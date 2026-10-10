<?php

declare(strict_types=1);

namespace Cronwatch\Store;

use Cronwatch\JobDefinition;
use Cronwatch\JobState;
use Cronwatch\Run;
use Cronwatch\StoredJob;

/**
 * Where jobs, runs, and state live: the SDK's Store. A store that also
 * implements UpdatesRunIf and ComparesAndSetsState (all of this package's
 * do) keeps several processes sharing it from finishing one run twice or
 * overwriting each other's state; without them the client falls back to a
 * read then a write, which is safe only while one process at a time writes.
 * tests/StoreConformanceTest.php is the test every store passes.
 */
interface Store
{
    /** Called once before first use. Create tables here. */
    public function init(): void;

    public function upsertJob(JobDefinition $definition, int|float $now): void;

    public function getJob(string $name): ?StoredJob;

    /** @return list<StoredJob> by name, in byte order */
    public function listJobs(): array;

    /** Removes the job, its runs, and its state. */
    public function deleteJob(string $name): void;

    /** Throws for an id already stored: a run is never overwritten. */
    public function insertRun(Run $run): void;

    /** Writes a run's status, finishedAt, durationMs, error, output, and metrics. A run that is gone stays gone. */
    public function updateRun(Run $run): void;

    public function getRun(string $id): ?Run;

    /** @return list<Run> newest first, runs started in the same millisecond newest written first */
    public function listRuns(string $job, int $limit): array;

    public function lastRun(string $job): ?Run;

    /** @return list<Run> oldest first, then in the order they were written */
    public function runningRuns(): array;

    public function getState(string $job): ?JobState;

    /** Write a job's state unconditionally. Used only when compareAndSetState is missing. */
    public function setState(JobState $state): void;

    /** Delete finished runs that started before this time, keeping each job's newest run. Returns how many. */
    public function prune(int|float $before): int;

    public function close(): void;
}
