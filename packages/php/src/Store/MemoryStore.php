<?php

declare(strict_types=1);

namespace Cronwatch\Store;

use Cronwatch\Evaluate;
use Cronwatch\JobDefinition;
use Cronwatch\JobState;
use Cronwatch\Js;
use Cronwatch\Run;
use Cronwatch\RunStatus;
use Cronwatch\StoredJob;

/**
 * Keeps everything in process memory (stores/memory.ts). The default when no
 * store is given, good for tests and for trying the library out. State is
 * gone when the process ends, and a PHP process usually ends with its
 * request or its cron script, so anything real wants SqliteStore or MysqlStore.
 */
final class MemoryStore implements Store, UpdatesRunIf, ComparesAndSetsState, DeletesRunIf
{
    /** @var array<string, StoredJob> */
    private array $jobs = [];
    /** @var array<string, Run> */
    private array $runs = [];
    /** @var array<string, int> */
    private array $order = [];
    /** @var array<string, JobState> */
    private array $states = [];
    private int $seq = 0;

    /**
     * A copy through JSON, as the SDK's memory store makes, so nothing the
     * caller holds is shared and values read back as any store returns them.
     *
     * @template T of Run|StoredJob|JobState
     * @param T $value
     * @return T
     */
    private static function clone(Run|StoredJob|JobState $value): Run|StoredJob|JobState
    {
        $data = Js::parse(Js::stringify($value));
        return $value::fromJson($data);
    }

    public function init(): void
    {
    }

    public function upsertJob(JobDefinition $definition, int|float $now): void
    {
        $name = (string) $definition->get('name');
        $existing = $this->jobs[$name] ?? null;
        $this->jobs[$name] = self::clone(new StoredJob($name, $definition, $existing?->createdAt ?? $now, $now));
    }

    public function getJob(string $name): ?StoredJob
    {
        return isset($this->jobs[$name]) ? self::clone($this->jobs[$name]) : null;
    }

    public function listJobs(): array
    {
        $jobs = array_map(self::clone(...), array_values($this->jobs));
        usort($jobs, fn (StoredJob $a, StoredJob $b) => strcmp($a->name, $b->name));
        return $jobs;
    }

    public function deleteJob(string $name): void
    {
        unset($this->jobs[$name], $this->states[$name]);
        foreach ($this->runs as $id => $run) {
            if ($run->job === $name) {
                unset($this->runs[$id], $this->order[$id]);
            }
        }
    }

    /** Like SQL's primary key: an id already recorded is refused, never overwritten. */
    public function insertRun(Run $run): void
    {
        if (isset($this->runs[$run->id])) {
            throw new \RuntimeException("run {$run->id} already exists");
        }
        $this->runs[$run->id] = self::clone($run);
        $this->order[$run->id] = ++$this->seq;
    }

    /** Like SQL's UPDATE: a run that is gone (its job was forgotten) stays gone, and only these fields change. */
    public function updateRun(Run $run): void
    {
        if (isset($this->runs[$run->id])) {
            $this->runs[$run->id] = self::finishedFields($this->runs[$run->id], $run);
        }
    }

    public function updateRunIf(Run $run, array $fromStatuses): bool
    {
        $existing = $this->runs[$run->id] ?? null;
        if ($existing === null || !in_array($existing->status, $fromStatuses, true)) {
            return false;
        }
        $this->runs[$run->id] = self::finishedFields($existing, $run);
        return true;
    }

    public function deleteRunIf(string $id, string $job, string $status): bool
    {
        $existing = $this->runs[$id] ?? null;
        if ($existing === null || $existing->job !== $job || $existing->status !== $status) {
            return false;
        }
        unset($this->runs[$id], $this->order[$id]);
        return true;
    }

    private static function finishedFields(Run $existing, Run $run): Run
    {
        $copy = self::clone($run);
        $updated = self::clone($existing);
        $updated->status = $copy->status;
        $updated->finishedAt = $copy->finishedAt;
        $updated->durationMs = $copy->durationMs;
        $updated->error = $copy->error;
        $updated->output = $copy->output;
        $updated->metrics = $copy->metrics;
        return $updated;
    }

    public function getRun(string $id): ?Run
    {
        return isset($this->runs[$id]) ? self::clone($this->runs[$id]) : null;
    }

    public function listRuns(string $job, int $limit): array
    {
        $runs = array_values(array_filter($this->runs, fn (Run $r) => $r->job === $job));
        usort($runs, fn (Run $a, Run $b) => [$b->startedAt, $this->order[$b->id]] <=> [$a->startedAt, $this->order[$a->id]]);
        return array_map(self::clone(...), array_slice($runs, 0, max(0, $limit)));
    }

    public function lastRun(string $job): ?Run
    {
        return $this->listRuns($job, 1)[0] ?? null;
    }

    public function runningRuns(): array
    {
        $runs = array_values(array_filter($this->runs, fn (Run $r) => $r->status === RunStatus::RUNNING));
        usort($runs, fn (Run $a, Run $b) => [$a->startedAt, $this->order[$a->id]] <=> [$b->startedAt, $this->order[$b->id]]);
        return array_map(self::clone(...), $runs);
    }

    public function getState(string $job): ?JobState
    {
        return isset($this->states[$job]) ? self::clone($this->states[$job]) : null;
    }

    public function setState(JobState $state): void
    {
        $this->states[$state->job] = self::clone($state);
    }

    public function compareAndSetState(JobState $state, int|float $expectedVersion): bool
    {
        $current = $this->states[$state->job] ?? null;
        if (Evaluate::stateVersion($current) != $expectedVersion) {
            return false;
        }
        $this->states[$state->job] = self::clone($state);
        return true;
    }

    /**
     * Each job's newest run is kept whatever its age: without it, a job that
     * runs less often than the retention looks like it never ran.
     */
    public function prune(int|float $before): int
    {
        $newest = [];
        foreach ($this->runs as $run) {
            $newest[$run->job] = max($newest[$run->job] ?? $run->startedAt, $run->startedAt);
        }
        $n = 0;
        foreach ($this->runs as $id => $run) {
            if ($run->status !== RunStatus::RUNNING && $run->startedAt < $before && $run->startedAt < $newest[$run->job]) {
                unset($this->runs[$id], $this->order[$id]);
                $n++;
            }
        }
        return $n;
    }

    public function close(): void
    {
    }
}
