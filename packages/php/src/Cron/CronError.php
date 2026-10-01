<?php

declare(strict_types=1);

namespace Cronwatch\Cron;

/**
 * What croner throws for an expression it will not read, with its message.
 *
 * @internal
 */
final class CronError extends \InvalidArgumentException
{
}
