<?php

declare(strict_types=1);

namespace Cronwatch;

/** What a job can be: each opens once, alerts, and closes with a recovery. */
final class Condition
{
    public const MISSED = 'missed';
    public const FAILED = 'failed';
    public const STUCK = 'stuck';
    public const SLOW = 'slow';
    public const OVER_BUDGET = 'over_budget';
    public const UNDER_FLOOR = 'under_floor';

    public const ALL = [self::MISSED, self::FAILED, self::STUCK, self::SLOW, self::OVER_BUDGET, self::UNDER_FLOOR];
}
