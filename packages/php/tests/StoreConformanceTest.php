<?php

declare(strict_types=1);

namespace Cronwatch\Tests;

use Cronwatch\Alert;
use Cronwatch\JobDefinition;
use Cronwatch\JobState;
use Cronwatch\Js;
use Cronwatch\Run;
use Cronwatch\Store\ComparesAndSetsState;
use Cronwatch\Store\MemoryStore;
use Cronwatch\Store\SqliteStore;
use Cronwatch\Store\Store;
use Cronwatch\Store\UpdatesRunIf;
use Cronwatch\Tests\Support\Backend;
use PHPUnit\Framework\Attributes\DataProvider;
use PHPUnit\Framework\TestCase;

/**
 * The test every store passes (store-conformance.ts): memory, SQLite in
 * memory and on disk, MySQL and MariaDB. Copy it to check a store of your own.
 */
final class StoreConformanceTest extends TestCase
{
    public static function makeRun(string $id, string $job, string $status, int $startedAt): Run
    {
        $running = $status === 'running';
        return new Run($id, $job, $status, $startedAt, $running ? null : $startedAt + 10, $running ? null : 10, null, null, ['n' => 1], 'run');
    }

    private static function with(Run $run, array $fields): Run
    {
        $copy = clone $run;
        foreach ($fields as $key => $value) {
            $copy->{$key} = $value;
        }
        return $copy;
    }

    public static function stores(): iterable
    {
        yield 'memory' => ['memory'];
        yield 'sqlite in memory' => ['sqlite-memory'];
        yield 'sqlite on disk' => ['sqlite'];
        yield 'mysql' => ['mysql'];
        yield 'mariadb' => ['mariadb'];
    }

    /** @return array{Store, \Closure(): void} */
    private function open(string $kind): array
    {
        if ($kind === 'memory') {
            return [new MemoryStore(), fn () => null];
        }
        if ($kind === 'sqlite-memory') {
            return [new SqliteStore(':memory:'), fn () => null];
        }
        $why = Backend::unavailable($kind);
        if ($why !== null) {
            $this->markTestSkipped($why);
        }
        $backend = Backend::make($kind);
        return [$backend->open(), $backend->done(...)];
    }

    #[DataProvider('stores')]
    public function testStoreConformance(string $kind): void
    {
        [$store, $done] = $this->open($kind);
        try {
            $this->conformance($store);
        } finally {
            $done();
        }
    }

    private static function names(array $items): array
    {
        return array_map(fn ($item) => $item instanceof Run ? $item->id : $item->name, $items);
    }

    private function conformance(Store $store): void
    {
        $this->assertInstanceOf(UpdatesRunIf::class, $store);
        $this->assertInstanceOf(ComparesAndSetsState::class, $store);
        $store->init();
        $this->assertNull($store->getJob('a'));
        $store->upsertJob(new JobDefinition(['name' => 'a', 'schedule' => 'every 5m']), 100);
        $store->upsertJob(new JobDefinition(['name' => 'a', 'schedule' => 'every 10m', 'tags' => ['x']]), 200);
        $store->upsertJob(new JobDefinition(['name' => 'b']), 300);
        $store->upsertJob(new JobDefinition(['name' => 'B']), 300);
        $store->upsertJob(new JobDefinition(['name' => '_c']), 300);
        $a = $store->getJob('a');
        $this->assertSame(100, $a->createdAt, 'createdAt survives upsert');
        $this->assertSame(200, $a->updatedAt);
        $this->assertSame('{"name":"a","schedule":"every 10m","tags":["x"]}', Js::stringify($a->definition));
        $this->assertSame(['B', '_c', 'a', 'b'], self::names($store->listJobs()), 'code unit order, not locale');

        $store->insertRun(self::makeRun('r1', 'a', 'ok', 1000));
        $store->insertRun(self::makeRun('r2', 'a', 'failed', 2000));
        $store->insertRun(self::makeRun('r3', 'a', 'running', 3000));
        $store->insertRun(self::makeRun('r4', 'b', 'ok', 1500));
        $store->insertRun(self::makeRun('rb', 'B', 'running', 2000));
        $store->insertRun(self::makeRun('rc', '_c', 'running', 2000));
        $this->assertSame(['r3', 'r2', 'r1'], self::names($store->listRuns('a', 10)));
        $this->assertSame(['r3', 'r2'], self::names($store->listRuns('a', 2)));
        $this->assertSame('r3', $store->lastRun('a')->id);
        $this->assertNull($store->lastRun('none'));
        $this->assertSame(['rb', 'rc', 'r3'], self::names($store->runningRuns()), 'oldest first, then insertion order');
        $r1 = $store->getRun('r1');
        $this->assertSame(['n' => 1], $r1->metrics);
        $this->assertSame(10, $r1->durationMs);

        $store->updateRun(self::with(self::makeRun('r3', 'a', 'ok', 3000), ['output' => "line1\nline2", 'error' => null, 'metrics' => ['cost' => 0.25]]));
        $r3 = $store->getRun('r3');
        $this->assertSame('ok', $r3->status);
        $this->assertSame("line1\nline2", $r3->output);
        $this->assertSame(['cost' => 0.25], $r3->metrics);
        $this->assertSame(['rb', 'rc'], self::names($store->runningRuns()));

        // updateRunIf: writes only over a row whose status is one of those given, and says whether it did.
        try {
            $store->insertRun(self::makeRun('r3', 'a', 'running', 3000));
            $this->fail('an id already recorded is refused');
        } catch (\Throwable $error) {
            $this->assertNotInstanceOf(\PHPUnit\Framework\AssertionFailedError::class, $error);
        }
        $store->upsertJob(new JobDefinition(['name' => 'q']), 300);
        $store->insertRun(self::makeRun('rx', 'q', 'running', 2500));
        $this->assertTrue($store->updateRunIf(self::with(self::makeRun('rx', 'q', 'failed', 2500), ['error' => 'first']), ['running']));
        $this->assertFalse($store->updateRunIf(self::with(self::makeRun('rx', 'q', 'ok', 2500), ['output' => 'second']), ['running']), 'a second finish over the first is refused');
        $this->assertSame('first', $store->getRun('rx')->error);
        $this->assertFalse($store->updateRunIf(self::with(self::makeRun('rx', 'q', 'ok', 2500), ['output' => 'late']), ['running', 'timeout']));
        $store->updateRun(self::with(self::makeRun('rx', 'q', 'timeout', 2500), ['error' => 'stuck']));
        $this->assertTrue($store->updateRunIf(self::with(self::makeRun('rx', 'q', 'ok', 2500), ['output' => 'late', 'metrics' => ['m' => 2]]), ['running', 'timeout']), 'any of the statuses given');
        $late = $store->getRun('rx');
        $this->assertSame(['ok', 'late', null, ['m' => 2], 'q', 'run'], [$late->status, $late->output, $late->error, $late->metrics, $late->job, $late->trigger]);
        $this->assertFalse($store->updateRunIf(self::makeRun('missing', 'q', 'ok', 1), ['running']), 'a run that is not there is not written');
        $this->assertNull($store->getRun('missing'));
        $this->assertFalse($store->updateRunIf(self::makeRun('rx', 'q', 'failed', 2500), []), 'no statuses, no write');
        $this->assertSame('ok', $store->getRun('rx')->status);
        $store->deleteJob('q');

        // Forgetting a job while one of its runs is in flight: the run finishing later changes nothing.
        $store->deleteJob('B');
        $store->updateRun(self::with(self::makeRun('rb', 'B', 'ok', 2000), ['output' => 'late']));
        $this->assertNull($store->getRun('rb'));
        $this->assertSame([], $store->listRuns('B', 10));
        $this->assertSame(['rc'], self::names($store->runningRuns()));
        $store->deleteJob('_c');

        $this->assertNull($store->getState('a'));
        $store->setState(new JobState('a', ['failed' => 5], 2, null, 6));
        $store->setState(new JobState('a', [], 0, 99, 6));
        $this->assertSame('{"job":"a","open":{},"consecutiveFailures":0,"silencedUntil":99,"lastAlertAt":6}', Js::stringify($store->getState('a')));
        $undelivered = new Alert('failed', null, ['consecutiveFailures' => 1], 'a', new JobDefinition(['name' => 'a']), 'a failed', 'boom', 7);
        $full = new JobState('a', ['stuck' => 7], 1, null, 6, ['missed'], [$undelivered]);
        $store->setState($full);
        $this->assertSame(Js::stringify($full), Js::stringify($store->getState('a')), 'pendingRecovery and undelivered round-trip');
        $store->setState(new JobState('a', [], 0, 99, 6));

        // compareAndSetState: writes only over the version it was told to expect.
        $v = fn (int $version, int $failures = 0, string $job = 'v') => new JobState($job, [], $failures, null, null, null, null, $version);
        $this->assertFalse($store->compareAndSetState($v(2), 1), 'no row matches only version 0');
        $this->assertNull($store->getState('v'));
        $this->assertTrue($store->compareAndSetState($v(1), 0), 'no row counts as version 0');
        $this->assertFalse($store->compareAndSetState($v(1, 9), 0), 'a write from a stale read is refused');
        $this->assertTrue($store->compareAndSetState($v(2, 1), 1));
        $this->assertFalse($store->compareAndSetState($v(3), 1));
        $this->assertSame(Js::stringify($v(2, 1)), Js::stringify($store->getState('v')));
        $store->setState(new JobState('w', [], 3));
        $this->assertFalse($store->compareAndSetState($v(1, 0, 'w'), 1), 'state written before versions counts as 0');
        $this->assertTrue($store->compareAndSetState($v(1, 0, 'w'), 0));
        $this->assertSame(1, $store->getState('w')->version);
        $store->deleteJob('v');
        $this->assertFalse($store->compareAndSetState($v(3), 2), "a forgotten job's state is not written back");
        $this->assertNull($store->getState('v'));
        $store->deleteJob('w');

        $store->insertRun(self::makeRun('r5', 'a', 'running', 500));
        $this->assertSame(2, $store->prune(2500), "r1 and r2 pruned; running r5 kept, and b's r4 kept as b's newest run");
        $this->assertSame(['r3', 'r5'], self::names($store->listRuns('a', 10)));
        $this->assertSame(['r4'], self::names($store->listRuns('b', 10)));
        $this->assertSame(0, $store->prune(1_000_000), 'however old, each job keeps its newest run, and running runs stay');

        $store->deleteJob('a');
        $this->assertNull($store->getJob('a'));
        $this->assertSame([], $store->listRuns('a', 10));
        $this->assertNull($store->getState('a'));
        $this->assertSame('b', $store->getJob('b')->name);
        $store->close();
    }
}
