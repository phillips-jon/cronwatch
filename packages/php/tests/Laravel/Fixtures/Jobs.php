<?php

declare(strict_types=1);

namespace Cronwatch\Tests\Laravel\Fixtures;

use Cronwatch\Cronwatch;
use Cronwatch\Laravel\ShouldBeWatched;
use Cronwatch\Watch;
use Illuminate\Bus\Queueable;
use Illuminate\Contracts\Queue\ShouldQueue;
use Illuminate\Foundation\Bus\Dispatchable;
use Illuminate\Queue\InteractsWithQueue;

// Queued jobs and scheduled callables for the Laravel tests, one file for
// all of them (TestCase.php requires it, since PSR-4 finds one class a file).

final class InvokableTask
{
    public function __invoke(): void
    {
    }

    public static function handle(): void
    {
    }
}

final class PlainQueuedJob implements ShouldQueue
{
    use Dispatchable, InteractsWithQueue, Queueable;

    public static int $handled = 0;

    public function handle(): void
    {
        self::$handled++;
    }
}

#[Watch(name: 'nightly-report', grace: '15m', expect: 'Report written', tags: ['nightly'])]
final class WatchedQueuedJob implements ShouldQueue
{
    use Dispatchable, InteractsWithQueue, Queueable;

    public function handle(): void
    {
        Cronwatch::current()?->log('Report written');
    }
}

/** Fails until its attempt number reaches $succeedOn (0: never). */
#[Watch(failuresBeforeAlert: 1)]
final class FlakyJob implements ShouldQueue
{
    use Dispatchable, InteractsWithQueue, Queueable;

    public int $tries = 3;
    public int $backoff = 0;
    public static int $succeedOn = 3;

    public function handle(): void
    {
        if (self::$succeedOn === 0 || $this->attempts() < self::$succeedOn) {
            throw new \RuntimeException("attempt {$this->attempts()} failed");
        }
        Cronwatch::current()?->log("attempt {$this->attempts()} worked");
    }
}

final class InterfaceJob implements ShouldQueue, ShouldBeWatched
{
    use Dispatchable, InteractsWithQueue, Queueable;

    public static function cronwatch(): array
    {
        return ['name' => 'by-interface', 'timeout' => '5m'];
    }

    public function handle(): void
    {
    }
}

#[Watch(enabled: false)]
final class OptedOutJob implements ShouldQueue, ShouldBeWatched
{
    use Dispatchable, InteractsWithQueue, Queueable;

    public function handle(): void
    {
    }
}

/** Throws on the attempts in $failOn, releases itself without an exception on those in $releaseOn, else works. */
#[Watch(name: 'releases', failuresBeforeAlert: 2)]
final class ReleasingJob implements ShouldQueue
{
    use Dispatchable, InteractsWithQueue, Queueable;

    public int $tries = 6;
    public int $backoff = 0;
    /** @var list<int> */
    public static array $failOn = [];
    /** @var list<int> */
    public static array $releaseOn = [1];

    public function handle(): void
    {
        $attempt = $this->attempts();
        if (in_array($attempt, self::$failOn, true)) {
            throw new \RuntimeException("attempt {$attempt} failed");
        }
        if (in_array($attempt, self::$releaseOn, true)) {
            Cronwatch::current()?->log('not now');
            $this->release(0);
            return;
        }
        Cronwatch::current()?->log("attempt {$attempt} worked");
    }
}

/** Released by its middleware before handle() runs, as RateLimited and WithoutOverlapping release a job, for its first $limited attempts. */
#[Watch(name: 'rate-limited')]
final class LimitedJob implements ShouldQueue
{
    use Dispatchable, InteractsWithQueue, Queueable;

    public int $tries = 5;
    public static int $limited = 1;

    public function middleware(): array
    {
        return [function (self $job, callable $next) {
            if ($job->attempts() <= self::$limited) {
                $job->release(0);
                return null;
            }
            return $next($job);
        }];
    }

    public function handle(): void
    {
        Cronwatch::current()?->log('done');
    }
}
