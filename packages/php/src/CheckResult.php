<?php

declare(strict_types=1);

namespace Cronwatch;

/** What a check found: every job's summary, the alerts it sent, and how many old runs it pruned. */
final class CheckResult
{
    /**
     * @param list<JobSummary> $jobs
     * @param list<Alert> $alerts
     */
    public function __construct(
        public int|float $checkedAt,
        public array $jobs,
        public array $alerts,
        public int $pruned,
    ) {
    }

    /** The line every port's check command prints: "cronwatch: checked 3 jobs, sent 1 alert". */
    public function summary(): string
    {
        $jobs = count($this->jobs);
        $alerts = count($this->alerts);
        return "cronwatch: checked {$jobs} job" . ($jobs === 1 ? '' : 's') . ", sent {$alerts} alert" . ($alerts === 1 ? '' : 's');
    }

    public function toJson(): array
    {
        return [
            'checkedAt' => $this->checkedAt,
            'jobs' => array_map(fn (JobSummary $j) => $j->toJson(), $this->jobs),
            'alerts' => array_map(fn (Alert $a) => $a->toJson(), $this->alerts),
            'pruned' => $this->pruned,
        ];
    }
}
