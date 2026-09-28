<?php

declare(strict_types=1);

namespace Cronwatch;

/** When the next run the schedule asks for is due, and when it counts as missed. */
final class Expectation
{
    public function __construct(
        /** When the next run the schedule asks for is due. */
        public readonly int|float $dueAt,
        /** Missed once now passes this. */
        public readonly int|float $deadline,
    ) {
    }

    public function toJson(): array
    {
        return ['dueAt' => $this->dueAt, 'deadline' => $this->deadline];
    }
}
