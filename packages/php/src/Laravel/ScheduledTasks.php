<?php

declare(strict_types=1);

namespace Cronwatch\Laravel;

use Cronwatch\Bridge\JobName;
use Cronwatch\Bridge\Unscheduled;
use Cronwatch\Cronwatch;
use Cronwatch\Job\JobHandle;
use Illuminate\Console\Application as Artisan;
use Illuminate\Console\Scheduling\CallbackEvent;
use Illuminate\Console\Scheduling\Event;
use Illuminate\Console\Scheduling\Schedule;
use Illuminate\Contracts\Container\Container;

/**
 * The app's schedule as CronWatch jobs: which job each scheduled event is,
 * with its cron expression and timezone as the job's schedule, declared on
 * the client so a check knows every task, including one that never ran.
 *
 * A job is named, unless ->cronwatch(['name' => ...]) names it:
 *
 * - a command (Schedule::command()) after the command as written, without
 *   PHP and artisan: `emails:send`; one with arguments has them too, with
 *   the characters a name cannot hold made "-" and a short hash added
 *   (`emails:send --force` is `emails:send-force-<8 hex>`);
 * - a shell command (Schedule::exec()) after the command, the same way;
 * - a callback (Schedule::call()) after its name or description when it has
 *   one (->name('prune-tokens')), else its class and method, else, for a
 *   closure, `closure:<file>:<line>`, which moves when the line does (give
 *   it a name);
 * - a queued job (Schedule::job()) after its class, backslashes as dots
 *   (App.Jobs.SendReport); when the class is watched on the queue
 *   (#[Cronwatch\Watch] or ShouldBeWatched), its runs are the queued job's,
 *   recorded by the worker, and the scheduler only declares the schedule.
 *
 * A task with filters (->when(), ->skip(), ->between(), ->unlessBetween())
 * does not run at every time its expression names, so it is declared
 * without a schedule: its runs and failures are watched, and it is never
 * reported missed. ->cronwatch(['schedule' => ...]) gives it one. Two
 * tasks with one name and different schedules are one job without a
 * schedule, reported once; a task outside the current environment
 * (->environments()) is not watched. The check itself is never a job.
 *
 * @internal
 */
final class ScheduledTasks
{
    public const TAG = 'laravel-scheduler';
    public const CHECK_COMMAND = 'cronwatch:check';

    /** @var array<int, ?string> spl_object_id(event) => job name, null for an event not watched */
    private array $names = [];
    /** @var array<string, array{options: array<string, mixed>, events: list<object>, defer: bool, schedules: list<string>}> */
    private array $jobs = [];
    /** @var array<string, JobHandle> */
    private array $handles = [];
    /** @var \WeakReference<object>|null the schedule planned */
    private ?\WeakReference $planned = null;
    /** @var array<string, true> */
    private array $reported = [];
    /** @var array<class-string, string> a queued job's class => the job the schedule dispatches it as */
    private array $queued = [];

    public function __construct(private readonly Container $app, private readonly QueueWatcher $queue)
    {
    }

    private function cw(): Cronwatch
    {
        return $this->app->make(Cronwatch::class);
    }

    /** @return array<string, mixed> */
    private function config(): array
    {
        $config = $this->app->make('config')->get('cronwatch.schedule', []);
        return is_array($config) ? $config : [];
    }

    /**
     * Declares every task of the schedule (the app's, by default) on the
     * client. Returns the job names declared.
     *
     * @return list<string>
     */
    public function declare(?Schedule $schedule = null): array
    {
        $schedule ??= $this->app->make(Schedule::class);
        if ($this->planned?->get() !== $schedule) {
            $this->plan($schedule);
        }
        $cw = $this->cw();
        foreach ($this->jobs as $name => $job) {
            if (!isset($this->handles[$name]) || !$this->declaredOn($cw, $name)) {
                $this->declareOne($cw, $name, $job['options']);
            }
        }
        return array_keys($this->handles);
    }

    /**
     * This app's tag under the scheduler's ("laravel-scheduler:<app>"): the
     * app's name from cronwatch.app_id (CRONWATCH_APP_ID), else app.name, so
     * two apps sharing a store never take each other's jobs for their own.
     */
    public function appTag(): string
    {
        $config = $this->app->make('config');
        $app = $config->get('cronwatch.app_id');
        $app = is_string($app) && trim($app) !== '' ? $app : $config->get('app.name');
        return Unscheduled::appTag(self::TAG, is_string($app) && trim($app) !== '' ? $app : 'laravel');
    }

    /** What a check starts with: every task declared, and jobs of tasks no longer scheduled declared without their schedule. */
    public function prepare(): Cronwatch
    {
        $this->declare();
        $cw = $this->cw();
        Unscheduled::declare($cw, self::TAG, $this->appTag(), $this->report(...));
        return $cw;
    }

    /**
     * The job an event runs as, declared, or null when it is not watched.
     * `recorded` is false for a queued job the queue watcher records.
     *
     * @return array{JobHandle, bool}|null
     */
    public function handleFor(object $event): ?array
    {
        $id = spl_object_id($event);
        if (!array_key_exists($id, $this->names)) {
            $schedule = $this->app->make(Schedule::class);
            if ($this->planned?->get() !== $schedule || in_array($event, $schedule->events(), true)) {
                $this->plan($schedule);
            }
            if (!array_key_exists($id, $this->names)) {
                // An event outside the app's schedule (made by hand, or by a test): planned on its own.
                $this->addEvent($event);
                $this->settle();
            }
        }
        $name = $this->names[$id] ?? null;
        if ($name === null || !isset($this->jobs[$name])) {
            return null;
        }
        $cw = $this->cw();
        if (!isset($this->handles[$name]) || !$this->declaredOn($cw, $name)) {
            $this->declareOne($cw, $name, $this->jobs[$name]['options']);
        }
        $handle = $this->handles[$name] ?? null;
        return $handle === null ? null : [$handle, !$this->jobs[$name]['defer']];
    }

    private function declaredOn(Cronwatch $cw, string $name): bool
    {
        foreach ($cw->definedJobs() as $definition) {
            if ($definition->get('name') === $name) {
                return true;
            }
        }
        return false;
    }

    /** @param array<string, mixed> $options */
    private function declareOne(Cronwatch $cw, string $name, array $options): void
    {
        try {
            $this->handles[$name] = $cw->job($name, $options);
            return;
        } catch (\Throwable $error) {
            $this->reportOnce($error, "declaring {$name}");
        }
        if (!isset($options['schedule']) && !isset($options['timezone'])) {
            unset($this->handles[$name]);
            return;
        }
        // A schedule CronWatch cannot read: the task is watched without one.
        unset($options['schedule'], $options['timezone']);
        try {
            $this->handles[$name] = $cw->job($name, $options);
        } catch (\Throwable $error) {
            unset($this->handles[$name]);
            $this->reportOnce($error, "declaring {$name}");
        }
    }

    private function plan(Schedule $schedule): void
    {
        $this->names = [];
        $this->jobs = [];
        $this->handles = [];
        $this->queued = [];
        $this->planned = \WeakReference::create($schedule);
        foreach ($schedule->events() as $event) {
            $this->addEvent($event);
        }
        $this->settle();
    }

    /** One event into the plan. */
    private function addEvent(object $event): void
    {
        if (!$event instanceof Event) {
            return;
        }
        // Seen, whether or not it is watched, so it is not planned again.
        $this->names[spl_object_id($event)] = null;
        $given = EventOptions::get($event);
        if ($given === false || self::isCheck($event)) {
            return;
        }
        $environment = (string) $this->app->make('config')->get('app.env', 'production');
        if (method_exists($event, 'runsInEnvironment') && !$event->runsInEnvironment($environment)) {
            return;
        }
        $given ??= [];
        [$name, $description] = self::describe($event);
        $base = ['description' => $description];
        $class = $event instanceof CallbackEvent && is_string($event->description) ? $event->description : null;
        $queued = $class !== null && class_exists($class) && $this->queue->watches($class) ? $class : null;
        if ($queued !== null) {
            // Schedule::job() of a job the queue watcher records: the queued
            // run is the run, under the queued job's name and options.
            [$name, $base] = $this->queue->definition($queued);
        }
        $name = is_string($given['name'] ?? null) && $given['name'] !== '' ? $given['name'] : $name;
        unset($given['name']);
        if (in_array($name, (array) ($this->config()['exclude'] ?? []), true)) {
            return;
        }
        $options = [];
        if (!self::isFiltered($event)) {
            $options['schedule'] = (string) $event->expression;
            $options['timezone'] = $this->timezone($event);
        }
        foreach ([...$base, ...$given] as $key => $value) {
            $options[(string) $key] = $value;
        }
        $options['tags'] = array_values(array_unique([...array_map('strval', (array) ($options['tags'] ?? [])), self::TAG, $this->appTag()]));
        $options = array_filter($options, fn ($value) => $value !== null);
        $this->names[spl_object_id($event)] = $name;
        if (!isset($this->jobs[$name])) {
            $this->jobs[$name] = ['options' => $options, 'events' => [$event], 'defer' => $queued !== null, 'schedules' => []];
        } else {
            $this->jobs[$name]['events'][] = $event;
        }
        if ($queued !== null) {
            $this->queued[$queued] = $name;
        }
        $this->jobs[$name]['schedules'][] = isset($options['schedule']) ? $options['schedule'] . ' ' . ($options['timezone'] ?? '') : '';
    }

    /**
     * The job a queued class runs as when the schedule dispatches it
     * (Schedule::job()), with the schedule's options, or null.
     *
     * @return array{string, array<string, mixed>}|null
     */
    public function queuedJob(string $class): ?array
    {
        try {
            $schedule = $this->app->make(Schedule::class);
            if ($this->planned?->get() !== $schedule) {
                $this->plan($schedule);
            }
        } catch (\Throwable) {
            return null;
        }
        $name = $this->queued[$class] ?? null;
        return $name !== null && isset($this->jobs[$name]) ? [$name, $this->jobs[$name]['options']] : null;
    }

    /** Names shared by tasks on different schedules become one job without a schedule. */
    private function settle(): void
    {
        foreach ($this->jobs as $name => $job) {
            $schedules = array_unique($job['schedules'] ?? []);
            if (count($schedules) > 1) {
                unset($this->jobs[$name]['options']['schedule'], $this->jobs[$name]['options']['timezone']);
                $this->reportOnce(new \RuntimeException(count($job['events']) . " scheduled tasks are named {$name}, on different schedules, so the job is watched without a schedule; give each its own name with ->cronwatch(['name' => ...])"), "declaring {$name}");
            }
        }
    }

    /**
     * The default job name and description of an event.
     *
     * @return array{string, string}
     */
    public static function describe(Event $event): array
    {
        $description = is_string($event->description) && $event->description !== '' ? $event->description : null;
        if ($event instanceof CallbackEvent) {
            if ($description !== null) {
                return [class_exists($description) ? JobName::ofClass($description) : JobName::clean($description), $description];
            }
            $callback = (fn () => $this->callback)->call($event);
            [$name, $label] = self::callbackName($callback);
            return [$name, $label];
        }
        $command = self::commandText((string) $event->command);
        return [JobName::clean($command), $description ?? $command];
    }

    /** The command an event runs, without PHP and artisan for an Artisan command. */
    public static function commandText(string $command): string
    {
        $prefix = Artisan::formatCommandString('');
        if (str_starts_with($command, $prefix)) {
            return trim(substr($command, strlen($prefix)));
        }
        // An artisan command given by path to PHP some other way: `php artisan x`.
        if (preg_match('/^(?:\S*php\S*[\'"]?\s+[\'"]?artisan[\'"]?)\s+(.*)$/s', $command, $m) === 1) {
            return trim($m[1]);
        }
        return trim($command);
    }

    /** @return array{string, string} */
    private static function callbackName(mixed $callback): array
    {
        if (is_string($callback)) {
            $text = str_replace(['@', '::'], '.', $callback);
            return [JobName::ofClass($text), $callback];
        }
        if (is_array($callback) && count($callback) === 2) {
            $class = is_object($callback[0]) ? $callback[0]::class : (string) $callback[0];
            return [JobName::ofClass($class) . '.' . JobName::clean((string) $callback[1]), "{$class}::{$callback[1]}"];
        }
        if ($callback instanceof \Closure) {
            $function = new \ReflectionFunction($callback);
            $file = basename((string) $function->getFileName());
            $line = (int) $function->getStartLine();
            return [JobName::clean("closure:{$file}:{$line}"), "A closure in {$file} at line {$line}"];
        }
        if (is_object($callback)) {
            return [JobName::ofClass($callback::class), $callback::class];
        }
        return ['callback', 'A callback'];
    }

    private static function isCheck(Event $event): bool
    {
        return !$event instanceof CallbackEvent && preg_match('/(^|\s|[\'"])' . preg_quote(self::CHECK_COMMAND, '/') . '($|\s|[\'"])/', self::commandText((string) $event->command)) === 1;
    }

    /** Whether the event runs only when filters pass (when, skip, between, unlessBetween). */
    public static function isFiltered(Event $event): bool
    {
        [$filters, $rejects] = (fn () => [$this->filters ?? [], $this->rejects ?? []])->call($event);
        // ->withoutOverlapping() adds a skip of its own (the lock is held),
        // which does not move when the task is due: it is not a filter here.
        $rejects = array_filter($rejects, fn ($reject) => !self::isOverlapSkip($reject));
        return $filters !== [] || $rejects !== [];
    }

    /** Whether a reject callback is the one Event::withoutOverlapping() adds. */
    private static function isOverlapSkip(mixed $reject): bool
    {
        static $where = null;
        if (!$reject instanceof \Closure) {
            return false;
        }
        try {
            if ($where === null) {
                $method = new \ReflectionMethod(Event::class, 'withoutOverlapping');
                $where = [$method->getFileName(), $method->getStartLine(), $method->getEndLine()];
            }
            $closure = new \ReflectionFunction($reject);
            return $closure->getFileName() === $where[0] && $closure->getStartLine() >= $where[1] && $closure->getEndLine() <= $where[2];
        } catch (\ReflectionException) {
            return false;
        }
    }

    private function timezone(Event $event): string
    {
        $zone = $event->timezone;
        if ($zone instanceof \DateTimeZone) {
            return $zone->getName();
        }
        if (is_string($zone) && $zone !== '') {
            return $zone;
        }
        $app = $this->app->make('config')->get('app.timezone');
        return is_string($app) && $app !== '' ? $app : date_default_timezone_get();
    }

    private function report(\Throwable $error, string $where): void
    {
        $this->cw()->onError($error, $where);
    }

    private function reportOnce(\Throwable $error, string $where): void
    {
        $key = $where . "\n" . $error->getMessage();
        if (isset($this->reported[$key])) {
            return;
        }
        $this->reported[$key] = true;
        $this->report($error, $where);
    }
}
