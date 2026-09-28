<?php

declare(strict_types=1);

namespace cwt\jobs;

use Cronwatch\Cronwatch;
use Craft;
use craft\queue\BaseJob;
use yii\queue\RetryableJobInterface;

/**
 * Fails until its attempt number reaches succeedOn. Listed in the settings'
 * queueJobs. A one second time to reserve, so a failed attempt is retried
 * as soon as the next `queue/run` after it.
 */
final class Flaky extends BaseJob implements RetryableJobInterface
{
    public string $key = '';
    public int $succeedOn = 1;

    public function execute($queue): void
    {
        $cache = Craft::$app->getCache();
        $attempt = (int) $cache->get("cwt-attempts-{$this->key}") + 1;
        $cache->set("cwt-attempts-{$this->key}", $attempt);
        Cronwatch::current()?->log("job {$this->key} attempt {$attempt}");
        if ($attempt < $this->succeedOn) {
            throw new \RuntimeException("job {$this->key} failed attempt {$attempt}");
        }
    }

    public function getTtr(): int
    {
        return 1;
    }

    public function canRetry($attempt, $error): bool
    {
        return $attempt < 5;
    }

    protected function defaultDescription(): ?string
    {
        return 'CronWatch flaky job';
    }
}
