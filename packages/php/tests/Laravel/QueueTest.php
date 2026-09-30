<?php

declare(strict_types=1);

namespace Cronwatch\Tests\Laravel;

use Cronwatch\Cronwatch;
use Cronwatch\Tests\Laravel\Fixtures\AttributeDescribedJob;
use Cronwatch\Tests\Laravel\Fixtures\FlakyJob;
use Cronwatch\Tests\Laravel\Fixtures\InterfaceJob;
use Cronwatch\Tests\Laravel\Fixtures\LimitedJob;
use Cronwatch\Tests\Laravel\Fixtures\MethodDescribedJob;
use Cronwatch\Tests\Laravel\Fixtures\OptedOutJob;
use Cronwatch\Tests\Laravel\Fixtures\PlainQueuedJob;
use Cronwatch\Tests\Laravel\Fixtures\ReleasingJob;
use Cronwatch\Tests\Laravel\Fixtures\SkippableJob;
use Cronwatch\Tests\Laravel\Fixtures\WatchedQueuedJob;
use Orchestra\Testbench\Attributes\DefineEnvironment;

/**
 * Queued jobs that opt in, through a real worker (`queue:work --once` on
 * the database queue) and the sync queue: each attempt a run, retries
 * failing until one succeeds, and jobs that do not opt in left alone.
 */
final class QueueTest extends TestCase
{

    protected function defineDatabaseMigrations(): void
    {
        $this->loadLaravelMigrations();
    }

    protected function defineEnvironment($app): void
    {
        parent::defineEnvironment($app);
        $app['config']->set('queue.default', 'database');
        $app['config']->set('queue.connections.database', ['driver' => 'database', 'table' => 'jobs', 'queue' => 'default', 'retry_after' => 90]);
    }

    private function work(int $times = 1): void
    {
        for ($i = 0; $i < $times; $i++) {
            $this->artisan('queue:work', ['--once' => true, '--tries' => 3, '--backoff' => 0])->assertExitCode(0);
        }
    }

    public function testEachAttemptIsARunAndTheOneThatSucceedsRecovers(): void
    {
        $cw = $this->client();
        FlakyJob::$succeedOn = 3;
        FlakyJob::dispatch();
        $this->work(3);
        $name = 'Cronwatch.Tests.Laravel.Fixtures.FlakyJob';
        $runs = array_reverse($cw->runs($name));
        $this->assertSame(['failed', 'failed', 'ok'], array_map(fn ($r) => $r->status, $runs));
        $this->assertSame(['queue', 'queue', 'queue'], array_map(fn ($r) => $r->trigger, $runs));
        $this->assertStringStartsWith('RuntimeException: attempt 1 failed', $runs[0]->error);
        $this->assertStringStartsWith('RuntimeException: attempt 2 failed', $runs[1]->error);
        $this->assertSame('attempt 3 worked', $runs[2]->output);
        $this->assertSame(['failed', 'recovered'], $this->capture->types(), 'one failed alert, closed by the success');
        $uuid = explode(':', $runs[0]->id)[0];
        $this->assertMatchesRegularExpression('/^[0-9a-f-]{36}:[0-9a-f]{12}$/', $runs[0]->id);
        $this->assertSame([$uuid, $uuid], [explode(':', $runs[1]->id)[0], explode(':', $runs[2]->id)[0]], 'the attempts share the job\'s uuid');
        $this->assertSame(['laravel-queue'], $cw->store->getJob($name)->definition->get('tags'));
    }

    public function testTheLastAttemptFailingIsAFailedRunOnce(): void
    {
        $cw = $this->client();
        FlakyJob::$succeedOn = 0;
        FlakyJob::dispatch();
        $this->work(4);
        $runs = $cw->runs('Cronwatch.Tests.Laravel.Fixtures.FlakyJob');
        $this->assertSame(['failed', 'failed', 'failed'], array_map(fn ($r) => $r->status, $runs));
        $this->assertStringStartsWith('RuntimeException: attempt 3 failed', $runs[0]->error, 'JobFailed and JobExceptionOccurred end it once');
        $this->assertSame(['failed'], $this->capture->types());
        $this->assertSame([], $this->errors);
    }

    public function testAJobReleasedWithoutAnExceptionLeavesNoRun(): void
    {
        $cw = $this->client();
        ReleasingJob::$failOn = [];
        ReleasingJob::$releaseOn = [1];
        ReleasingJob::dispatch();
        $this->work();
        $this->assertSame([], $cw->runs('releases'), 'the released attempt is taken back');
        $this->assertNotNull($cw->store->getJob('releases'), 'the job is still declared');
        $this->work();
        $this->assertSame([['ok', 'attempt 2 worked']], array_map(fn ($r) => [$r->status, $r->output], $cw->runs('releases')));
        $this->assertSame([], $this->capture->types());
        $this->assertSame([], $this->errors);
    }

    public function testAReleaseNeitherFailsNorRecovers(): void
    {
        // failuresBeforeAlert: 2. Failures on either side of a release are
        // two in a row, and the release closes nothing.
        $cw = $this->client();
        ReleasingJob::$failOn = [1, 3];
        ReleasingJob::$releaseOn = [2, 4];
        ReleasingJob::dispatch();
        $this->work(2);
        $this->assertSame(['failed'], array_map(fn ($r) => $r->status, $cw->runs('releases')));
        $this->assertSame([], $this->capture->types(), 'one failure is not yet two');
        $this->work();
        $this->assertSame(['failed', 'failed'], array_map(fn ($r) => $r->status, $cw->runs('releases')));
        $this->assertSame(['failed'], $this->capture->types(), 'the release did not reset the count');
        $this->work();
        $this->assertSame(['failed'], $this->capture->types(), 'a release does not recover');
        $this->assertSame('failing', $cw->jobSummary('releases')->health);
        $this->work();
        $this->assertSame(['ok', 'failed', 'failed'], array_map(fn ($r) => $r->status, $cw->runs('releases')));
        $this->assertSame(['failed', 'recovered'], $this->capture->types());
        $this->assertSame([], $this->errors);
    }

    public function testAJobReleasedByItsMiddlewareLeavesNoRun(): void
    {
        $cw = $this->client();
        LimitedJob::$limited = 2;
        LimitedJob::dispatch();
        $this->work(2);
        $this->assertSame([], $cw->runs('rate-limited'));
        $this->work();
        $this->assertSame([['ok', 'done']], array_map(fn ($r) => [$r->status, $r->output], $cw->runs('rate-limited')));
        $this->assertSame([], $this->capture->types());
        $this->assertSame([], $this->errors);
    }

    public function testAJobItsMiddlewareSkipsWithoutReleasingLeavesNoRun(): void
    {
        $cw = $this->client();
        $statuses = fn () => array_map(fn ($r) => $r->status, $cw->runs('skippable'));
        SkippableJob::$mode = 'fail';
        SkippableJob::dispatch();
        $this->work();
        $this->work();
        $this->work();
        $this->assertSame(['failed', 'failed', 'failed'], $statuses());
        $this->assertSame(['failed'], $this->capture->types());

        SkippableJob::$mode = 'skip';
        SkippableJob::dispatch();
        $this->work();
        $this->assertSame(0, \Illuminate\Support\Facades\DB::table('jobs')->count(), 'Laravel deleted the skipped job');
        $this->assertSame(['failed', 'failed', 'failed'], $statuses(), 'the skipped attempt is taken back');
        $this->assertSame(['failed'], $this->capture->types(), 'a skip is not a recovery');

        SkippableJob::$mode = 'ok';
        SkippableJob::dispatch();
        $this->work();
        $this->assertSame(['ok', 'failed', 'failed', 'failed'], $statuses());
        $this->assertSame('worked', $cw->runs('skippable')[0]->output);
        $this->assertSame(['failed', 'recovered'], $this->capture->types());

        // On the sync queue too, and a bus pipe the app sets later is kept with CronWatch's.
        $this->app['config']->set('queue.default', 'sync');
        $seen = [];
        $bus = $this->app->make(\Illuminate\Contracts\Bus\Dispatcher::class);
        $bus->pipeThrough([function ($command, $next) use (&$seen) {
            $seen[] = $command::class;
            return $next($command);
        }]);
        SkippableJob::$mode = 'skip';
        SkippableJob::dispatch();
        SkippableJob::$mode = 'ok';
        SkippableJob::dispatch();
        $this->assertSame(['ok', 'ok', 'failed', 'failed', 'failed'], $statuses());
        $this->assertSame([SkippableJob::class], $seen, 'the app\'s pipe still runs');
        $this->assertSame([], $this->errors);
    }

    public function testAWatchedJobsOwnDescriptionWins(): void
    {
        $cw = $this->client();
        AttributeDescribedJob::dispatch();
        MethodDescribedJob::dispatch();
        $this->work(2);
        $this->assertSame('Sends the nightly digest', $cw->store->getJob('described-by-attribute')->definition->get('description'));
        $this->assertSame('Rebuilds the search index', $cw->store->getJob('described-by-method')->definition->get('description'));
        $this->assertSame('Queued job ' . InterfaceJob::class, (new \Cronwatch\Laravel\QueueWatcher($this->app))->definition(InterfaceJob::class)[1]['description'], 'the default, for a job with none');
    }

    public function testATakenBackRunLeavesMissedOpenAndAlertedOnce(): void
    {
        $cw = $this->client();
        $handle = $cw->job('hourly-queue', ['schedule' => '0 * * * *', 'timezone' => 'UTC']);
        $cw->check();
        $this->clock->advance(2 * 3600_000);
        $cw->check();
        $this->assertSame(['missed'], $this->capture->types());
        $key = $cw->startExecution($handle->definition, 'queue', mayDiscard: true);
        $this->assertTrue($cw->discardExecution($key));
        $this->clock->advance(60_000);
        $cw->check();
        $this->assertSame(['missed'], $this->capture->types(), 'not missed again: it never closed');
        $key = $cw->startExecution($handle->definition, 'queue', mayDiscard: true);
        $this->assertSame('ok', $cw->finishExecution($key)->status);
        $this->assertSame(['missed', 'recovered'], $this->capture->types(), 'the start closes missed when the run is judged');
        $this->assertSame([], $this->errors);
    }

    public function testATakenBackRunThatACheckAlreadyMarkedStuckIsLeftAndReported(): void
    {
        $cw = $this->client(['store' => new \Cronwatch\Store\MemoryStore()]);
        $handle = $cw->job('released', ['timeout' => '1m']);
        $key = $cw->startExecution($handle->definition, 'queue', 'x:1');
        $this->clock->advance(120_000);
        $cw->check();
        $this->assertFalse($cw->discardExecution($key));
        $this->assertSame('timeout', $cw->getRun('x:1')->status);
        $this->assertSame(['discarding released'], $this->wheres());
        $this->assertNull(Cronwatch::current());
    }

    public function testOnlyJobsThatOptInAreWatched(): void
    {
        $cw = $this->client();
        PlainQueuedJob::dispatch();
        OptedOutJob::dispatch();
        InterfaceJob::dispatch();
        WatchedQueuedJob::dispatch();
        $this->work(4);
        $this->assertSame(['by-interface', 'nightly-report'], array_map(fn ($j) => $j->name, $cw->jobs()));
        $this->assertSame('5m', $cw->store->getJob('by-interface')->definition->get('timeout'));
        $this->assertSame(['ok', 'Report written'], [$cw->runs('nightly-report')[0]->status, $cw->runs('nightly-report')[0]->output]);
    }

    public function testTheSyncQueueIsWatchedToo(): void
    {
        $this->app['config']->set('queue.default', 'sync');
        $cw = $this->client();
        WatchedQueuedJob::dispatch();
        FlakyJob::$succeedOn = 0;
        try {
            FlakyJob::dispatch();
            $this->fail('the sync queue throws');
        } catch (\RuntimeException) {
        }
        $this->assertSame('ok', $cw->runs('nightly-report')[0]->status);
        $this->assertSame('failed', $cw->runs('Cronwatch.Tests.Laravel.Fixtures.FlakyJob')[0]->status);
    }

    protected function queueOff($app): void
    {
        $app['config']->set('cronwatch.queue.watch', false);
    }

    #[DefineEnvironment('queueOff')]
    public function testQueueWatchingCanBeTurnedOff(): void
    {
        $cw = $this->client();
        WatchedQueuedJob::dispatch();
        $this->work();
        $this->assertSame([], $cw->jobs());
    }
}
