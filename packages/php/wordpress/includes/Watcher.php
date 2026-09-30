<?php

declare(strict_types=1);

namespace Cronwatch\WordPress;

\defined('ABSPATH') || exit;

use Cronwatch\Job\RunHandle;
use Cronwatch\Output;

/**
 * Records each WP-Cron event's run, with no change to the code that
 * schedules it.
 *
 * wp-cron.php (and WP-CLI's `wp cron event run`) run an event in three
 * steps: wp_reschedule_event() for a recurring one, wp_unschedule_event(),
 * then do_action_ref_array($hook, $args). The first two pass through the
 * pre_reschedule_event and pre_unschedule_event filters, which this watches
 * (changing nothing) to note which event is about to run, and on the first
 * sight of a hook it adds two callbacks to it: one at PHP_INT_MIN that
 * starts the run, one at PHP_INT_MAX that finishes it. A hook fired any
 * other way (a plain do_action, or outside cron) finds no note and is not a
 * run.
 *
 * What the callbacks echo is passed on as it is written (an output buffer
 * with a callback, flushed every 8 KB), and its end is kept as the run's
 * output: never all of it, so a callback that streams a large export uses
 * no more memory than it did without the plugin. A callback that throws, a fatal error or an exit() ends the
 * request: the run is recorded as failed from inside WordPress's fatal
 * error handler (which may end the process with wp_die() before a plugin's
 * shutdown function is called) or from a shutdown function of its own,
 * whichever comes first.
 */
final class Watcher
{
    /** @var array{hook: string, key: string, recurrence: string, interval: int}|null The recurring event just rescheduled. */
    private ?array $rescheduled = null;
    /** @var array{hook: string, args: array, recurrence: ?string, interval: ?int}|null The event about to run. */
    private ?array $next = null;
    /** @var array<string, true> Hooks the two callbacks were added to. */
    private array $wrapped = [];
    /** @var list<array{hook: string, handle: ?RunHandle, level: int}> Runs in progress, innermost last. */
    private array $open = [];
    /** How much of the end of a run's output is kept: four times the run's cap, so the cap (counted in UTF-16 units) always has enough. */
    public const OUTPUT_KEPT = 4 * \Cronwatch\Output::OUTPUT_CAP;
    /** The size at which a run's output buffer is flushed on. */
    public const CHUNK = 8192;
    /** @var array<int, string> the kept end of each open run's output passed on so far, by buffer level */
    private array $kept = [];
    private bool $shutdownHooked = false;
    /** Memory given back when a fatal error (memory exhausted) ends a run, so it can still be recorded. */
    private ?string $reserve = null;

    public function register(): void
    {
        // Last, so the note is of what WordPress will do; $pre is returned untouched.
        add_filter('pre_reschedule_event', [$this, 'rescheduling'], PHP_INT_MAX, 2);
        add_filter('pre_unschedule_event', [$this, 'unscheduling'], PHP_INT_MAX, 4);
        add_action('cronwatch_log', [$this, 'log'], 10, PHP_INT_MAX);
        // WordPress's fatal error handler shows its page with wp_die(), which
        // exits, and it is a shutdown function registered before any plugin's,
        // so the open runs are recorded here, before that page. Any wp_die()
        // during an event ends the process the same way.
        add_filter('wp_php_error_message', [$this, 'fatalFilter'], 1, 1);
        foreach (['wp_die_handler', 'wp_die_ajax_handler', 'wp_die_json_handler', 'wp_die_jsonp_handler', 'wp_die_xmlrpc_handler', 'wp_die_xml_handler'] as $filter) {
            add_filter($filter, [$this, 'fatalFilter'], 1, 1);
        }
    }

    /** pre_reschedule_event: a recurring event is about to run (or is rescheduled by someone else). */
    public function rescheduling(mixed $pre, mixed $event = null): mixed
    {
        if (is_object($event) && isset($event->hook) && is_string($event->hook)) {
            $args = is_array($event->args ?? null) ? $event->args : [];
            $recurrence = is_string($event->schedule ?? null) ? $event->schedule : '';
            $interval = (int) ($event->interval ?? 0);
            if ($interval <= 0 && $recurrence !== '') {
                $interval = (int) (wp_get_schedules()[$recurrence]['interval'] ?? 0);
            }
            $this->rescheduled = ['hook' => $event->hook, 'key' => md5(serialize($args)), 'recurrence' => $recurrence, 'interval' => $interval];
        }
        return $pre;
    }

    /** pre_unschedule_event: in cron, the event about to run. */
    public function unscheduling(mixed $pre, mixed $timestamp = null, mixed $hook = null, mixed $args = null): mixed
    {
        if (!is_string($hook) || !wp_doing_cron() || $hook === Plugin::CHECK_HOOK) {
            return $pre;
        }
        $args = is_array($args) ? $args : [];
        $recurring = $this->rescheduled !== null && $this->rescheduled['hook'] === $hook && $this->rescheduled['key'] === md5(serialize($args))
            && $this->rescheduled['interval'] > 0 ? $this->rescheduled : null;
        $this->rescheduled = null;
        $this->next = ['hook' => $hook, 'args' => $args, 'recurrence' => $recurring['recurrence'] ?? null, 'interval' => $recurring['interval'] ?? null];
        if (!isset($this->wrapped[$hook])) {
            $this->wrapped[$hook] = true;
            add_action($hook, [$this, 'begin'], PHP_INT_MIN, PHP_INT_MAX);
            add_action($hook, [$this, 'end'], PHP_INT_MAX, PHP_INT_MAX);
        }
        return $pre;
    }

    /** The first callback on a watched hook: starts the run when the hook is the event noted. */
    public function begin(mixed ...$args): void
    {
        $hook = current_filter();
        $event = $this->next;
        $this->next = null;
        if ($event === null || $event['hook'] !== $hook) {
            return;
        }
        $handle = null;
        if (apply_filters('cronwatch_watch_event', true, $hook, $event['args'], $event['recurrence'])) {
            try {
                $handle = Plugin::startRun($event);
            } catch (\Throwable $error) {
                Plugin::report($error, "recording {$hook}");
            }
        }
        if ($handle === null) {
            // Not watched: a marker so end() still pairs up.
            $this->open[] = ['hook' => $hook, 'handle' => null, 'level' => -1];
            return;
        }
        $this->hookFailures();
        $level = ob_get_level() + 1;
        $this->kept[$level] = '';
        ob_start(fn (string $chunk, int $phase): string => $this->passOn($level, $chunk, $phase), self::CHUNK);
        $this->open[] = ['hook' => $hook, 'handle' => $handle, 'level' => ob_get_level()];
    }

    /**
     * A run's output buffer handler: each chunk goes on as it is, and the
     * end of what went on is kept for the run. What is cleaned (at the end
     * of the run, which reads the rest itself) is neither kept nor sent.
     */
    private function passOn(int $level, string $chunk, int $phase): string
    {
        if (($phase & PHP_OUTPUT_HANDLER_CLEAN) !== 0) {
            return '';
        }
        if ($chunk !== '' && isset($this->kept[$level])) {
            $this->kept[$level] = self::keepEnd($this->kept[$level] . $chunk);
        }
        return $chunk;
    }

    /** The last OUTPUT_KEPT bytes of `text`, starting on a whole UTF-8 character. */
    private static function keepEnd(string $text): string
    {
        if (strlen($text) <= self::OUTPUT_KEPT) {
            return $text;
        }
        return (string) preg_replace('/^[\x80-\xBF]+/', '', substr($text, -self::OUTPUT_KEPT));
    }

    /** The last callback on a watched hook: finishes the run begin() started. */
    public function end(mixed ...$args): void
    {
        $top = end($this->open);
        if ($top === false || $top['hook'] !== current_filter()) {
            return;
        }
        array_pop($this->open);
        if ($top['handle'] !== null) {
            $this->finish($top, null);
        }
    }

    /** cronwatch_log(): a line for the run in progress. */
    public function log(mixed ...$parts): void
    {
        for ($i = count($this->open) - 1; $i >= 0; $i--) {
            if ($this->open[$i]['handle'] !== null) {
                $this->open[$i]['handle']->log(...$parts);
                return;
            }
        }
    }

    /** Whether a run is in progress in this process. */
    public function anyOpen(): bool
    {
        foreach ($this->open as $entry) {
            if ($entry['handle'] !== null) {
                return true;
            }
        }
        return false;
    }

    /**
     * Records one run: what its callbacks echoed (echoed on again), then the
     * finish, or the failure when `error` is given.
     *
     * @param array{hook: string, handle: ?RunHandle, level: int} $entry
     */
    private function finish(array $entry, mixed $error): void
    {
        $output = '';
        if ($entry['level'] > 0 && ob_get_level() >= $entry['level']) {
            while (ob_get_level() > $entry['level']) {
                ob_end_flush();
            }
            $rest = (string) ob_get_contents();
            ob_end_clean();
            $output = self::keepEnd(($this->kept[$entry['level']] ?? '') . $rest);
            echo $rest; // phpcs:ignore WordPress.Security.EscapeOutput.OutputNotEscaped -- the callbacks' own output, passed on unchanged.
        }
        unset($this->kept[$entry['level']]);
        $handle = $entry['handle'];
        try {
            $text = rtrim($output, "\r\n");
            if ($text !== '') {
                $handle->log($text);
            }
            $error === null ? $handle->finish() : $handle->fail($error);
        } catch (\Throwable $problem) {
            Plugin::report($problem, "finishing {$entry['hook']}");
        }
    }

    /** Records every run still open as failed with `error`, innermost first. */
    private function failAll(mixed $error): void
    {
        while (($entry = array_pop($this->open)) !== null) {
            if ($entry['handle'] !== null) {
                $this->finish($entry, $error);
            }
        }
    }

    /**
     * The shutdown function, registered once an event runs. No exception
     * handler is set: one would change how the site ends on an uncaught
     * exception (WordPress's fatal error page and recovery mode read the
     * error PHP leaves), so an exception is recorded from that error.
     */
    private function hookFailures(): void
    {
        if (!$this->shutdownHooked) {
            $this->shutdownHooked = true;
            $this->reserve = str_repeat(' ', 256 * 1024);
            register_shutdown_function([$this, 'interrupted']);
        }
    }

    /** wp_php_error_message and the wp_die handler filters: WordPress is about to show a fatal error and stop. */
    public function fatalFilter(mixed $value): mixed
    {
        if ($this->anyOpen()) {
            $this->interrupted();
        }
        return $value;
    }

    /**
     * The process is ending with runs still open (exit() inside a callback,
     * or a fatal error): each is recorded as failed, as the library's own
     * shutdown handler writes it.
     */
    public function interrupted(): void
    {
        if (!$this->anyOpen()) {
            return;
        }
        $this->reserve = null;
        $fatal = error_get_last();
        if ($fatal !== null && !in_array($fatal['type'], [E_ERROR, E_PARSE, E_CORE_ERROR, E_COMPILE_ERROR, E_USER_ERROR, E_RECOVERABLE_ERROR], true)) {
            $fatal = null;
        }
        if ($fatal !== null && str_starts_with($fatal['message'], 'Allowed memory size')) {
            // phpcs:ignore Squiz.PHP.DiscouragedFunctions.Discouraged -- the request is ending on a memory fatal; room to record the failed run. wp_raise_memory_limit() only reaches WP_MAX_MEMORY_LIMIT, which may be the limit just hit.
            @ini_set('memory_limit', (string) (memory_get_usage(true) + 32 * 1024 * 1024));
        }
        $this->failAll($fatal !== null
            ? Output::describe('Interrupted', 'Fatal error: ' . $fatal['message'], ["{$fatal['file']}:{$fatal['line']}"])
            : 'Interrupted: the process exited during the run');
    }
}
