<?php

declare(strict_types=1);

namespace Cronwatch\Store;

use Cronwatch\Run;

/** A store that can write a run only while its stored status is one of several, in one step. */
interface UpdatesRunIf
{
    /**
     * Write a run's status, finishedAt, durationMs, error, output and metrics
     * only when its stored status is one of `fromStatuses` (SQL: UPDATE ...
     * WHERE id = ? AND status IN (...)). Returns whether it wrote. This is what
     * lets exactly one of several processes finishing the same run evaluate it.
     *
     * @param list<string> $fromStatuses
     */
    public function updateRunIf(Run $run, array $fromStatuses): bool;
}
