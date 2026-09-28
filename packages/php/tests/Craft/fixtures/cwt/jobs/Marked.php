<?php

declare(strict_types=1);

namespace cwt\jobs;

use Cronwatch\Cronwatch;
use Cronwatch\Watch;
use craft\queue\BaseJob;

/** Watched by its attribute, not the settings. */
#[Watch(name: 'cwt-marked', grace: '1h', failuresBeforeAlert: 2)]
final class Marked extends BaseJob
{
    public function execute($queue): void
    {
        Cronwatch::current()?->log('marked ran');
    }

    protected function defaultDescription(): ?string
    {
        return 'CronWatch marked job';
    }
}
