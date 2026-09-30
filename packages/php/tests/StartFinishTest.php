<?php

declare(strict_types=1);

namespace Cronwatch\Tests;

use Cronwatch\Cronwatch;
use Cronwatch\Pattern;
use Cronwatch\Run;
use Cronwatch\RunStatus;
use Cronwatch\Store\ComparesAndSetsState;
use Cronwatch\Store\MemoryStore;
use Cronwatch\Tests\Support\Backend;
use Cronwatch\Tests\Support\Capture;
use Cronwatch\Tests\Support\Clients;
use Cronwatch\Tests\Support\Clock;
use Cronwatch\Tests\Support\DelegatingStore;
use Cronwatch\Tests\Support\FlakyStore;
use PHPUnit\Framework\Attributes\DataProvider;
use PHPUnit\Framework\TestCase;

/** start-finish.test.ts, and the parts of finish-once.test.ts that need one process. */
final class StartFinishTest extends TestCase
{
    use Clients;

    private const MIN = Clock::MIN;
    private const HOUR = Clock::HOUR;
    private const T0 = Clock::T0;

    public function testStartRecordsARunningRunAndFinishRecordsItOk(): void
    {
        $cw = $this->make();
        $job = $cw->job('sync', ['schedule' => '@hourly']);
        $run = $job->start(trigger: 'queue');
        $this->assertSame('sync', $run->job);
        $this->assertTrue($run->isActive());
        $stored = $cw->getRun($run->id);
        $this->assertSame('running', $stored->status);
        $this->assertSame('queue', $stored->trigger);
        $run->log('imported', 12, 'rows');
        $run->metric('rows', 12);
        $this->clock->advance(90_000);
        $finished = $run->finish();
        $this->assertSame('ok', $finished->status);
        $this->assertSame(90_000, $finished->durationMs);
        $this->assertFalse($run->isActive());
        $recorded = $cw->runs('sync')[0];
        $this->assertSame('ok', $recorded->status);
        $this->assertSame('imported 12 rows', $recorded->output);
        $this->assertSame(['rows' => 12], $recorded->metrics);
        $this->assertSame([], $this->capture->types());
        $this->assertSame('healthy', $cw->jobSummary('sync')->health);
    }

    public function testFailAndFinishErrorRecordAFailureAndAlertOnce(): void
    {
        $cw = $this->make();
        $job = $cw->job('import', ['failuresBeforeAlert' => 2]);
        $job->start()->fail(new \RuntimeException('api down'));
        $run = $job->start()->finish(['error' => new \RuntimeException('still down')]);
        $this->assertSame('failed', $run->status);
        $this->assertStringStartsWith('RuntimeException: still down', $run->error);
        $this->assertSame(['failed'], $this->capture->types());
        $job->start(trigger: 'retry')->finish(['status' => 'ok']);
        $this->assertSame(['failed', 'recovered'], $this->capture->types());
    }

    public function testASecondFinishIsIgnoredAndReportedNotThrown(): void
    {
        $cw = $this->make();
        $job = $cw->job('once');
        $run = $job->start();
        $a = $run->fail('boom');
        $b = $run->finish();
        $this->assertSame('failed', $a->status);
        $this->assertNull($b);
        $this->assertNull($run->finish());
        $this->assertSame(['failed'], $this->capture->types());
        $this->assertSame('failed', $cw->runs('once')[0]->status);
        $this->assertCount(2, $this->errors);
        $this->assertStringContainsString('was already finished by this handle; ignored', $this->messages()[0]);
        $this->assertSame('finishing once', $this->errors[0][1]);
    }

    public function testStartWithAnIdTwiceRecordsOneRunAndReturnsAHandleOnIt(): void
    {
        $cw = $this->make();
        $job = $cw->job('inngest-fn');
        $one = $job->start(id: '01HX-run');
        $two = $job->start(id: '01HX-run');
        $this->assertSame('01HX-run', $one->id);
        $this->assertSame('01HX-run', $two->id);
        $again = $job->start(trigger: 'ignored', id: '01HX-run');
        $this->assertTrue($again->isActive());
        $this->assertCount(1, $cw->runs('inngest-fn'));
        $this->assertSame('start', $cw->getRun('01HX-run')->trigger);
        $again->finish('done');
        // Finished elsewhere: this handle's finish is a reported no-op.
        $this->assertNull($one->finish());
        $this->assertStringContainsString('already finished as ok; ignored', $this->messages()[count($this->errors) - 1]);
        $late = $job->start(id: '01HX-run');
        $this->assertFalse($late->isActive());
        $this->assertNull($late->finish());
        $this->assertCount(1, $cw->runs('inngest-fn'));
        foreach ([
            'belongs to job "inngest-fn"' => fn () => $cw->job('other')->start(id: '01HX-run'),
            'run id of 1 to 200 characters' => fn () => $job->start(id: ''),
            // No store could hold a NUL (Postgres refuses it), so such an id is refused wherever one is taken.
            'start() cannot take a run id containing a NUL character' => fn () => $job->start(id: "01HX\0run"),
            'resume() cannot take a run id containing a NUL character' => fn () => $job->resume("01HX\0run"),
            'recordRun: run ids cannot contain a NUL character (job "inngest-fn")' => fn () => $cw->recordRun(new Run("x\0y", 'inngest-fn', RunStatus::OK, 1, 2, 1)),
        ] as $expected => $start) {
            try {
                $start();
                $this->fail("expected {$expected}");
            } catch (\InvalidArgumentException $error) {
                $this->assertStringContainsString($expected, $error->getMessage());
            }
        }
    }

    public static function pairs(): iterable
    {
        foreach (['memory', 'sqlite', 'mysql', 'mariadb', 'postgres'] as $kind) {
            yield $kind => [$kind];
        }
    }

    #[DataProvider('pairs')]
    public function testResumeInASecondClientOnTheSameStoreAppendsAndFinishes(string $kind): void
    {
        $why = Backend::unavailable($kind);
        if ($why !== null) {
            $this->markTestSkipped($why);
        }
        $backend = Backend::make($kind);
        try {
            $clock = new Clock();
            $alerts = new Capture();
            $errors = [];
            $onError = function (\Throwable $e) use (&$errors): void {
                $errors[] = $e->getMessage();
            };
            $first = new Cronwatch(store: $backend->open(), now: $clock, alerts: [$alerts], cronSecret: false, onError: $onError);
            $second = new Cronwatch(store: $backend->open(), now: $clock, alerts: [$alerts], cronSecret: false, onError: $onError);
            $options = ['expect' => 'sent', 'budget' => ['emails' => 100]];
            $started = $first->job('digest', $options)->start(id: 'evt-1');
            $started->log('loaded 40 recipients');
            $started->log('token=abc123');
            $started->metric('recipients', 40);
            $started->flush();
            $midway = $first->getRun('evt-1');
            $this->assertSame('running', $midway->status);
            $this->assertSame("loaded 40 recipients\ntoken=[redacted]", $midway->output);

            $clock->advance(5 * self::MIN);
            $second->job('digest', $options);
            $resumed = $second->resumeRun('digest', 'evt-1');
            $this->assertTrue($resumed->isActive());
            $this->assertSame($midway->startedAt, $resumed->startedAt);
            $resumed->log('sent 40 emails');
            $resumed->metric('emails', 40);
            $run = $resumed->finish();
            $this->assertSame('ok', $run->status);
            $this->assertSame(5 * self::MIN, $run->durationMs);
            $stored = $first->getRun('evt-1');
            $this->assertSame('ok', $stored->status);
            $this->assertSame("loaded 40 recipients\ntoken=[redacted]\nsent 40 emails", $stored->output);
            // Postgres keeps metrics as JSONB, which orders keys by length: the SDK reads them back so too.
            $this->assertSame($kind === 'postgres' ? ['emails' => 40, 'recipients' => 40] : ['recipients' => 40, 'emails' => 40], $stored->metrics);
            $this->assertSame([], $alerts->types());
            $this->assertSame([], $errors);
        } finally {
            $backend->done();
        }
    }

    public function testResumeOfAnUnknownOrFinishedRunReturnsAHandleWhoseFinishIsAReportedNoOp(): void
    {
        $cw = $this->make();
        $job = $cw->job('webhook');
        $missing = $job->resume('nope');
        $this->assertFalse($missing->isActive());
        $this->assertNull($missing->startedAt);
        $missing->log('dropped');
        $missing->flush();
        $this->assertNull($missing->finish());
        $this->assertStringContainsString('run nope of webhook was not found; ignored', $this->messages()[0]);
        $job->run(fn () => 'done');
        $done = $cw->runs('webhook')[0];
        $finished = $job->resume($done->id);
        $this->assertFalse($finished->isActive());
        $this->assertNull($finished->fail('late'));
        $this->assertStringContainsString('already finished as ok; ignored', $this->messages()[1]);
        $this->assertSame('ok', $cw->runs('webhook')[0]->status);
        $this->expectExceptionMessage('not declared');
        $cw->resumeRun('undeclared', 'x');
    }

    public function testARunNeverFinishedIsMarkedStuckAfterTheJobsTimeout(): void
    {
        $cw = $this->make();
        $job = $cw->job('callback', ['timeout' => '30m']);
        $run = $job->start();
        $this->clock->advance(29 * self::MIN);
        $cw->check();
        $this->assertSame('running', $cw->getRun($run->id)->status);
        $this->clock->advance(2 * self::MIN);
        $cw->check();
        $stored = $cw->getRun($run->id);
        $this->assertSame('timeout', $stored->status);
        $this->assertStringContainsString('Still running after 30m', $stored->error);
        $this->assertSame(['stuck'], $this->capture->types());
    }

    public function testLinesFlushedWhileACheckMarksEarlierRunsStuckAreKeptOnTheRunItMarksNext(): void
    {
        $second = null;
        $sent = 0;
        // While the first stuck run's alert is being sent, the second is still running, and flushes.
        $held = new \Cronwatch\Alerts\Custom('held', function () use (&$second, &$sent): void {
            if ($sent++ === 0) {
                $second->log('important progress line');
                $second->metric('rows', 2);
                $second->flush();
            }
        });
        $cw = $this->make(['alerts' => [$held]]);
        $first = $cw->job('first', ['timeout' => '30m'])->start();
        $this->clock->advance(1000);
        $second = $cw->job('second', ['timeout' => '30m'])->start();
        $second->log('early line');
        $second->metric('rows', 1);
        $second->flush();
        $this->clock->advance(31 * self::MIN);
        $cw->check();
        $stored = $cw->getRun($second->id);
        $this->assertSame('timeout', $stored->status);
        $this->assertSame("early line\nimportant progress line", $stored->output);
        $this->assertSame(['rows' => 2], $stored->metrics);
        $this->assertSame('timeout', $cw->getRun($first->id)->status);
    }

    public function testALateSuccessAfterATimeoutMarkClosesStuckAndRecoversALateFailureDoesNotCountTwice(): void
    {
        $cw = $this->make();
        $job = $cw->job('slowpoke', ['timeout' => '10m', 'failuresBeforeAlert' => 2]);
        $first = $job->start();
        $this->clock->advance(11 * self::MIN);
        $cw->check();
        $this->assertSame([], $this->capture->types());
        $failed = $first->fail(new \RuntimeException('gave up'));
        $this->assertSame('failed', $failed->status);
        $this->assertSame('RuntimeException: gave up', explode("\n", $cw->getRun($first->id)->error)[0], 'the run keeps its real error');
        $this->assertSame([], $this->capture->types(), 'the late failure did not count as a second one');

        $second = $job->start();
        $this->clock->advance(11 * self::MIN);
        $cw->check();
        $this->assertSame(['stuck'], $this->capture->types());
        $resumed = $cw->resumeRun('slowpoke', $second->id);
        $this->assertTrue($resumed->isActive(), 'a run marked timeout can still be finished late');
        $this->assertSame('ok', $resumed->finish()->status);
        $this->assertSame(['stuck', 'recovered'], $this->capture->types());
        $this->assertNull($second->finish(), 'the handle that started it sees it finished elsewhere');
    }

    public function testExpectIsAppliedAtFinishToTheLoggedLinesOrTheStringPassed(): void
    {
        $cw = $this->make();
        $job = $cw->job('export', ['expect' => new Pattern('/wrote \d+ files/')]);
        $run = $job->start()->finish(['status' => 'ok', 'result' => 'nothing to do']);
        $this->assertSame('failed', $run->status);
        $this->assertSame('nothing to do', $run->output);
        $this->assertStringContainsString('did not match /wrote \d+ files/', $run->error);
        $this->assertSame(['failed'], $this->capture->types());

        $busy = $job->start();
        $busy->log('wrote 3 files');
        $busy->flush();
        $resumed = $job->resume($busy->id);
        $this->assertSame('ok', $resumed->finish('uploaded')->status, 'lines flushed earlier count toward expect');
        $this->assertSame(['failed', 'recovered'], $this->capture->types());
    }

    public function testAStoreFailingDuringStartDoesNotThrowFinishRecordsTheRunOnceTheStoreIsBack(): void
    {
        $store = (new FlakyStore(new MemoryStore()))->breaks(['insertRun']);
        $cw = $this->make(['store' => $store]);
        $job = $cw->job('backup', ['schedule' => '@hourly']);
        $run = $job->start();
        $this->assertTrue($run->isActive());
        $this->assertSame('recording backup', $this->errors[0][1]);
        $this->assertNull($cw->getRun($run->id));
        $run->log('copied');
        $run->flush(); // nothing stored to append to; kept for finish
        $store->broken = [];
        $this->clock->advance(self::HOUR / 2);
        $this->assertSame('ok', $run->finish()->status);
        $stored = $cw->getRun($run->id);
        $this->assertSame('ok', $stored->status);
        $this->assertSame('copied', $stored->output);
        $this->assertSame(self::HOUR / 2, $stored->durationMs);
        $this->assertSame([], $this->capture->types());
    }

    public function testAStoreFailingAtFinishIsReportedNotThrownAndTheHandleCanFinishAgain(): void
    {
        $store = new FlakyStore(new MemoryStore());
        $cw = $this->make(['store' => $store]);
        $job = $cw->job('flaky');
        $run = $job->start();
        $run->log('working');
        $store->breaks(['getRun', 'updateRun', 'updateRunIf']);
        $run->flush();
        $this->assertSame('flushing flaky', $this->errors[count($this->errors) - 1][1]);
        $this->assertNull($run->finish(), 'nothing recorded');
        $this->assertContains('finishing flaky', $this->wheres());
        $this->assertTrue($run->isActive(), 'still active, to finish again');
        // The read works but the write fails: still retryable.
        unset($store->broken['getRun']);
        $this->assertNull($run->finish());
        $this->assertTrue($run->isActive());
        $store->broken = [];
        $this->assertSame('running', $cw->getRun($run->id)->status, 'nothing written yet');
        $finished = $run->finish();
        $this->assertSame('ok', $finished->status);
        $this->assertSame('working', $finished->output, 'the lines logged before the failures are kept');
        $this->assertFalse($run->isActive());
        $this->assertNull($run->finish(), 'finished once only');
    }

    // ------------------------------------------------------------ finish-once.test.ts, in one process

    public function testTwoClientsFinishingOneRunOneRecordsAndJudgesItTheOtherReportsIt(): void
    {
        $store = new MemoryStore();
        $one = $this->make(['store' => $store]);
        $oneAlerts = $this->capture;
        $two = $this->make(['store' => $store]);
        $errors = &$this->errors;
        $job = $one->job('webhook-ingest', ['failuresBeforeAlert' => 2]);
        $two->job('webhook-ingest', ['failuresBeforeAlert' => 2]);
        $job->start(id: 'delivery-1');
        $h1 = $one->resumeRun('webhook-ingest', 'delivery-1');
        $h2 = $two->resumeRun('webhook-ingest', 'delivery-1');
        $this->clock->advance(self::MIN);
        $results = [$h1->fail(new \RuntimeException('upstream 502')), $h2->fail(new \RuntimeException('upstream 502'))];
        $this->assertCount(1, array_filter($results), 'one finish recorded');
        $this->assertStringContainsString('already finished as failed; ignored', implode("\n", array_map(fn ($e) => $e[0]->getMessage(), $errors)));
        $this->assertCount(1, $one->runs('webhook-ingest'));
        $this->assertSame(1, $store->getState('webhook-ingest')->consecutiveFailures, 'the failure counted once');
        $this->assertSame([], [...$oneAlerts->types(), ...$this->capture->types()], 'one failure is below failuresBeforeAlert 2');
    }

    public function testAStoreWithoutUpdateRunIfFallsBackToAReadAndAWrite(): void
    {
        $store = new class (new MemoryStore()) extends DelegatingStore implements ComparesAndSetsState {
            public function compareAndSetState(\Cronwatch\JobState $state, int|float $expectedVersion): bool
            {
                return $this->inner->compareAndSetState($state, $expectedVersion);
            }
        };
        $cw = $this->make(['store' => $store]);
        $job = $cw->job('plain');
        $this->assertSame('ok', $job->start(id: 'p1')->finish('done')->status);
        $this->assertNull($job->resume('p1')->finish('again'));
        $this->assertStringContainsString('already finished', implode("\n", $this->messages()));
    }

    public function testRecordRunARunACheckMarkedTimeoutTakesItsLateFinishAsAHandlesWould(): void
    {
        $this->clock = new Clock(\Cronwatch\Js::dateUtc(2026, 0, 1, 3, 0));
        $cw = $this->make();
        $cw->job('db:vacuum', ['schedule' => '0 3 * * *', 'timeout' => '30m']);
        $base = fn (string $id, string $status, array $more = []) => new Run(...array_replace(
            ['id' => $id, 'job' => 'db:vacuum', 'status' => $status, 'startedAt' => $this->clock->now, 'trigger' => 'pg_cron'],
            $more,
        ));
        $startedAt = $this->clock->now;
        $cw->recordRun($base('pgcron:77', 'running'));
        $this->clock->advance(45 * self::MIN);
        $cw->check();
        $this->assertSame('timeout', $cw->getRun('pgcron:77')->status);
        $this->clock->advance(15 * self::MIN);
        $cw->recordRun($base('pgcron:77', 'ok', ['startedAt' => $startedAt, 'finishedAt' => $this->clock->now - 5 * self::MIN, 'durationMs' => 55 * self::MIN, 'output' => 'VACUUM']));
        $cw->check();
        $run = $cw->getRun('pgcron:77');
        $this->assertSame('ok', $run->status);
        $this->assertSame('VACUUM', $run->output);
        $this->assertSame('healthy', $cw->jobSummary('db:vacuum')->health);
        $this->assertSame(['stuck', 'recovered'], $this->capture->types());

        // A late failure is written but not counted twice.
        $otherAt = $this->clock->now;
        $cw->recordRun($base('pgcron:78', 'running'));
        $this->clock->advance(45 * self::MIN);
        $cw->check();
        $cw->recordRun($base('pgcron:78', 'failed', ['startedAt' => $otherAt, 'finishedAt' => $this->clock->now, 'durationMs' => 45 * self::MIN, 'error' => 'ERROR: canceled']));
        $this->assertSame('failed', $cw->getRun('pgcron:78')->status);
        $this->assertSame(1, $cw->store->getState('db:vacuum')->consecutiveFailures);
        $this->assertSame(['stuck', 'recovered', 'stuck'], $this->capture->types());
    }

    public function testRecordRunLeavesAStoredRunOfAnotherJobAloneAndReportsIt(): void
    {
        $cw = $this->make();
        $a = $cw->job('webhook-job');
        $cw->job('db:nightly');
        $h = $a->start(id: 'run-43');
        $sent = $cw->recordRun(new Run('run-43', 'db:nightly', 'ok', self::T0 - 1000, self::T0, 1000, trigger: 'pg_cron'));
        $this->assertSame([], $sent);
        $stored = $cw->getRun('run-43');
        $this->assertSame('webhook-job', $stored->job);
        $this->assertSame('running', $stored->status);
        $this->assertStringContainsString('run-43 of db:nightly belongs to job "webhook-job"; ignored', implode("\n", $this->messages()));
        $this->assertSame('ok', $h->finish()->status);
        $this->assertSame([], $this->capture->types());
    }

    public function testRecordRunRefusesAMetricThatIsNoFiniteNumberAndStoresNothing(): void
    {
        $cw = $this->make();
        $cw->job('imported');
        foreach ([NAN, INF, null, '3'] as $i => $value) {
            try {
                $cw->recordRun(['id' => "m{$i}", 'job' => 'imported', 'status' => 'ok', 'startedAt' => 1, 'finishedAt' => 2, 'durationMs' => 1, 'metrics' => ['cost' => 1, 'rows' => $value]]);
                $this->fail('expected recordRun to throw');
            } catch (\InvalidArgumentException $error) {
                $this->assertSame("recordRun: metric \"rows\" must be a finite number (job \"imported\", run \"m{$i}\")", $error->getMessage());
            }
            $this->assertNull($cw->getRun("m{$i}"));
        }
        $this->assertSame([], $cw->runs('imported'));
    }

    public function testStartAndResumeRefuseIdsInThePgCronSourcesNamespace(): void
    {
        $cw = $this->make();
        $job = $cw->job('webhook-job');
        foreach ([fn () => $job->start(id: 'pgcron:42'), fn () => $job->resume('pgcron:42'), fn () => $cw->resumeRun('webhook-job', 'pgcron:db:42')] as $call) {
            try {
                $call();
                $this->fail('expected the pgcron: prefix refused');
            } catch (\InvalidArgumentException $error) {
                $this->assertStringContainsString('cannot take a run id starting with "pgcron:"', $error->getMessage());
            }
        }
        $this->assertTrue($job->start(id: 'pgcron-42')->isActive(), 'only the prefix with its colon is reserved');
    }

    public function testStartWithAnIdAnotherJobHoldsFails(): void
    {
        $cw = $this->make();
        $a = $cw->job('import-a');
        $b = $cw->job('import-b');
        $a->start(id: 'evt_123');
        try {
            $b->start(id: 'evt_123');
            $this->fail('expected the id refused');
        } catch (\InvalidArgumentException $error) {
            $this->assertStringContainsString('belongs to job "import-a", not "import-b"', $error->getMessage());
        }
        $this->assertSame($a->start(id: 'evt_9')->id, $a->start(id: 'evt_9')->id);
        $this->assertCount(2, $cw->runs('import-a'));
        $this->assertSame('import-a', $cw->getRun('evt_123')->job);
    }

    public function testAHandleResumedWhileTheStoreFailedCannotFinishOrFlushAnotherJobsRun(): void
    {
        $inner = new MemoryStore();
        $store = new FlakyStore($inner);
        $fail = false;
        $store->hooks['getRun'] = function (\Closure $next, array $args) use (&$fail) {
            if ($fail) {
                $fail = false;
                throw new \RuntimeException('blip');
            }
            return $next(...$args);
        };
        $cw = $this->make(['store' => $store]);
        $billing = $cw->job('billing');
        $webhook = $cw->job('webhook');
        $billing->start(id: 'run-7');
        $fail = true;
        $h = $webhook->resume('run-7');
        $this->assertTrue($h->isActive(), 'unknown yet: the read failed');
        $h->log('attacker line');
        $h->flush();
        $this->assertStringContainsString('run-7 of webhook belongs to job "billing"; ignored', implode("\n", $this->messages()));
        $this->assertNull($h->finish('ok'));
        $stored = $inner->getRun('run-7');
        $this->assertSame(['billing', 'running', null], [$stored->job, $stored->status, $stored->output]);
    }

    public function testExpectAtFinishSeesAnEarlyLineEvenAfterFlushesAsRunWould(): void
    {
        $cw = $this->make();
        $job = $cw->job('export', ['expect' => 'connected to warehouse']);
        $job->run(function ($ctx): void {
            $ctx->log('connected to warehouse');
            for ($i = 0; $i < 400; $i++) {
                $ctx->log(str_pad("row batch {$i} ", 60, '.'));
            }
        });
        $this->assertSame('ok', $cw->runs('export')[0]->status);
        $h = $job->start();
        $h->log('connected to warehouse');
        for ($i = 0; $i < 400; $i++) {
            $h->log(str_pad("row batch {$i} ", 60, '.'));
            if ($i % 100 === 99) {
                $h->flush();
            }
        }
        $run = $h->finish();
        $this->assertSame('ok', $run->status, (string) $run->error);
        $this->assertStringNotContainsString('connected to warehouse', $run->output, 'the stored output kept only the tail');
    }

    public function testAFlushNeverUndoesAFinishWrittenWhileItRead(): void
    {
        $inner = new MemoryStore();
        $store = new FlakyStore($inner);
        $finishFirst = null;
        $store->hooks['getRun'] = function (\Closure $next, array $args) use (&$finishFirst) {
            $run = $next(...$args);
            if ($finishFirst !== null) {
                $f = $finishFirst;
                $finishFirst = null;
                $f();
            }
            return $run;
        };
        $cw = $this->make(['store' => $store]);
        $job = $cw->job('sync');
        $h = $job->start(id: 's1');
        $h->log('halfway');
        $other = $job->resume('s1');
        $finishFirst = fn () => $other->finish('done elsewhere');
        $h->flush();
        $stored = $inner->getRun('s1');
        $this->assertSame('ok', $stored->status, 'still finished');
        $this->assertSame('done elsewhere', $stored->output);
    }

    public function testARunFinishedWhileACheckMarksItTimeoutIsJudgedOnce(): void
    {
        $store = new FlakyStore(new MemoryStore());
        $race = null;
        $store->hooks['runningRuns'] = function (\Closure $next) use (&$race) {
            $runs = $next();
            if ($race !== null) {
                $r = $race;
                $race = null;
                $r();
            }
            return $runs;
        };
        $cw = $this->make(['store' => $store]);
        $job = $cw->job('long', ['timeout' => '5m']);
        $h = $job->start();
        $this->clock->advance(10 * self::MIN);
        $race = fn () => $h->finish('finally');
        $cw->check();
        $this->assertSame('ok', $cw->getRun($h->id)->status);
        $this->assertSame([], $this->capture->types(), 'not marked stuck over a finish');
    }
}
