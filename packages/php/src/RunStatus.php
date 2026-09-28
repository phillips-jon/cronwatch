<?php

declare(strict_types=1);

namespace Cronwatch;

/** A run's status, as the wire string. */
final class RunStatus
{
    public const RUNNING = 'running';
    public const OK = 'ok';
    public const FAILED = 'failed';
    public const TIMEOUT = 'timeout';
}
