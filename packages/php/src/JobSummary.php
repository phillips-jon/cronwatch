<?php

declare(strict_types=1);

namespace Cronwatch;

/** A job at a glance: its health, open conditions, last run, next due time and recent stats. */
final class JobSummary
{
    /**
     * @param list<string> $open
     * @param int|float|null $nextExpectedAt when the schedule says the next run is due; null without a schedule
     * @param array{runs: int, okRate: int|float, p50Ms: int|float|null, p95Ms: int|float|null} $stats from the last
     *        twenty runs of any status; p50Ms and p95Ms are over the successful ones among them
     */
    public function __construct(
        public string $name,
        public JobDefinition $definition,
        public string $health,
        public array $open,
        public ?Run $lastRun,
        public int|float|null $nextExpectedAt,
        public int|float $consecutiveFailures,
        public int|float|null $silencedUntil,
        public array $stats,
    ) {
    }

    public function toJson(): array
    {
        return [
            'name' => $this->name,
            'definition' => $this->definition->toJson(),
            'health' => $this->health,
            'open' => array_values($this->open),
            'lastRun' => $this->lastRun?->toJson(),
            'nextExpectedAt' => $this->nextExpectedAt,
            'consecutiveFailures' => $this->consecutiveFailures,
            'silencedUntil' => $this->silencedUntil,
            'stats' => [
                'runs' => $this->stats['runs'],
                'okRate' => $this->stats['okRate'],
                'p50Ms' => $this->stats['p50Ms'],
                'p95Ms' => $this->stats['p95Ms'],
            ],
        ];
    }
}
