<?php

declare(strict_types=1);

namespace Cronwatch\Tests\Support;

use Cronwatch\JobState;
use Cronwatch\Run;
use Cronwatch\Store\ComparesAndSetsState;
use Cronwatch\Store\UpdatesRunIf;

/** A DelegatingStore with the conditional writes too, as every store of this package has them. */
final class FlakyStore extends DelegatingStore implements UpdatesRunIf, ComparesAndSetsState
{
    public function updateRunIf(Run $run, array $fromStatuses): bool
    {
        return $this->call('updateRunIf', [$run, $fromStatuses]);
    }

    public function compareAndSetState(JobState $state, int|float $expectedVersion): bool
    {
        return $this->call('compareAndSetState', [$state, $expectedVersion]);
    }
}
