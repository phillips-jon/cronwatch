<?php

declare(strict_types=1);

namespace Cronwatch\Tests;

use Cronwatch\Cronwatch;
use Cronwatch\Run;
use Cronwatch\Store\MemoryStore;
use Cronwatch\Store\SqliteStore;
use Cronwatch\Store\Store;
use Cronwatch\Store\UpdatesRunIf;
use Cronwatch\Tests\Support\Capture;
use Cronwatch\Tests\Support\Clock;
use Cronwatch\Tests\Support\DelegatingStore;
use Cronwatch\Tests\Support\FlakyStore;
use PHPUnit\Framework\TestCase;

/**
 * concurrency.test.ts in one process. The SDK's slowReads store lets two
 * clients read a job's state before either writes; here the same moment is
 * made on purpose: the first client's read of the state lets the second
 * client do its whole run before the first goes on to write. FinishOnceTest
 * has the same race with real processes.
 */
final class ConcurrencyTest extends TestCase
{
    /**
     * Two clients, as two processes sharing one store, each failing the job
     * once "at the same time": the second fails while the first is between
     * reading the state and writing it.
     *
     * @return array{\Cronwatch\JobState, list<string>}
     */
    private function race(DelegatingStore $storeA, Store $storeB): array
    {
        $clock = new Clock();
        $a = new Capture();
        $b = new Capture();
        $one = new Cronwatch(store: $storeA, now: $clock, alerts: [$a], cronSecret: false);
        $two = new Cronwatch(store: $storeB, now: $clock, alerts: [$b], cronSecret: false);
        $options = ['failuresBeforeAlert' => 2];
        $one->run('shared', fn () => null, $options);
        $two->job('shared', $options);
        $reads = 0;
        $storeA->hooks['getState'] = function (\Closure $next, array $args) use (&$reads, $two) {
            $state = $next(...$args);
            // The evaluation of the failure (the second read of the run): the other process fails meanwhile.
            if (++$reads === 2) {
                try {
                    $two->run('shared', function (): never {
                        throw new \RuntimeException('two');
                    });
                } catch (\RuntimeException) {
                }
            }
            return $state;
        };
        try {
            $one->run('shared', function (): never {
                throw new \RuntimeException('one');
            });
        } catch (\RuntimeException) {
        }
        return [$storeA->getState('shared'), [...$a->types(), ...$b->types()]];
    }

    public function testTwoProcessesFailingAJobAtOnceBothFailuresCountAndTheAlertGoesOutOnce(): void
    {
        $store = new MemoryStore();
        [$state, $types] = $this->race(new FlakyStore($store), $store);
        $this->assertSame(2, $state->consecutiveFailures, 'neither failure was lost');
        $this->assertSame(['failed'], array_keys($state->open), 'the condition opened');
        $this->assertSame(['failed'], $types, 'one alert, from whichever process counted the second failure');
        $this->assertGreaterThanOrEqual(3, $state->version, "every write bumped the version ({$state->version})");
    }

    public function testTheSameRaceThroughTwoSqliteConnectionsToOneFile(): void
    {
        $file = sys_get_temp_dir() . '/cronwatch-race-' . getmypid() . '-' . bin2hex(random_bytes(4)) . '.db';
        try {
            [$state, $types] = $this->race(new FlakyStore(new SqliteStore($file)), new SqliteStore($file));
            $this->assertSame(2, $state->consecutiveFailures);
            $this->assertSame(['failed'], $types);
        } finally {
            foreach ([$file, "{$file}-wal", "{$file}-shm"] as $f) {
                @unlink($f);
            }
        }
    }

    public function testACustomStoreWithoutCompareAndSetStateStillWorksButCannotKeepTwoProcessesApart(): void
    {
        $store = new MemoryStore();
        $plain = fn () => new class ($store) extends DelegatingStore implements UpdatesRunIf {
            public function updateRunIf(Run $run, array $fromStatuses): bool
            {
                return $this->inner->updateRunIf($run, $fromStatuses);
            }
        };
        [$state, $types] = $this->race($plain(), $plain());
        // The documented caveat: the later write wins, so one failure is lost.
        $this->assertSame(1, $state->consecutiveFailures);
        $this->assertSame([], $types);
    }

    public function testASilenceMadeByOneProcessSurvivesAnotherProcesssRun(): void
    {
        $store = new MemoryStore();
        $clock = new Clock();
        $runnerStore = new FlakyStore($store);
        $runner = new Cronwatch(store: $runnerStore, now: $clock, alerts: [new Capture()], cronSecret: false);
        $admin = new Cronwatch(store: $store, now: $clock, alerts: [new Capture()], cronSecret: false);
        $runner->run('s', fn () => null);
        $silenced = false;
        $runnerStore->hooks['getState'] = function (\Closure $next, array $args) use (&$silenced, $admin) {
            $state = $next(...$args);
            if (!$silenced) {
                $silenced = true;
                $admin->silence('s', '1h');
            }
            return $state;
        };
        try {
            $runner->run('s', function (): never {
                throw new \RuntimeException('x');
            });
        } catch (\RuntimeException) {
        }
        $state = $store->getState('s');
        $this->assertNotNull($state->silencedUntil, 'the silence was not overwritten');
        $this->assertSame(1, $state->consecutiveFailures, 'nor was the failure');
    }

    public function testAHandleKeptFromAnEarlierDeclarationWritesTheOneThatStandsNotItsOwn(): void
    {
        $store = new MemoryStore();
        $cw = new Cronwatch(store: $store, now: new Clock(), alerts: [new Capture()], cronSecret: false);
        $earlier = $cw->job('a');
        $cw->job('a', ['schedule' => 'every 5m']);
        $earlier->run(fn () => null);
        $this->assertSame('every 5m', $store->getJob('a')->definition->get('schedule'));
        $cw->check();
        $this->assertSame('every 5m', $store->getJob('a')->definition->get('schedule'));
    }

    public function testAHandleWhoseJobWasForgottenWritesItsOwnDefinition(): void
    {
        $store = new MemoryStore();
        $cw = new Cronwatch(store: $store, now: new Clock(), alerts: [new Capture()], cronSecret: false);
        $handle = $cw->job('a', ['schedule' => 'every 5m']);
        $cw->forget('a');
        $handle->run(fn () => null);
        $this->assertSame('every 5m', $store->getJob('a')->definition->get('schedule'));
    }

    /**
     * A client whose store, on the first write of a job's definition, calls
     * `during` before the write goes through. Nothing else in one PHP process
     * can declare a job while its definition is being written: a store of the
     * app's own, or a hook inside one (WordPress's "query" filter, say).
     *
     * @param \Closure(Cronwatch): void $during
     * @return array{Cronwatch, MemoryStore}
     */
    private function heldUpsert(\Closure $during): array
    {
        $inner = new MemoryStore();
        $store = new FlakyStore($inner);
        $cw = new Cronwatch(store: $store, now: new Clock(), alerts: [new Capture()], cronSecret: false);
        $held = false;
        $store->hooks['upsertJob'] = function (\Closure $next, array $args) use (&$held, $during, $cw) {
            if (!$held) {
                $held = true;
                $during($cw);
            }
            return $next(...$args);
        };
        return [$cw, $inner];
    }

    public function testADeclarationMadeWhileTheEarlierOneIsBeingWrittenIsStillToBeWritten(): void
    {
        [$cw, $inner] = $this->heldUpsert(function (Cronwatch $cw): void {
            $cw->job('a', ['schedule' => 'every 5m']);
        });
        $cw->job('a')->run(fn () => null);
        $cw->check();
        $this->assertSame('every 5m', $inner->getJob('a')->definition->get('schedule'));
    }

    public function testAForgetThatLandsWhileAJobsFirstWriteIsUnderWayLeavesItToBeWrittenOnItsNextRun(): void
    {
        $inner = new MemoryStore();
        $store = new FlakyStore($inner);
        $cw = new Cronwatch(store: $store, now: new Clock(), alerts: [new Capture()], cronSecret: false);
        $forgotten = false;
        $store->hooks['upsertJob'] = function (\Closure $next, array $args) use (&$forgotten, $cw) {
            $next(...$args);
            // The forget lands just after the write.
            if (!$forgotten) {
                $forgotten = true;
                $cw->forget('a');
            }
        };
        $handle = $cw->job('a', ['schedule' => 'every 5m']);
        $handle->run(fn () => null);
        $this->assertNull($inner->getJob('a'));
        $handle->run(fn () => null);
        $this->assertSame('every 5m', $inner->getJob('a')?->definition->get('schedule'));
    }

    public function testAJobForgottenByAnotherProcessComesBackInALongLivedOneThatStillDeclaresIt(): void
    {
        $store = new MemoryStore();
        $clock = new Clock();
        $worker = new Cronwatch(store: $store, now: $clock, alerts: [new Capture()], cronSecret: false);
        $web = new Cronwatch(store: $store, now: $clock, alerts: [new Capture()], cronSecret: false);
        $handle = $worker->job('nightly', ['schedule' => '0 2 * * *']);
        $handle->run(fn () => null);
        $comesBack = [
            'run' => fn () => $handle->run(fn () => null),
            'start' => fn () => $handle->start()->finish(),
            'check' => fn () => $worker->check(),
            'jobs' => fn () => $worker->jobs(),
            'jobSummary' => fn () => $worker->jobSummary('nightly'),
        ];
        foreach ($comesBack as $how => $call) {
            $web->forget('nightly');
            $this->assertNull($store->getJob('nightly'), $how);
            // The process that forgot it does not bring it back.
            $web->check();
            $this->assertNull($store->getJob('nightly'), $how);
            $call();
            $this->assertSame('0 2 * * *', $store->getJob('nightly')?->definition->get('schedule'), $how);
        }
    }

    public function testADeclarationWrittenFromInsideTheEarlierOnesWriteIsWrittenAgainSoItStays(): void
    {
        [$cw, $inner] = $this->heldUpsert(function (Cronwatch $cw): void {
            $cw->job('a', ['schedule' => 'every 5m']);
            $this->assertSame('every 5m', $cw->jobSummary('a')->definition->get('schedule'));
        });
        $cw->job('a')->run(fn () => null);
        // The earlier write landed after the later one, which no queue can stop in one thread.
        $this->assertNull($inner->getJob('a')->definition->get('schedule'));
        $cw->check();
        $this->assertSame('every 5m', $inner->getJob('a')->definition->get('schedule'));
    }
}
