<?php

declare(strict_types=1);

namespace Cronwatch\Tests\Support;

use Cronwatch\JobDefinition;
use Cronwatch\JobState;
use Cronwatch\Run;
use Cronwatch\Store\Store;
use Cronwatch\StoredJob;

/**
 * Passes every call to another store, unless the method is in $broken (it
 * throws "store down: <method>") or has a hook, which is called with the
 * real method and the arguments. The helpers.ts flaky() store, and the
 * SDK tests' hand-made stores, in one.
 */
class DelegatingStore implements Store
{
    /** @var array<string, true> */
    public array $broken = [];
    /** @var array<string, \Closure(\Closure, list<mixed>): mixed> */
    public array $hooks = [];

    public function __construct(public readonly Store $inner)
    {
    }

    /** @param list<string> $methods */
    public function breaks(array $methods): static
    {
        foreach ($methods as $method) {
            $this->broken[$method] = true;
        }
        return $this;
    }

    protected function call(string $method, array $args): mixed
    {
        if (isset($this->broken[$method])) {
            throw new \RuntimeException("store down: {$method}");
        }
        $next = fn (mixed ...$a) => $this->inner->{$method}(...$a);
        return isset($this->hooks[$method]) ? ($this->hooks[$method])($next, $args) : $next(...$args);
    }

    public function init(): void
    {
        $this->call('init', []);
    }

    public function upsertJob(JobDefinition $definition, int|float $now): void
    {
        $this->call('upsertJob', [$definition, $now]);
    }

    public function getJob(string $name): ?StoredJob
    {
        return $this->call('getJob', [$name]);
    }

    public function listJobs(): array
    {
        return $this->call('listJobs', []);
    }

    public function deleteJob(string $name): void
    {
        $this->call('deleteJob', [$name]);
    }

    public function insertRun(Run $run): void
    {
        $this->call('insertRun', [$run]);
    }

    public function updateRun(Run $run): void
    {
        $this->call('updateRun', [$run]);
    }

    public function getRun(string $id): ?Run
    {
        return $this->call('getRun', [$id]);
    }

    public function listRuns(string $job, int $limit): array
    {
        return $this->call('listRuns', [$job, $limit]);
    }

    public function lastRun(string $job): ?Run
    {
        return $this->call('lastRun', [$job]);
    }

    public function runningRuns(): array
    {
        return $this->call('runningRuns', []);
    }

    public function getState(string $job): ?JobState
    {
        return $this->call('getState', [$job]);
    }

    public function setState(JobState $state): void
    {
        $this->call('setState', [$state]);
    }

    public function prune(int|float $before): int
    {
        return $this->call('prune', [$before]);
    }

    public function close(): void
    {
        $this->call('close', []);
    }
}
