<?php

declare(strict_types=1);

namespace Cronwatch\Tests\Laravel;

use Cronwatch\Tests\Laravel\Fixtures\FlakyJob;
use Cronwatch\Tests\Laravel\Fixtures\InterfaceJob;
use Cronwatch\Tests\Laravel\Fixtures\OptedOutJob;
use Cronwatch\Tests\Laravel\Fixtures\PlainQueuedJob;
use Cronwatch\Tests\Laravel\Fixtures\ReleasingJob;
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

    public function testAJobThatReleasesItselfFailsTheAttempt(): void
    {
        $cw = $this->client();
        ReleasingJob::dispatch();
        $this->work();
        $this->assertSame([['failed', 'Released back onto the queue']], array_map(fn ($r) => [$r->status, $r->error], $cw->runs('releases')));
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
