<?php

declare(strict_types=1);

namespace Cronwatch\Job;

use Cronwatch\Cronwatch;
use Cronwatch\JobDefinition;

/**
 * A declared job. Keep it, and run the job through it:
 *
 *     $nightly->run(function (JobContext $job) {   // returns what the function returns
 *         $job->log('Report written');
 *     });
 *
 *     $task = $nightly->monitor($callable);        // a callable whose every call is a run
 */
final class JobHandle
{
    public readonly string $name;

    /** @internal Made by Cronwatch::job(). */
    public function __construct(
        private readonly Cronwatch $client,
        /** The job as declared. */
        public readonly JobDefinition $definition,
    ) {
        $this->name = (string) $definition->get('name');
    }

    /**
     * Run the function now as a recorded run, passing it the JobContext.
     * Returns what it returns and throws what it throws, after the run is
     * recorded. A string it returns is the run's output when nothing was logged.
     *
     * @template T
     * @param callable(JobContext): T $fn
     * @return T
     */
    public function run(callable $fn, string $trigger = 'run'): mixed
    {
        return $this->client->execute($this->definition, $trigger, $fn);
    }

    /**
     * A callable that runs `$fn` as a recorded run each time it is called,
     * with the arguments it is called with. Inside it, Cronwatch::current()
     * is the run's context, for log() and metric(). The Python package's
     * decorator has the same name.
     */
    public function monitor(callable $fn, string $trigger = 'run'): \Closure
    {
        return fn (mixed ...$args) => $this->client->execute($this->definition, $trigger, fn () => $fn(...$args));
    }

    /**
     * The same as monitor().
     *
     * @deprecated since 1.0, removed in 2.0: use monitor(), which is the same.
     */
    public function wrap(callable $fn, string $trigger = 'run'): \Closure
    {
        return $this->monitor($fn, $trigger);
    }

    /**
     * A request handler that runs the job, for a cron that calls a URL: the
     * function is called as fn(JobContext $job, $request) for each request
     * carrying `Authorization: Bearer <secret>`, as a recorded run with the
     * trigger "handler", and the request is answered with how it went. The
     * secret defaults to the client's cronSecret (CRON_SECRET); null lets
     * anyone run the job (false does the same, deprecated since 1.0 and
     * removed in 2.0; in 0.x null meant the client's secret). See Handler for its answers and its adapters
     * (serve() for a bare script, laravel(), a Symfony controller, PSR-15).
     *
     * @param callable(JobContext, mixed): mixed $fn
     */
    public function handler(callable $fn, string|false|null $secret = ''): Handler
    {
        return new Handler($this->client, $this->definition, $fn, $secret);
    }

    /**
     * Record a running run now and finish it later, perhaps from another
     * process (see resume()). `id` is your own stable id for the run, 1 to 200
     * characters, not starting with "pgcron:" (the pg_cron source's): a start
     * with an id already recorded for this job records nothing and returns a
     * handle on that run instead; an id recorded for another job throws.
     * Store failures go to onError; it never throws for them. A run that is
     * never finished is marked stuck by the first check after the job's timeout.
     */
    public function start(?string $trigger = null, ?string $id = null): RunHandle
    {
        return $this->client->startRun($this->definition, $trigger, $id);
    }

    /** A handle on a run this job started elsewhere, by its id, so this process can log to it and finish it. */
    public function resume(string $runId): RunHandle
    {
        return $this->client->resumeHandle($this->definition, $runId);
    }
}
