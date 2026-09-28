<?php

declare(strict_types=1);

namespace Cronwatch;

use Cronwatch\Job\AbortSignal;

/**
 * What a triage function receives. The signal aborts when the client stops
 * waiting; pass what it has left (remainingMs()) to any request made.
 */
final class TriageContext
{
    /** @param list<Run> $recentRuns */
    public function __construct(
        public readonly Alert $alert,
        public readonly array $recentRuns,
        public readonly AbortSignal $signal,
    ) {
    }
}
