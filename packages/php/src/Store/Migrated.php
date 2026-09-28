<?php

declare(strict_types=1);

namespace Cronwatch\Store;

use Cronwatch\JobDefinition;
use Cronwatch\JobState;
use Cronwatch\Run;
use Cronwatch\StoredJob;

/**
 * A store whose tables a migration made: every call goes to the store
 * given, but init(), which would run CREATE TABLE IF NOT EXISTS, does
 * nothing. For an app whose database user may not create tables at run
 * time (the framework integrations use it when told the migration ran).
 */
final class Migrated implements Store, UpdatesRunIf, ComparesAndSetsState, DeletesRunIf
{
    public function __construct(public readonly Store&UpdatesRunIf&ComparesAndSetsState $inner)
    {
    }

    public function init(): void
    {
    }

    public function upsertJob(JobDefinition $definition, int|float $now): void
    {
        $this->inner->upsertJob($definition, $now);
    }

    public function getJob(string $name): ?StoredJob
    {
        return $this->inner->getJob($name);
    }

    public function listJobs(): array
    {
        return $this->inner->listJobs();
    }

    public function deleteJob(string $name): void
    {
        $this->inner->deleteJob($name);
    }

    public function insertRun(Run $run): void
    {
        $this->inner->insertRun($run);
    }

    public function updateRun(Run $run): void
    {
        $this->inner->updateRun($run);
    }

    public function updateRunIf(Run $run, array $fromStatuses): bool
    {
        return $this->inner->updateRunIf($run, $fromStatuses);
    }

    /** False when the store given cannot delete a run. */
    public function deleteRunIf(string $id, string $job, string $status): bool
    {
        return $this->inner instanceof DeletesRunIf && $this->inner->deleteRunIf($id, $job, $status);
    }

    public function getRun(string $id): ?Run
    {
        return $this->inner->getRun($id);
    }

    public function listRuns(string $job, int $limit): array
    {
        return $this->inner->listRuns($job, $limit);
    }

    public function lastRun(string $job): ?Run
    {
        return $this->inner->lastRun($job);
    }

    public function runningRuns(): array
    {
        return $this->inner->runningRuns();
    }

    public function getState(string $job): ?JobState
    {
        return $this->inner->getState($job);
    }

    public function setState(JobState $state): void
    {
        $this->inner->setState($state);
    }

    public function compareAndSetState(JobState $state, int|float $expectedVersion): bool
    {
        return $this->inner->compareAndSetState($state, $expectedVersion);
    }

    public function prune(int|float $before): int
    {
        return $this->inner->prune($before);
    }

    public function close(): void
    {
        $this->inner->close();
    }
}
