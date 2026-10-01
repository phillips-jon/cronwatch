<?php

declare(strict_types=1);

namespace Cronwatch\Laravel;

use Cronwatch\Bridge\JobName;
use Cronwatch\Cronwatch;
use Cronwatch\Job\JobHandle;
use Cronwatch\Watch;
use Illuminate\Contracts\Container\Container;

/**
 * Queued jobs that opt in (#[Cronwatch\Watch] on the class, or
 * ShouldBeWatched), watched through the queue's events, so each attempt
 * is a run with the trigger "queue", recorded in the worker that ran it:
 *
 * - JobProcessing starts the run; Cronwatch::current() is its context
 *   while the job runs, for log() and metric().
 * - JobProcessed ends it ok, or failed when the job marked itself failed.
 *   A job released back onto the queue without an exception (a RateLimited
 *   or WithoutOverlapping middleware, or a deliberate $this->release())
 *   did not run, so its run is taken back (Cronwatch::discardExecution):
 *   no row is left, nothing is judged or alerted, and failuresBeforeAlert
 *   counts on across it. A release after an exception is the exception's
 *   failed attempt, as Celery's retry is. A job a middleware skips without
 *   releasing it (WithoutOverlapping or RateLimited ->dontRelease(), Skip)
 *   is deleted unrun, and its run is taken back the same way: a pipe on the
 *   command bus, which runs only once the job's own middleware let it
 *   through, notes each attempt that reached its handler.
 * - JobExceptionOccurred and JobFailed end it failed with the exception,
 *   whichever comes first; JobTimedOut ends it failed before the worker
 *   kills itself.
 *
 * Every attempt is a run of its own (its id is the queued job's uuid and
 * a random suffix), so failing attempts open one failed alert, the attempt
 * that succeeds closes it, and failuresBeforeAlert rides through retries.
 * A worker killed outright records nothing, and its run is marked stuck
 * after the job's timeout; one that exits or dies of a fatal error records
 * the run as interrupted. A queued listener, mailable or notification is
 * watched by its own class, as the worker names it.
 *
 * @internal
 */
final class QueueWatcher
{
    public const TRIGGER = 'laravel-queue';
    public const TAG = 'laravel-queue';

    /** @var array<int, int> spl_object_id(queue job) => the run's execution key */
    private array $open = [];
    /** @var array<string, array{Cronwatch, JobHandle}> */
    private array $handles = [];
    /** @var array<string, bool> */
    private array $watched = [];
    /** @var array<int, bool> spl_object_id(queue job) => whether its handler was reached, for the jobs that can tell */
    private array $reached = [];
    /** The command bus pipe that notes a handler reached. */
    private ?\Closure $pipe = null;

    public function __construct(private readonly Container $app)
    {
    }

    private function cw(): Cronwatch
    {
        return $this->app->make(Cronwatch::class);
    }

    /** Whether a job class opted in. */
    public function watches(string $class): bool
    {
        if (isset($this->watched[$class])) {
            return $this->watched[$class];
        }
        $watch = class_exists($class) ? Watch::of($class) : null;
        $watched = $watch !== null ? $watch->enabled : is_subclass_of($class, ShouldBeWatched::class);
        return $this->watched[$class] = $watched;
    }

    /**
     * A watched class's options: the attribute's, then a static cronwatch()
     * method's, with "name" taken out.
     *
     * @return array{string, array<string, mixed>}
     */
    public function definition(string $class): array
    {
        $options = Watch::of($class)?->options() ?? [];
        $name = Watch::of($class)?->name;
        if (method_exists($class, 'cronwatch') && (new \ReflectionMethod($class, 'cronwatch'))->isStatic()) {
            $more = $class::cronwatch();
            if (is_array($more)) {
                $name = is_string($more['name'] ?? null) && $more['name'] !== '' ? $more['name'] : $name;
                unset($more['name']);
                $options = array_replace($options, $more);
            }
        }
        $options = $options + ['description' => "Queued job {$class}"];
        $options['tags'] = array_values(array_unique([...array_map('strval', (array) ($options['tags'] ?? [])), self::TAG]));
        return [$name !== null && $name !== '' ? $name : JobName::ofClass($class), $options];
    }

    private function handle(string $class): ?JobHandle
    {
        $cw = $this->cw();
        [$client, $handle] = $this->handles[$class] ?? [null, null];
        if ($client === $cw && $handle !== null) {
            return $handle;
        }
        try {
            // A job the schedule dispatches (Schedule::job()) is declared with its schedule, as the check declares it.
            $scheduled = $this->app->make('config')->get('cronwatch.schedule.watch', true)
                ? $this->app->make(ScheduledTasks::class)->queuedJob($class)
                : null;
            [$name, $options] = $scheduled ?? $this->definition($class);
            $handle = $cw->job($name, $options);
        } catch (\Throwable $error) {
            $cw->onError($error, "declaring {$class}");
            return null;
        }
        $this->handles[$class] = [$cw, $handle];
        return $handle;
    }

    /** The watched class a queue job runs, or null. */
    private function classOf(object $job): ?string
    {
        $candidates = [];
        try {
            $payload = method_exists($job, 'payload') ? $job->payload() : [];
            if (is_string($payload['data']['commandName'] ?? null)) {
                $candidates[] = $payload['data']['commandName'];
            }
        } catch (\Throwable) {
        }
        if (method_exists($job, 'resolveName')) {
            $candidates[] = (string) $job->resolveName();
        }
        foreach ($candidates as $class) {
            if (class_exists($class) && $this->watches($class)) {
                return $class;
            }
        }
        return null;
    }

    public function processing(object $event): void
    {
        $job = $event->job;
        $class = $this->classOf($job);
        if ($class === null || isset($this->open[spl_object_id($job)])) {
            return;
        }
        $handle = $this->handle($class);
        if ($handle === null) {
            return;
        }
        $base = method_exists($job, 'uuid') ? $job->uuid() : null;
        $base = is_string($base) && $base !== '' ? $base : (method_exists($job, 'getJobId') ? $job->getJobId() : null);
        $id = is_scalar($base) && (string) $base !== '' && strlen((string) $base) <= 150 ? $base . ':' . bin2hex(random_bytes(6)) : null;
        $this->open[spl_object_id($job)] = $this->cw()->startExecution($handle->definition, self::TRIGGER, $id, mayDiscard: true);
        if ($this->tellsReached($job, $class)) {
            $this->reached[spl_object_id($job)] = false;
        }
    }

    /**
     * Whether this attempt will say when its handler is reached: a job class
     * run by Laravel's CallQueuedHandler, which gives the command its queue
     * job (InteractsWithQueue), on Laravel's own command bus, which then
     * carries the pipe. The pipe is put back if the app set the bus's pipes
     * since.
     */
    private function tellsReached(object $job, string $class): bool
    {
        try {
            $payload = method_exists($job, 'payload') ? $job->payload() : [];
            if (($payload['job'] ?? null) !== 'Illuminate\\Queue\\CallQueuedHandler@call' || ($payload['data']['commandName'] ?? null) !== $class
                || !in_array(\Illuminate\Queue\InteractsWithQueue::class, class_uses_recursive($class), true)) {
                return false;
            }
            $bus = $this->app->make(\Illuminate\Contracts\Bus\Dispatcher::class);
            if (!$bus instanceof \Illuminate\Bus\Dispatcher) {
                return false;
            }
            $this->pipe ??= function (object $command, \Closure $next): mixed {
                $queued = $command->job ?? null;
                if (is_object($queued) && isset($this->reached[spl_object_id($queued)])) {
                    $this->reached[spl_object_id($queued)] = true;
                }
                return $next($command);
            };
            $pipes = (fn (): array => $this->pipes)->call($bus);
            if (!in_array($this->pipe, $pipes, true)) {
                $bus->pipeThrough([...$pipes, $this->pipe]);
            }
            return true;
        } catch (\Throwable) {
            return false;
        }
    }

    public function processed(object $event): void
    {
        $job = $event->job;
        if (!isset($this->open[spl_object_id($job)])) {
            return;
        }
        if (method_exists($job, 'hasFailed') && $job->hasFailed()) {
            $this->end($job, 'The job was marked as failed');
        } elseif (method_exists($job, 'isReleased') && $job->isReleased() && !(method_exists($job, 'isDeleted') && $job->isDeleted())) {
            // Released without an exception (rate limited, WithoutOverlapping,
            // a deliberate release): the attempt did not happen, so its run is
            // taken back, neither a failure nor a success.
            $this->discard($job);
        } elseif (($this->reached[spl_object_id($job)] ?? true) === false) {
            // Deleted without its handler running (a middleware's
            // dontRelease(), Skip): no attempt happened either.
            $this->discard($job);
        } else {
            $this->end($job, null);
        }
    }

    private function discard(object $job): void
    {
        $id = spl_object_id($job);
        $key = $this->open[$id] ?? null;
        if ($key === null) {
            return;
        }
        unset($this->open[$id], $this->reached[$id]);
        $this->cw()->discardExecution($key);
    }

    /** JobExceptionOccurred and JobFailed: the attempt failed with this exception. */
    public function failed(object $event): void
    {
        $this->end($event->job, $event->exception ?? 'The job failed');
    }

    public function timedOut(object $event): void
    {
        $job = $event->job;
        $name = method_exists($job, 'resolveName') ? (string) $job->resolveName() : 'The job';
        $this->end($job, "{$name} has timed out.");
    }

    /** Ends the attempt's run: ok when `error` is null, else failed with it. */
    private function end(object $job, mixed $error): void
    {
        $id = spl_object_id($job);
        $key = $this->open[$id] ?? null;
        if ($key === null) {
            return;
        }
        unset($this->open[$id], $this->reached[$id]);
        $this->cw()->finishExecution($key, null, $error, $error !== null);
    }
}
