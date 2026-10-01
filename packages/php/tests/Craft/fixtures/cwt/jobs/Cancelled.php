<?php

declare(strict_types=1);

namespace cwt\jobs;

use Cronwatch\Watch;
use craft\queue\BaseJob;

/** Watched, and cancelled by a listener of EVENT_BEFORE_EXEC registered after the plugin's (see Module). */
#[Watch(name: 'cwt-cancelled')]
final class Cancelled extends BaseJob
{
    public function execute($queue): void
    {
        throw new \RuntimeException('a cancelled job never runs');
    }

    protected function defaultDescription(): ?string
    {
        return 'CronWatch cancelled job';
    }
}
