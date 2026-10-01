<?php

declare(strict_types=1);

namespace Cronwatch\Tests;

use Cronwatch\Alert;
use Cronwatch\Alerts\ChannelContext;
use Cronwatch\Alerts\Custom;
use Cronwatch\Cronwatch;
use Cronwatch\Job\JobContext;
use Cronwatch\Js;
use Cronwatch\TriageContext;
use Cronwatch\Tests\Support\Clients;
use Cronwatch\Tests\Support\Clock;
use PHPUnit\Framework\TestCase;

/** client.test.ts, but for the handler, which comes with the web phase. */
final class ClientTest extends TestCase
{
    use Clients;

    private const MIN = Clock::MIN;
    private const HOUR = Clock::HOUR;
    private const T0 = Clock::T0;

    public function testRunRecordsOutputMetricsAndDurationAndReturnsTheResult(): void
    {
        $cw = $this->make();
        $job = $cw->job('report', ['schedule' => '0 2 * * *']);
        $result = $job->run(function (JobContext $j) {
            $j->log('hello', ['n' => 1]);
            $j->metric('rows', 42);
            $this->clock->advance(1500);
            return 'done';
        });
        $this->assertSame('done', $result);
        $run = $cw->runs('report')[0];
        $this->assertSame('ok', $run->status);
        $this->assertSame(1500, $run->durationMs);
        $this->assertSame('hello {"n":1}', $run->output);
        $this->assertSame(['rows' => 42], $run->metrics);
        $summary = $cw->jobSummary('report');
        $this->assertSame('healthy', $summary->health);
        $this->assertSame(Js::dateUtc(2026, 0, 6, 2, 0), $summary->nextExpectedAt);
    }

    public function testMonitorAndCurrentRecordRunsToo(): void
    {
        $cw = $this->make();
        $job = $cw->job('wrapped');
        $task = $job->monitor(function (int $a, int $b): int {
            Cronwatch::current()->log("adding {$a} and {$b}");
            return $a + $b;
        });
        $this->assertSame(5, $task(2, 3));
        $this->assertNull(Cronwatch::current(), 'nothing is current outside a run');
        $this->assertSame('adding 2 and 3', $cw->runs('wrapped')[0]->output);
        $this->assertInstanceOf(\RuntimeException::class, $this->failing(fn () => $job->monitor(self::thrower())()));
        $this->assertSame(['ok'], array_slice(array_map(fn ($r) => $r->status, $cw->runs('wrapped')), 1));
    }

    public function testWrapIsMonitorUnderItsDeprecatedName(): void
    {
        $cw = $this->make();
        $task = $cw->job('old')->wrap(fn (int $a) => $a * 2, 'legacy');
        $this->assertSame(8, $task(4));
        $run = $cw->runs('old')[0];
        $this->assertSame(['ok', 'legacy'], [$run->status, $run->trigger]);
    }

    public function testAThrowingJobIsRecordedAsFailedAlertsAndRethrows(): void
    {
        $cw = $this->make();
        $job = $cw->job('nightly');
        $error = $this->failing(fn () => $job->run(self::thrower('db down')));
        $this->assertSame('db down', $error->getMessage());
        $run = $cw->runs('nightly')[0];
        $this->assertSame('failed', $run->status);
        $this->assertStringStartsWith('RuntimeException: db down', $run->error);
        $this->assertSame(['failed'], $this->capture->types());
        $this->assertStringContainsString('db down', $this->capture->alerts[0]->message);
        $this->assertSame('failing', $cw->jobSummary('nightly')->health);
    }

    public function testAnErrorOrExitOutsideExceptionIsRecordedToo(): void
    {
        $cw = $this->make();
        $error = $this->failing(fn () => $cw->run('typed', fn () => strlen([])));
        $this->assertInstanceOf(\TypeError::class, $error);
        $this->assertStringStartsWith('TypeError: strlen()', $cw->runs('typed')[0]->error);
    }

    public function testExpectTurnsAQuietSuccessIntoAFailure(): void
    {
        $cw = $this->make();
        $job = $cw->job('export', ['expect' => 'wrote']);
        $job->run(fn (JobContext $j) => $j->log('wrote 12 files'));
        $this->assertSame([], $this->capture->types());
        $this->clock->advance(self::HOUR);
        $job->run(fn (JobContext $j) => $j->log('nothing to do'));
        $run = $cw->runs('export')[0];
        $this->assertSame('failed', $run->status);
        $this->assertStringContainsString('did not contain "wrote"', $run->error);
        $this->assertSame(['failed'], $this->capture->types());
        // A returned string counts as output too.
        $job->run(fn () => 'wrote 3 files');
        $this->assertSame(['failed', 'recovered'], $this->capture->types());
    }

    public function testRunDefinesOnFirstUseAndValidatesNamesAndSchedules(): void
    {
        $cw = $this->make();
        $cw->run('adhoc', fn () => 1, ['schedule' => 'every 5m']);
        $this->assertCount(1, $cw->jobs());
        foreach ([
            'job name' => fn () => $cw->job('bad name!'),
            'not a cron expression' => fn () => $cw->job('x', ['schedule' => 'nope']),
            'grace' => fn () => $cw->job('x', ['grace' => 'soon']),
            'unknown option shedule' => fn () => $cw->job('x', ['shedule' => '@hourly']),
        ] as $expected => $declare) {
            try {
                $declare();
                $this->fail("expected an error mentioning {$expected}");
            } catch (\InvalidArgumentException $error) {
                $this->assertStringContainsString($expected, $error->getMessage());
            }
        }
    }

    public function testCheckFindsAMissedRunOnceAndALaterRunRecovers(): void
    {
        $cw = $this->make();
        $job = $cw->job('sync', ['schedule' => 'every 1h', 'grace' => '10m']);
        $cw->check(); // registers at T0
        $this->clock->advance(30 * self::MIN);
        $this->assertSame([], $cw->check()->alerts);
        $this->clock->set(self::T0 + 70 * self::MIN + 1);
        $r = $cw->check();
        $this->assertSame(['missed'], array_map(fn (Alert $a) => $a->type, $r->alerts));
        $this->assertSame('late', $r->jobs[0]->health);
        $this->assertSame([], $cw->check()->alerts, 'no repeat');
        $job->run(fn () => null);
        $this->assertSame(['missed', 'recovered'], $this->capture->types());
        $this->assertSame('healthy', $cw->jobSummary('sync')->health);
    }

    public function testAJobDeclaredAgainWithoutItsScheduleClosesMissedWithARecoveryOnce(): void
    {
        $cw = $this->make();
        $cw->job('sync', ['schedule' => 'every 1h', 'grace' => '10m']);
        $cw->check();
        $this->clock->set(self::T0 + 70 * self::MIN + 1);
        $this->assertSame(['missed'], array_map(fn (Alert $a) => $a->type, $cw->check()->alerts));
        $job = $cw->job('sync');
        $this->clock->advance(self::MIN);
        $r = $cw->check();
        $this->assertSame(['recovered'], array_map(fn (Alert $a) => $a->type, $r->alerts));
        $alert = $r->alerts[0];
        $this->assertSame('sync is no longer scheduled', $alert->title);
        $this->assertSame('Missed since 2026-01-05 10:40:00 UTC (1m ago). It has no schedule now, so nothing is due; the missed alert is closed.', $alert->message);
        $this->assertSame(['after' => ['missed'], 'reason' => 'unscheduled', 'since' => self::T0 + 70 * self::MIN + 1], $alert->details);
        $this->assertSame('never_ran', $r->jobs[0]->health);
        $this->assertSame([], $cw->check()->alerts, 'no repeat');
        $job->run(fn () => null);
        $this->assertSame(['missed', 'recovered'], $this->capture->types(), 'the next run owes nothing');
    }

    public function testAScheduleRemovedWhileSilencedClosesMissedQuietly(): void
    {
        $cw = $this->make();
        $cw->job('sync', ['schedule' => 'every 1h', 'grace' => '10m']);
        $cw->check();
        $this->clock->set(self::T0 + 70 * self::MIN + 1);
        $cw->check();
        $cw->silence('sync', '1h');
        $cw->job('sync');
        $this->clock->advance(self::MIN);
        $this->assertSame([], $cw->check()->alerts);
        $this->assertSame([], $cw->jobSummary('sync')->open);
        $this->clock->advance(2 * self::HOUR);
        $this->assertSame([], $cw->check()->alerts);
        $this->assertSame(['missed'], $this->capture->types());
    }

    public function testASilenceEndsOnAWholeMillisecondHeldAtTheLargestSafeInteger(): void
    {
        $cw = $this->make();
        $cw->job('quiet');
        $this->assertSame(9007199254740991, $cw->silence('quiet', '99999999999999999999w')->silencedUntil);
        $this->assertSame(9007199254740991, $cw->silence('quiet', 1e300)->silencedUntil);
        $this->assertSame(self::T0 + 1, $cw->silence('quiet', 1.5)->silencedUntil);
    }

    public function testCheckMarksARunThatNeverFinishedAsStuck(): void
    {
        // A process killed mid-run leaves its run running; another process's check finds it.
        $cw = $this->make();
        $job = $cw->job('long', ['timeout' => '5m']);
        $cw->store->init();
        $cw->store->insertRun(new \Cronwatch\Run('hung', 'long', 'running', self::T0));
        $this->assertSame('running', $cw->runs('long')[0]->status);
        $this->clock->advance(4 * self::MIN);
        $this->assertSame([], $cw->check()->alerts);
        $this->clock->advance(2 * self::MIN);
        $r = $cw->check();
        $this->assertSame(['stuck'], array_map(fn (Alert $a) => $a->type, $r->alerts));
        $this->assertSame('timeout', $cw->runs('long')[0]->status);
        $this->assertSame('stuck', $r->jobs[0]->health);
        $this->assertStringContainsString('never reported finishing', $this->capture->alerts[0]->message);
        unset($job);
    }

    public function testSlowAndOverBudgetAlertsComeFromTheJobsOwnBaseline(): void
    {
        $cw = $this->make();
        $job = $cw->job('agent', ['budget' => ['cost' => 1]]);
        for ($i = 0; $i < 5; $i++) {
            $job->run(function (JobContext $j) {
                $this->clock->advance(1000);
                $j->metrics(['tokens' => 1000, 'cost' => 0.5]);
            });
            $this->clock->advance(self::HOUR);
        }
        $this->assertSame([], $this->capture->types());
        $job->run(function (JobContext $j) {
            $this->clock->advance(15_000);
            $j->metrics(['tokens' => 1000, 'cost' => 0.5]);
        });
        $this->assertSame(['slow'], $this->capture->types());
        $this->clock->advance(self::HOUR);
        $job->run(function (JobContext $j) {
            $this->clock->advance(1000);
            $j->metrics(['tokens' => 5000, 'cost' => 1.2]);
        });
        $this->assertSame(['slow', 'over_budget'], $this->capture->types());
        $last = $this->capture->alerts[1];
        $this->assertStringContainsString('cost: 1.2, limit 1 (budget)', $last->message);
        $this->assertStringContainsString('tokens: 5,000, limit 3,000 (three times the usual 1,000)', $last->message);
        $this->clock->advance(self::HOUR);
        $job->run(function (JobContext $j) {
            $this->clock->advance(1000);
            $j->metrics(['tokens' => 1000, 'cost' => 0.5]);
        });
        $this->assertSame(['slow', 'over_budget', 'recovered'], $this->capture->types());
    }

    public function testSilenceSwallowsAlertsAndNothingOpensUnderneathUnsilenceAlertsAgain(): void
    {
        $cw = $this->make();
        $job = $cw->job('flaky');
        $cw->silence('flaky', '1h');
        $this->failing(fn () => $job->run(self::thrower('x')));
        $this->assertSame([], $this->capture->types());
        $this->assertSame('silenced', $cw->jobSummary('flaky')->health);
        $cw->unsilence('flaky');
        $this->failing(fn () => $job->run(self::thrower('y')));
        $this->assertSame(['failed'], $this->capture->types());
    }

    public function testTriageOutputIsAttachedToFailureAlertsAndNeverBlocksThem(): void
    {
        $cw = $this->make(['triage' => fn (TriageContext $ctx) => "Probably {$ctx->alert->job}'s database."]);
        $this->failing(fn () => $cw->run('t', self::thrower()));
        $this->assertSame("Probably t's database.", $this->capture->alerts[0]->triage);
        $cw2 = $this->make(['triage' => function (): never {
            throw new \RuntimeException('api down');
        }]);
        $this->failing(fn () => $cw2->run('t', self::thrower()));
        $this->assertSame(['failed'], $this->capture->types());
        $this->assertNull($this->capture->alerts[0]->triage);
        $this->assertTrue($this->capture->alerts[0]->triageTried, 'tried, and gave nothing');
        $this->assertSame(['triage for t'], $this->wheres());
    }

    public function testForgetRemovesTheJobAndItsRuns(): void
    {
        $cw = $this->make();
        $cw->run('gone', fn () => null);
        $this->assertCount(1, $cw->jobs());
        $cw->forget('gone');
        $this->assertCount(0, $cw->jobs());
        $this->assertNull($cw->jobSummary('gone'));
    }

    public function testAFailingAlertChannelDoesNotBreakTheRun(): void
    {
        $cw = $this->make(['alerts' => [new Custom('broken', function (): never {
            throw new \RuntimeException('no network');
        })]]);
        $error = $this->failing(fn () => $cw->run('x', self::thrower('job')));
        $this->assertSame('job', $error->getMessage());
        $this->assertSame(['alert channel broken'], $this->wheres());
    }

    public function testPlainCallablesAndCustomChannelsTakeAlerts(): void
    {
        $got = [];
        $cw = $this->make(['alerts' => [
            function (Alert $alert) use (&$got): void {
                $got[] = "plain {$alert->type}";
            },
            new Custom('with-context', function (Alert $alert, ChannelContext $context) use (&$got): void {
                $got[] = "context {$alert->type}";
                $context->onError(new \RuntimeException('one recipient refused'));
            }),
        ]]);
        $this->failing(fn () => $cw->run('c', self::thrower()));
        $this->assertSame(['plain failed', 'context failed'], $got);
        $this->assertSame(['alert channel with-context'], $this->wheres());
        $this->assertSame([], $cw->store->getState('c')->undelivered, 'delivered');
    }
}
