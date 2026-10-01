<?php

declare(strict_types=1);

namespace Cronwatch;

/**
 * Percentiles and medians, as stats.ts computes them.
 *
 * @internal
 */
final class Stats
{
    /** @param list<int|float> $values */
    public static function percentile(array $values, int|float $p): int|float|null
    {
        if ($values === []) {
            return null;
        }
        sort($values);
        $index = (int) min(count($values) - 1, max(0, ceil(($p / 100) * count($values)) - 1));
        return $values[$index];
    }

    /** @param list<int|float> $values */
    public static function median(array $values): int|float|null
    {
        if ($values === []) {
            return null;
        }
        sort($values);
        $mid = intdiv(count($values), 2);
        return count($values) % 2 === 0 ? ($values[$mid - 1] + $values[$mid]) / 2 : $values[$mid];
    }
}
