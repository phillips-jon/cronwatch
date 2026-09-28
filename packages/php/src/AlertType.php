<?php

declare(strict_types=1);

namespace Cronwatch;

/** An alert's type: a condition that opened, or a recovery. */
final class AlertType
{
    public const MISSED = 'missed';
    public const FAILED = 'failed';
    public const STUCK = 'stuck';
    public const SLOW = 'slow';
    public const OVER_BUDGET = 'over_budget';
    public const RECOVERED = 'recovered';
}
