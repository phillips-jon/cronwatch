<?php

declare(strict_types=1);

namespace Cronwatch;

/** A job's summary and its newest runs, as the dashboard shows them. */
final class JobWithRuns
{
    /** @param list<Run> $runs */
    public function __construct(
        public JobSummary $job,
        public array $runs,
    ) {
    }

    public function toJson(): array
    {
        return ['job' => $this->job->toJson(), 'runs' => array_map(fn (Run $r) => $r->toJson(), $this->runs)];
    }
}
