<?php

declare(strict_types=1);

namespace Cronwatch\Tests\Support;

/** A clock the tests move by hand. */
final class Clock
{
    /** Monday 2026-01-05 09:30:00Z. */
    public const T0 = 1767605400000;
    public const MIN = 60_000;
    public const HOUR = 3_600_000;

    public function __construct(public int|float $now = self::T0)
    {
    }

    public function __invoke(): int|float
    {
        return $this->now;
    }

    public function advance(int|float $ms): int|float
    {
        return $this->now += $ms;
    }

    public function set(int|float $at): void
    {
        $this->now = $at;
    }
}
