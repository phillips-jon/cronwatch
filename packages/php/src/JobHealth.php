<?php

declare(strict_types=1);

namespace Cronwatch;

/** How a job looks at a glance. */
final class JobHealth
{
    public const HEALTHY = 'healthy';
    public const LATE = 'late';
    public const FAILING = 'failing';
    public const STUCK = 'stuck';
    public const SILENCED = 'silenced';
    public const NEVER_RAN = 'never_ran';
}
