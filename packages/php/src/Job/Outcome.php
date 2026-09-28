<?php

declare(strict_types=1);

namespace Cronwatch\Job;

use Cronwatch\Run;

/**
 * How one execute() ended: the run as recorded, and what the function
 * returned or threw.
 *
 * @internal
 */
final class Outcome
{
    public function __construct(
        public readonly Run $run,
        public readonly mixed $result,
        public readonly mixed $error,
        public readonly bool $threw,
    ) {
    }
}
