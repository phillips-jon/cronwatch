<?php

declare(strict_types=1);

namespace Cronwatch\Store;

use Cronwatch\JobState;

/** A store that can write a job's state only over the version the writer read. */
interface ComparesAndSetsState
{
    /**
     * Write `state` only when the stored state's version (absent, or no row at
     * all, counts as 0) equals `expectedVersion`. Returns whether it wrote.
     * This keeps two processes sharing a store from overwriting each other's
     * updates: the client reads, computes, and on a refused write reads again.
     */
    public function compareAndSetState(JobState $state, int|float $expectedVersion): bool;
}
