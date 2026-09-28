<?php

declare(strict_types=1);

namespace Cronwatch\Job;

/**
 * The store failed part way through a finish and nothing was recorded
 * (already reported): the handle stays active to be finished again.
 *
 * @internal
 */
final class RetryFinish extends \RuntimeException
{
}
