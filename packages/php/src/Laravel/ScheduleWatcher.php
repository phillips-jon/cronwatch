<?php

declare(strict_types=1);

namespace Cronwatch\Laravel;

use Cronwatch\Cronwatch;
use Cronwatch\Js;
use Cronwatch\RunStatus;
use Illuminate\Console\Scheduling\CallbackEvent;
use Illuminate\Contracts\Container\Container;

/**
 * Records the scheduler's runs from its events, so every scheduled task
 * is watched with no code changes:
 *
 * - ScheduledTaskStarting starts the run (trigger "schedule"); a callback's
 *   Cronwatch::current() is its context while it runs.
 * - ScheduledTaskFinished ends it: ok, or failed with "Exited with code N"
 *   for a command that exited non-zero (a callback returning false, "Returned
 *   false"). A callback's return value is its output, as for run(); a
 *   command's output is what it wrote, read from its output file (the
 *   task's own, ->sendOutputTo() or ->appendOutputTo(), from where it stood
 *   when the run started, or else a file of CronWatch's own for the run).
 * - ScheduledTaskFailed ends a run still open failed with the exception (a
 *   callback that threw).
 * - ScheduledTaskSkipped (filters or a paused schedule) records nothing.
 * - A task ->withoutOverlapping() whose last run still holds the lock is
 *   skipped by Laravel and records nothing; a task ->onOneServer() records
 *   its run on the server that ran it (use a shared store).
 * - A task ->runInBackground() is started here and finished by
 *   `schedule:finish` in the process Laravel runs when the command ends
 *   (ScheduledBackgroundTaskFinished), with its exit code and output.
 *
 * @internal
 */
final class ScheduleWatcher
{
    public const TRIGGER = 'schedule';
    /** How much of an output file's end a run reads. */
    private const OUTPUT_READ = 256 * 1024;

    /** @var array<int, array{key: int, file: ?string, offset: int, own: bool, output: mixed, append: mixed}> spl_object_id(event) => the run */
    private array $open = [];

    public function __construct(private readonly Container $app, private readonly ScheduledTasks $tasks)
    {
    }

    private function cw(): Cronwatch
    {
        return $this->app->make(Cronwatch::class);
    }

    public function starting(object $event): void
    {
        $task = $event->task;
        $found = $this->tasks->handleFor($task);
        if ($found === null || !$found[1]) {
            return;
        }
        [$handle] = $found;
        if (!empty($task->withoutOverlapping) && isset($task->mutex) && $task->mutex->exists($task)) {
            // Laravel skips this run: the last one still holds the lock.
            return;
        }
        $capture = ['file' => null, 'offset' => 0, 'own' => false, 'output' => $task->output ?? null, 'append' => $task->shouldAppendOutput ?? false];
        if (!$task instanceof CallbackEvent) {
            $capture = $this->captureOutput($task) + $capture;
        }
        if (!empty($task->runInBackground)) {
            // Finished by schedule:finish in another process, which finds the run by its job.
            $handle->start(trigger: self::TRIGGER);
            return;
        }
        $this->open[spl_object_id($task)] = ['key' => $this->cw()->startExecution($handle->definition, self::TRIGGER, mayDiscard: !empty($task->withoutOverlapping))] + $capture;
    }

    public function finished(object $event): void
    {
        $task = $event->task;
        $run = $this->open[spl_object_id($task)] ?? null;
        if ($run === null) {
            return;
        }
        unset($this->open[spl_object_id($task)]);
        $output = $this->readOutput($task, $run);
        $cw = $this->cw();
        if (!empty($task->skippedBecauseOverlapping)) {
            // Laravel 13 skipped it after all (the lock was taken between the
            // two looks): no run happened, so none is left.
            $cw->discardExecution($run['key']);
            return;
        }
        $code = (int) ($task->exitCode ?? 0);
        if ($task instanceof CallbackEvent) {
            $result = (fn () => $this->result)->call($task);
            if ($result === false) {
                $cw->finishExecution($run['key'], null, 'Returned false', true);
                return;
            }
            $cw->finishExecution($run['key'], $result);
            return;
        }
        if ($code !== 0) {
            $cw->finishExecution($run['key'], null, "Exited with code {$code}", true, $output);
            return;
        }
        $cw->finishExecution($run['key'], output: $output);
    }

    public function failed(object $event): void
    {
        $task = $event->task;
        $run = $this->open[spl_object_id($task)] ?? null;
        if ($run === null) {
            return;
        }
        unset($this->open[spl_object_id($task)]);
        $output = $this->readOutput($task, $run);
        $this->cw()->finishExecution($run['key'], null, $event->exception, true, $output);
    }

    /** ScheduledBackgroundTaskFinished, in the schedule:finish process: the oldest running run of the task's job is finished. */
    public function backgroundFinished(object $event): void
    {
        $task = $event->task;
        $found = $this->tasks->handleFor($task);
        if ($found === null || !$found[1]) {
            return;
        }
        [$handle] = $found;
        $cw = $this->cw();
        $output = null;
        $file = self::backgroundFile($task);
        if (is_file($file)) {
            $output = self::tail($file, 0);
            @unlink($file);
        } elseif (is_string($task->output ?? null) && $task->output !== $task->getDefaultOutput() && is_file($task->output)) {
            $output = self::tail($task->output, 0);
        }
        try {
            $running = array_values(array_filter($cw->runs($handle->name, 50), fn ($run) => $run->status === RunStatus::RUNNING && $run->trigger === self::TRIGGER));
        } catch (\Throwable $error) {
            $cw->onError($error, "finishing {$handle->name}");
            return;
        }
        $oldest = end($running);
        if ($oldest === false) {
            return;
        }
        $code = (int) ($task->exitCode ?? 0);
        $run = $handle->resume($oldest->id);
        if ($output !== null && $output !== '') {
            $run->log($output);
        }
        if ($code !== 0) {
            $run->fail("Exited with code {$code}");
        } else {
            $run->finish();
        }
    }

    /**
     * Where a command's output will be read from: its own file, from where
     * it stands now, or a file of CronWatch's own for this run when the task
     * sends its output nowhere.
     *
     * @return array{file: ?string, offset: int, own: bool}
     */
    private function captureOutput(object $task): array
    {
        $default = method_exists($task, 'getDefaultOutput') ? $task->getDefaultOutput() : '/dev/null';
        $output = $task->output ?? $default;
        if ($output === $default) {
            $file = !empty($task->runInBackground) ? self::backgroundFile($task) : (string) tempnam(sys_get_temp_dir(), 'cronwatch-schedule-');
            if ($file === '') {
                return ['file' => null, 'offset' => 0, 'own' => false];
            }
            $task->output = $file;
            $task->shouldAppendOutput = false;
            return ['file' => $file, 'offset' => 0, 'own' => true];
        }
        $offset = !empty($task->shouldAppendOutput) && is_file($output) ? (int) filesize($output) : 0;
        return ['file' => (string) $output, 'offset' => $offset, 'own' => false];
    }

    /**
     * What the run wrote, and the task's output setting put back.
     *
     * @param array{file: ?string, offset: int, own: bool, output: mixed, append: mixed} $run
     */
    private function readOutput(object $task, array $run): ?string
    {
        if ($run['file'] === null) {
            return null;
        }
        clearstatcache(true, $run['file']);
        $text = is_file($run['file']) ? self::tail($run['file'], $run['offset']) : null;
        if ($run['own']) {
            @unlink($run['file']);
            $task->output = $run['output'];
            $task->shouldAppendOutput = $run['append'];
        }
        return $text === '' ? null : $text;
    }

    /** The file a background task's output goes to, known to both schedule:run and schedule:finish. */
    private static function backgroundFile(object $task): string
    {
        $dir = function_exists('storage_path') ? storage_path('framework') : sys_get_temp_dir();
        if (!is_dir($dir)) {
            $dir = sys_get_temp_dir();
        }
        return rtrim($dir, '/') . '/schedule-cronwatch-' . sha1((string) $task->mutexName()) . '.log';
    }

    /** The end of a file from an offset, at most OUTPUT_READ bytes. */
    private static function tail(string $file, int $offset): ?string
    {
        $size = (int) @filesize($file);
        $start = max($offset, $size - self::OUTPUT_READ);
        $handle = @fopen($file, 'rb');
        if ($handle === false) {
            return null;
        }
        try {
            fseek($handle, $start);
            $text = (string) stream_get_contents($handle);
        } finally {
            fclose($handle);
        }
        $text = rtrim(Js::wellFormed($text), "\r\n");
        return $text === '' ? null : $text;
    }
}
