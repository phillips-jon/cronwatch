<?php

declare(strict_types=1);

namespace Cronwatch\Symfony;

use Cronwatch\CheckResult;
use Cronwatch\Cronwatch;

/**
 * Handles CheckMessage (and the cronwatch:check command): every scheduled
 * message declared, jobs of messages no longer scheduled declared without
 * their schedule, then the client's check.
 *
 * @internal
 */
final class CheckMessageHandler
{
    /** @param \Closure(): Cronwatch $client */
    public function __construct(private readonly \Closure $client, private readonly ?ScheduledMessages $scheduled = null)
    {
    }

    public function __invoke(CheckMessage $message): CheckResult
    {
        $cw = $this->scheduled !== null ? $this->scheduled->prepare() : ($this->client)();
        return $cw->check();
    }
}
