<?php

declare(strict_types=1);

namespace Cronwatch\Tests;

use Cronwatch\Alert;
use Cronwatch\Alerts\Custom;
use Cronwatch\Cronwatch;
use Cronwatch\JobDefinition;
use Cronwatch\Run;
use Cronwatch\Store\MemoryStore;
use Cronwatch\Store\Store;
use Cronwatch\Tests\Support\Capture;
use Cronwatch\Tests\Support\Clients;
use Cronwatch\Tests\Support\Clock;
use Cronwatch\Tests\Support\FlakyStore;
use Cronwatch\TriageContext;
use PHPUnit\Framework\TestCase;

/**
 * client-hardening.test.ts. The SDK's tests of a hung channel, a triage
 * aborted mid-call and the interval timer have no PHP counterpart: PHP sends
 * in turn and cannot cut a call short, and there is no start() (see
 * DESIGN.md); what replaces them is here too.
 */
final class ClientHardeningTest extends TestCase
{
    use Clients;

    private const MIN = Clock::MIN;
    private const HOUR = Clock::HOUR;
    private const T0 = Clock::T0;

    public function testACronFiringMoreOftenThanItsGraceIsStillMissed(): void
    {
        $cw = $this->make();
        $job = $cw->job('often', ['schedule' => '*/5 * * * *']); // default grace 10m
        $job->run(fn () => null); // 09:30
        $this->clock->advance(14 * self::MIN);
        $this->assertSame([], $cw->check()->alerts, '09:35 is due, grace runs to 09:45');
        $this->clock->advance(2 * self::MIN);
        $this->assertSame(['missed'], array_map(fn (Alert $a) => $a->type, $cw->check()->alerts));
        $job->run(fn () => null);
        $this->assertSame(['missed', 'recovered'], $this->capture->types());
    }

    public function testAMissedRunWhoseNextRunFailsBelowTheThresholdStillRecoversLater(): void
    {
        $cw = $this->make();
        $job = $cw->job('quiet', ['schedule' => 'every 1h', 'failuresBeforeAlert' => 3]);
        $cw->check();
        $this->clock->advance(2 * self::HOUR);
        $cw->check();
        $this->failing(fn () => $job->run(self::thrower()));
        $this->assertSame(['missed'], $this->capture->types());
        $job->run(fn () => null);
        $this->assertSame(['missed', 'recovered'], $this->capture->types());
        $this->assertStringContainsString('after: missed', $this->capture->alerts[1]->message);
    }

    public function testAStoreOutageNeverStopsTheJobAndStoreErrorsGoToOnError(): void
    {
        $store = (new FlakyStore(new MemoryStore()))->breaks(['upsertJob', 'insertRun', 'getState', 'setState', 'updateRun', 'listRuns']);
        $cw = $this->make(['store' => $store]);
        $ran = 0;
        $this->assertSame(7, $cw->run('s', function () use (&$ran) {
            $ran++;
            return 7;
        }));
        $throws = function () use (&$ran): never {
            $ran++;
            throw new \RuntimeException("the job's own");
        };
        $error = $this->failing(fn () => $cw->run('s', $throws));
        $this->assertSame("the job's own", $error->getMessage());
        $this->assertSame(2, $ran);
        $this->assertNotSame([], $this->wheres());
        $this->assertSame([], array_values(array_filter($this->wheres(), fn ($w) => $w !== 'recording s')), implode(', ', $this->wheres()));
        $store->broken = [];
        $cw->run('s', fn () => 'back');
        $this->assertCount(1, $cw->runs('s'));
    }

    public function testAStoreThatFailsToInitialiseIsTriedAgainOnTheNextCall(): void
    {
        $store = new FlakyStore(new MemoryStore());
        $inits = 0;
        $store->hooks['init'] = function (\Closure $next) use (&$inits): void {
            if (++$inits === 1) {
                throw new \RuntimeException('not yet');
            }
            $next();
        };
        $cw = $this->make(['store' => $store]);
        $this->assertSame(1, $cw->run('i', fn () => 1));
        $this->assertSame(['recording i'], $this->wheres());
        // The finished run was written on the retry, once init went through.
        $this->assertSame(2, $inits);
        $cw->run('i', fn () => 2);
        $this->assertSame(2, $inits);
        $this->assertCount(2, $cw->runs('i'));
    }

    public function testDispatchDoesNotOverwriteASilenceMadeWhileAnAlertWasBeingSent(): void
    {
        $cw = null;
        $cw = $this->make(['alerts' => [new Custom('silencer', function () use (&$cw): void {
            $cw->silence('loud', '1h');
        })]]);
        $this->failing(fn () => $cw->run('loud', self::thrower()));
        $state = $cw->store->getState('loud');
        $this->assertNotNull($state->silencedUntil, 'the silence survived');
        $this->assertSame(['failed' => self::T0], $state->open);
        $this->assertSame(self::T0, $state->lastAlertAt);
    }

    public function testASlowChannelHoldsUpOnlyItselfAndOneThatAcceptedMakesItDelivered(): void
    {
        $good = new Capture();
        $cw = $this->make(['alerts' => [new Custom('down', function (): never {
            throw new \RuntimeException('timed out');
        }), $good]]);
        $this->failing(fn () => $cw->run('h', self::thrower()));
        $this->assertSame(['failed'], $good->types(), 'the other channel has it');
        $this->assertSame(['alert channel down'], $this->wheres());
        $this->assertSame([], $cw->store->getState('h')->undelivered, 'one channel took it: delivered');
    }

    public function testTriageIsGivenASignalThatAbortsAtItsDeadline(): void
    {
        $signal = null;
        $cw = $this->make(['triage' => function (TriageContext $ctx) use (&$signal): string {
            $signal = $ctx->signal;
            $this->assertGreaterThan(24_000, $ctx->signal->remainingMs());
            $this->assertLessThanOrEqual(Cronwatch::TRIAGE_TIMEOUT_MS, $ctx->signal->remainingMs());
            return 'A look.';
        }]);
        $this->failing(fn () => $cw->run('t', self::thrower()));
        $this->assertFalse($signal->aborted(), 'settled once triage answered');
        $this->assertSame('A look.', $this->capture->alerts[0]->triage);
    }

    public function testAnAlertNoChannelTookIsRetriedOncePerCheckUntilOneDoes(): void
    {
        $down = true;
        $attempts = 0;
        $got = [];
        $cw = $this->make(['alerts' => [new Custom('flaky', function (Alert $a) use (&$down, &$attempts, &$got): void {
            $attempts++;
            if ($down) {
                throw new \RuntimeException('down');
            }
            $got[] = $a;
        })]]);
        $this->failing(fn () => $cw->run('r', self::thrower()));
        $state = $cw->store->getState('r');
        $this->assertCount(1, $state->undelivered);
        $this->assertNull($state->lastAlertAt, 'nothing was delivered');
        $this->clock->advance(self::MIN);
        $cw->check();
        $this->assertSame(2, $attempts, 'one retry per check');
        $down = false;
        $this->clock->advance(self::MIN);
        $result = $cw->check();
        $this->assertSame(['failed'], array_map(fn (Alert $a) => $a->type, $result->alerts));
        $this->assertSame(['failed'], array_map(fn (Alert $a) => $a->type, $got));
        $this->assertSame(self::T0, $got[0]->at, 'the same alert, not a new one');
        $state = $cw->store->getState('r');
        $this->assertSame([], $state->undelivered);
        $this->assertSame(self::T0 + 2 * self::MIN, $state->lastAlertAt);
        $cw->check();
        $this->assertSame(3, $attempts, 'not sent again');
    }

    public function testDeliverCheckQueuesAlertsForAnotherProcesssCheckWhichSendsThemWithTriage(): void
    {
        $clock = new Clock();
        $store = new MemoryStore();
        $unused = new Capture();
        $triaged = 0;
        // The recording process: no network, so it sends nothing itself.
        $recorder = new Cronwatch(store: $store, now: $clock, alerts: [$unused], deliver: 'check', triage: fn () => 'never asked', cronSecret: false);
        $job = $recorder->job('backup', ['schedule' => '40 3 * * *', 'timezone' => 'UTC']);
        $this->failing(fn () => $job->run(self::thrower('disk full')));
        $this->assertSame([], $unused->types(), 'nothing sent from the recording process');
        $state = $store->getState('backup');
        $this->assertSame(['failed'], array_map(fn (Alert $a) => $a->type, $state->undelivered));
        $this->assertNull($state->lastAlertAt);
        $this->assertSame([], $recorder->check()->alerts, 'its own check does not send either');

        // The web server: can send, and has not declared the job.
        $sent = new Capture();
        $server = new Cronwatch(store: $store, now: $clock, alerts: [$sent], triage: function () use (&$triaged): string {
            $triaged++;
            return 'The disk is full.';
        }, cronSecret: false);
        $clock->advance(self::MIN);
        $result = $server->check();
        $this->assertSame(['failed'], array_map(fn (Alert $a) => $a->type, $result->alerts));
        $this->assertSame(['failed'], $sent->types());
        $this->assertSame('The disk is full.', $sent->alerts[0]->triage);
        $this->assertSame(self::T0, $sent->alerts[0]->at, 'the alert from the run, not a new one');
        $this->assertSame(1, $triaged);
        $state = $store->getState('backup');
        $this->assertSame([], $state->undelivered);
        $this->assertSame(self::T0 + self::MIN, $state->lastAlertAt);
        $server->check();
        $this->assertSame(['failed'], $sent->types(), 'sent once');

        // The recovery takes the same route.
        $job->run(fn () => null);
        $server->check();
        $this->assertSame(['failed', 'recovered'], $sent->types());
        $this->assertSame(1, $triaged, 'recoveries are not triaged');
    }

    public function testDeliverTakesOnlyNowOrCheck(): void
    {
        $this->expectExceptionMessage('deliver must be "now" or "check", not "later"');
        new Cronwatch(deliver: 'later');
    }

    public function testOverlappingRunsOfOneJobShareItsStateWithoutLosingUpdates(): void
    {
        // One job run from inside another's, the nearest a single PHP process comes to overlapping runs.
        $cw = $this->make();
        $job = $cw->job('par', ['failuresBeforeAlert' => 2]);
        $this->failing(fn () => $job->run(function () use ($job): never {
            $this->failing(fn () => $job->run(self::thrower()));
            $this->failing(fn () => $job->run(self::thrower()));
            throw new \RuntimeException('x');
        }));
        $this->assertSame(3, $cw->store->getState('par')->consecutiveFailures);
        $this->assertSame(['failed'], $this->capture->types(), 'one alert, not one per run');
    }

    public function testJobRejectsNumbersThatWouldQuietlyTurnACheckOff(): void
    {
        $cw = $this->make();
        foreach ([
            'failuresBeforeAlert' => [['failuresBeforeAlert' => NAN], ['failuresBeforeAlert' => 0], ['failuresBeforeAlert' => 1.5]],
            'budget.cost' => [['budget' => ['cost' => NAN]], ['budget' => ['cost' => INF]], ['budget' => ['cost' => -1]]],
            'grace' => [['grace' => NAN]],
            'timeout' => [['timeout' => 0]],
            'maxDuration' => [['maxDuration' => '0s']],
            'timezone' => [['schedule' => '0 2 * * *', 'timezone' => 'Mars/Olympus']],
        ] as $mentions => $cases) {
            foreach ($cases as $options) {
                try {
                    $cw->job('a', $options);
                    $this->fail("expected an error mentioning {$mentions}");
                } catch (\InvalidArgumentException $error) {
                    $this->assertStringContainsString($mentions, $error->getMessage());
                }
            }
        }
        try {
            (new Cronwatch(defaults: ['failuresBeforeAlert' => NAN]))->job('a');
            $this->fail('expected an error');
        } catch (\InvalidArgumentException $error) {
            $this->assertStringContainsString('failuresBeforeAlert', $error->getMessage());
        }
        $cw->job('a', ['budget' => ['errors' => 0], 'failuresBeforeAlert' => 2, 'timeout' => '5m']);
        // Zones are matched without regard to case, as Intl matches them.
        $this->assertSame('europe/london', $cw->job('b', ['schedule' => '@hourly', 'timezone' => 'europe/london'])->definition->get('timezone'));
    }

    public function testAReturnedStringIsCappedLikeLoggedOutput(): void
    {
        $cw = $this->make();
        $cw->run('big', fn () => str_repeat('x', 40_000));
        $run = $cw->runs('big')[0];
        $this->assertLessThan(17 * 1024, strlen($run->output));
        $this->assertStringStartsWith('[earlier output trimmed]', $run->output);
    }

    public function testRunsTakesAWholeNumberOfRunsInRange(): void
    {
        $cw = $this->make();
        for ($i = 0; $i < 3; $i++) {
            $cw->run('n', fn () => null);
        }
        $this->assertCount(2, $cw->runs('n', 2.7));
        $this->assertCount(1, $cw->runs('n', -4));
        $this->assertCount(3, $cw->runs('n', NAN));
        $entry = $cw->jobsWithRuns(2)[0];
        $this->assertCount(2, $entry->runs);
        $this->assertSame($entry->runs[0]->id, $entry->job->lastRun->id);
    }

    public function testAnErrorIsWrittenNameMessageAndFramesInnermostFirst(): void
    {
        $cw = $this->make();
        $this->failing(fn () => $cw->run('db', function (): never {
            throw new \PDOException('SQLSTATE[HY000] [2002] Connection refused');
        }));
        $error = $cw->runs('db')[0]->error;
        $this->assertMatchesRegularExpression('/^PDOException: SQLSTATE\[HY000\] \[2002\] Connection refused\n    at [^\n]*\{closure[^\n]*\(' . preg_quote(__FILE__, '/') . ':\d+\)\n/', $error);
        $this->assertLessThanOrEqual(6, count(explode("\n", $error)), 'five frames at most');
        $this->assertStringNotContainsString('Error: PDOException', $this->capture->alerts[0]->message);
        $this->assertMatchesRegularExpression('/^PDOException: SQLSTATE/m', $this->capture->alerts[0]->message);
        $this->failing(fn () => $cw->run('db', self::thrower("two\nlines")));
        $this->assertMatchesRegularExpression("/^RuntimeException: two\nlines\n    at /", $cw->runs('db')[0]->error);
    }

    public function testTheBaselineReadsPastRecentFailuresToTwentySuccessfulRuns(): void
    {
        $cw = $this->make();
        $job = $cw->job('base');
        $at = function (int $ms, bool $fail = false) use ($job): void {
            try {
                $job->run(function () use ($ms, $fail): void {
                    $this->clock->advance($ms);
                    if ($fail) {
                        throw new \RuntimeException('x');
                    }
                });
            } catch (\RuntimeException) {
            }
            $this->clock->advance(self::MIN);
        };
        for ($i = 0; $i < 5; $i++) {
            $at(100_000);
        }
        for ($i = 0; $i < 15; $i++) {
            $at(1_000);
        }
        for ($i = 0; $i < 10; $i++) {
            $at(1_000, true);
        }
        // Fifteen 1s runs alone would make 10s the limit; with the five 100s runs, p95 is 100s.
        $at(30_000);
        $this->assertSame(['failed', 'recovered'], $this->capture->types());
    }

    /** A job's failure queued by a deliver: "check" process, so a check elsewhere must triage and send it. */
    private function queued(Store $store, Clock $clock, string $name = 'backup'): Cronwatch
    {
        $recorder = new Cronwatch(store: $store, now: $clock, deliver: 'check', cronSecret: false);
        $this->failing(fn () => $recorder->run($name, self::thrower('disk full')));
        return $recorder;
    }

    public function testADiagnosisMadeOnARetryIsKeptWithTheQueuedAlertAndTriageRunsOncePerAlert(): void
    {
        $clock = new Clock();
        $store = new MemoryStore();
        $this->queued($store, $clock);
        $asked = 0;
        $down = true;
        $sent = [];
        $channel = new Custom('flaky', function (Alert $a) use (&$down, &$sent): void {
            if ($down) {
                throw new \RuntimeException('down');
            }
            $sent[] = $a;
        });
        $server = new Cronwatch(store: $store, now: $clock, alerts: [$channel], triage: function () use (&$asked): string {
            $asked++;
            return 'The disk is full.';
        }, cronSecret: false, onError: fn () => null);
        $server->check();
        $this->assertSame(1, $asked);
        $this->assertSame('The disk is full.', $store->getState('backup')->undelivered[0]->triage, 'the stored copy has it');
        $server->check();
        $server->check();
        $this->assertSame(1, $asked, 'not asked again on later retries');
        $down = false;
        $server->check();
        $this->assertSame([['failed', 'The disk is full.']], array_map(fn (Alert $a) => [$a->type, $a->triage], $sent));
    }

    public function testATriageThatThrowsOrAnswersNothingIsTriedOnceRecordedAsNull(): void
    {
        foreach ([function (): never {
            throw new \RuntimeException('api down');
        }, fn () => '', fn () => null] as $triage) {
            $clock = new Clock();
            $store = new MemoryStore();
            $this->queued($store, $clock);
            $asked = 0;
            $server = new Cronwatch(
                store: $store,
                now: $clock,
                cronSecret: false,
                onError: fn () => null,
                alerts: [new Custom('down', function (): never {
                    throw new \RuntimeException('down');
                })],
                triage: function () use (&$asked, $triage) {
                    $asked++;
                    return $triage();
                },
            );
            for ($i = 0; $i < 3; $i++) {
                $server->check();
            }
            $this->assertSame(1, $asked);
            $queued = $store->getState('backup')->undelivered[0];
            $this->assertNull($queued->triage);
            $this->assertTrue($queued->triageTried);
        }
    }

    public function testRetriesStopOnceACheckHasSpentItsBudgetAndTheRestWait(): void
    {
        $clock = new Clock();
        $store = new MemoryStore();
        foreach (['a', 'b', 'c'] as $name) {
            $this->queued($store, $clock, $name);
        }
        $tried = [];
        // Each attempt takes twelve seconds of wall clock (the client's, set
        // here as the SDK's test mocks Date) and fails.
        $wall = 0;
        $server = new Cronwatch(store: $store, now: $clock, alerts: [new Custom('slow', function (Alert $a) use (&$tried, &$wall): never {
            $tried[] = $a->job;
            $wall += 12_000;
            throw new \RuntimeException('timed out');
        })], cronSecret: false, onError: fn () => null);
        (new \ReflectionProperty(Cronwatch::class, 'wall'))->setValue($server, function () use (&$wall): int {
            return $wall;
        });
        $server->check();
        $this->assertSame(['a', 'b'], $tried, 'twenty seconds cover two attempts');
        $this->assertCount(1, $store->getState('c')->undelivered, 'c is still queued');
        $tried = [];
        $server->check();
        $this->assertSame(['a', 'b'], $tried, 'each check has a fresh budget');
    }

    public function testAnAlertWhoseConditionClosedIsDroppedFromTheRetryQueueARecoveryWhoseConditionsStayClosedIsSent(): void
    {
        $down = true;
        $sent = [];
        $cw = $this->make(['alerts' => [new Custom('flaky', function (Alert $a) use (&$down, &$sent): void {
            if ($down) {
                throw new \RuntimeException('down');
            }
            $sent[] = "{$a->type}@{$a->at}";
        })]]);
        $this->failing(fn () => $cw->run('s', self::thrower()));
        $this->clock->advance(self::MIN);
        $cw->run('s', fn () => null);
        $this->assertSame(['failed', 'recovered'], array_map(fn (Alert $a) => $a->type, $cw->store->getState('s')->undelivered));
        $down = false;
        $this->clock->advance(self::MIN);
        $cw->check();
        $this->assertSame(['recovered@' . (self::T0 + self::MIN)], $sent, 'the failure is over, so only its recovery goes');
        $this->assertSame([], $cw->store->getState('s')->undelivered);
    }

    public function testAnAlertWhoseConditionOpenedAgainAtAnotherTimeIsDroppedAndSoIsARecoveryItUndoes(): void
    {
        $down = true;
        $sent = [];
        $cw = $this->make(['alerts' => [new Custom('flaky', function (Alert $a) use (&$down, &$sent): void {
            if ($down) {
                throw new \RuntimeException('down');
            }
            $sent[] = "{$a->type}@{$a->at}";
        })]]);
        $this->failing(fn () => $cw->run('s', self::thrower()));
        $this->clock->advance(self::MIN);
        $cw->run('s', fn () => null);
        $this->clock->advance(self::MIN);
        $this->failing(fn () => $cw->run('s', self::thrower('again')));
        $this->assertSame(['failed', 'recovered', 'failed'], array_map(fn (Alert $a) => $a->type, $cw->store->getState('s')->undelivered));
        $down = false;
        $this->clock->advance(self::MIN);
        $cw->check();
        $this->assertSame(['failed@' . (self::T0 + 2 * self::MIN)], $sent);
    }

    public function testAJobThatCannotBeEvaluatedIsReportedAndShownAsFailingAndTheOthersAreChecked(): void
    {
        $cw = $this->make();
        $good = $cw->job('good', ['schedule' => 'every 1h']);
        $good->run(fn () => null);
        $cw->store->upsertJob(new JobDefinition(['name' => 'bad', 'schedule' => 'not a schedule']), self::T0);
        $cw->store->upsertJob(new JobDefinition(['name' => 'odd', 'timeout' => 'soon']), self::T0);
        $cw->store->insertRun(new Run('hung', 'odd', 'running', self::T0));
        $this->clock->advance(2 * self::HOUR);
        $result = $cw->check();
        $this->assertSame(['good:missed'], array_map(fn (Alert $a) => "{$a->job}:{$a->type}", $result->alerts));
        $health = [];
        foreach ($result->jobs as $j) {
            $health[$j->name] = $j->health;
        }
        $this->assertSame(['bad' => 'failing', 'good' => 'late', 'odd' => 'failing'], $health);
        $this->assertSame(['checking odd', 'checking bad', 'checking odd'], $this->wheres());
        $this->assertSame(['missed'], $this->capture->types());

        $this->errors = [];
        $jobs = $cw->jobs();
        $this->assertSame([['bad', 'failing', true], ['good', 'late', false], ['odd', 'failing', true]], array_map(fn ($j) => [$j->name, $j->health, $j->nextExpectedAt === null], $jobs));
        $this->assertSame(['reading bad', 'reading odd'], $this->wheres());
        $this->assertSame('failing', $cw->jobSummary('bad')->health);
        $cw->silence('bad', '1h');
        $this->assertSame('silenced', $cw->jobSummary('bad')->health);
    }

    public function testTrimmingTheUndeliveredQueuePastTwentyIsReported(): void
    {
        $cw = $this->make(['deliver' => 'check', 'alerts' => null]);
        for ($i = 0; $i < 10; $i++) {
            $this->failing(fn () => $cw->run('q', self::thrower()));
            $cw->run('q', fn () => null);
        }
        $this->assertCount(20, $cw->store->getState('q')->undelivered);
        $this->assertSame([], $this->wheres());
        $this->failing(fn () => $cw->run('q', self::thrower()));
        $this->assertCount(20, $cw->store->getState('q')->undelivered);
        $this->assertSame(['alert queue for q'], $this->wheres());
    }

    public function testAnUpdateThatKeepsLosingGivesUpAndReportsAndTheRunStillFinishes(): void
    {
        $store = new FlakyStore(new MemoryStore());
        // Always refuses: as if another process wrote between every read and write.
        $store->hooks['compareAndSetState'] = fn () => false;
        $cw = $this->make(['store' => $store]);
        $this->failing(fn () => $cw->run('busy', self::thrower()));
        $this->assertSame(['evaluating busy'], $this->wheres());
        $this->assertSame('failed', $cw->runs('busy')[0]->status);
    }

    public function testARedactThatFailsIsReportedAndTheDefaultIsUsed(): void
    {
        $cw = $this->make(['redact' => fn (string $text) => null]);
        $cw->run('r', fn () => 'password=hunter2');
        $this->assertSame('password=[redacted]', $cw->runs('r')[0]->output);
        $this->assertSame(['redact'], $this->wheres());
        $plain = $this->make(['redact' => false]);
        $plain->run('r', fn () => 'password=hunter2');
        $this->assertSame('password=hunter2', $plain->runs('r')[0]->output);
    }

    public function testASecretSplitByThe16KbCutIsRedactedWhole(): void
    {
        $cap = \Cronwatch\Output::OUTPUT_CAP;
        $pem = "-----BEGIN PRIVATE KEY-----\n" . implode("\n", array_map(fn (int $i) => str_repeat('QUJD', 15) . sprintf('%04d', $i), range(0, 24))) . "\n-----END PRIVATE KEY-----";
        $bearer = 'Authorization: Bearer opaqueTOKENvalue1234567890';
        $cw = $this->make();
        // The cut lands inside the key's body, and in a second run just after "Bear".
        $cw->run('pem', function ($job) use ($cap, $pem): void {
            $job->log(str_repeat('x', $cap));
            $job->log(substr($pem, 0, 900));
            $job->log(substr($pem, 900));
            $job->log('done');
        });
        $output = $cw->runs('pem')[0]->output;
        $this->assertStringNotContainsString('QUJD', $output);
        $this->assertStringEndsWith("[redacted]\ndone", $output);
        $tail = str_repeat('y', $cap - 30);
        $cw->run('bearer', fn () => "{$bearer}\n{$tail}");
        $output = $cw->runs('bearer')[0]->output;
        $this->assertStringNotContainsString('opaqueTOKEN', $output);
        $this->assertLessThanOrEqual($cap + strlen("[earlier output trimmed]\n"), strlen($output));

        // Errors, recorded runs and flushed lines the same way.
        $this->failing(fn () => $cw->run('thrown', self::thrower(str_repeat('e', $cap) . " {$bearer} " . str_repeat('z', $cap - 40))));
        $this->assertStringNotContainsString('opaqueTOKEN', $cw->runs('thrown')[0]->error);
        $cw->job('imported');
        $cw->recordRun(['id' => 'i1', 'job' => 'imported', 'status' => 'ok', 'startedAt' => 1, 'finishedAt' => 2, 'durationMs' => 1, 'error' => null, 'output' => "{$bearer}\n{$tail}", 'metrics' => [], 'trigger' => 'source']);
        $this->assertStringNotContainsString('opaqueTOKEN', $cw->getRun('i1')->output);
        $handle = $cw->job('flushed')->start();
        $handle->log($bearer);
        $handle->log($tail);
        $handle->flush();
        $this->assertStringNotContainsString('opaqueTOKEN', $cw->getRun($handle->id)->output);
        $handle->finish();
        $this->assertStringNotContainsString('opaqueTOKEN', $cw->getRun($handle->id)->output);
    }

    public function testTextPastTheRedactionWindowNeverKeepsWhatCameRightAfterItsCut(): void
    {
        $cap = \Cronwatch\Output::OUTPUT_CAP;
        $edge = \Cronwatch\Output::REDACT_EDGE;
        $trimmed = "[earlier output trimmed]\n";
        $redact = \Cronwatch\Output::redactSecrets(...);
        $text = "-----BEGIN PRIVATE KEY-----\n" . str_repeat('QUJD', 4000) . "\n" . str_repeat('k', $cap + $edge - 8000);
        $kept = \Cronwatch\Output::redactAndCap($text, $redact);
        $this->assertStringStartsWith($trimmed, $kept);
        $this->assertSame(strlen($trimmed) + $cap, strlen($kept));
        $this->assertStringNotContainsString('QUJD', $kept);

        // A redaction that shrinks the window cannot pull its first units into view.
        $shrinking = fn (string $t) => (string) preg_replace('/s{100}/', '', $t);
        $this->assertSame($trimmed, \Cronwatch\Output::redactAndCap(str_repeat('QUJD', 100) . str_repeat('s', $cap + $edge), $shrinking));

        // Short text is redacted whole, then capped as before; NULs go either side of redact.
        $this->assertSame('password=[redacted]', \Cronwatch\Output::redactAndCap('password=x', $redact));
        $this->assertSame('ab', \Cronwatch\Output::redactAndCap("a\0b", fn (string $t) => "{$t}\0"));
        $this->assertSame($trimmed . str_repeat('x', $cap), \Cronwatch\Output::redactAndCap(str_repeat('x', $cap + 5), $redact));
    }

    public function testACheckCalledFromInsideACheckIsRefused(): void
    {
        $cw = null;
        $cw = $this->make(['alerts' => [new Custom('loop', function () use (&$cw): void {
            $cw->check();
        })]]);
        $cw->job('sync', ['schedule' => 'every 1h']);
        $cw->check();
        $this->clock->advance(2 * self::HOUR);
        $cw->check();
        $this->assertSame(['alert channel loop'], $this->wheres());
        $this->assertStringContainsString('from inside a check', $this->messages()[0]);
    }

    public function testAWriteWhoseAnswerWasLostWithTheConnectionIsNotAppliedTwice(): void
    {
        // The state write and the finish land, then the connection breaks and the
        // store sends each again, which now matches nothing: the store reads what
        // is there and counts its own first send, so the failure is judged once
        // and alerted.
        $store = new \Cronwatch\Tests\Support\ResendingStore();
        $cw = $this->make(['store' => $store]);
        $job = $cw->job('flaky', ['failuresBeforeAlert' => 1]);
        $job->run(fn () => 'warm up');
        $store->breakAfter = ['casInsert'];
        try {
            $job->run(function (): void {
                throw new \RuntimeException('down');
            });
        } catch (\RuntimeException) {
        }
        $this->assertSame(1, $store->resends);
        $this->assertSame(['failed'], $this->capture->types(), 'alerted once');
        $this->assertSame(1, $store->getState('flaky')->consecutiveFailures, 'counted once');

        $store->breakAfter = ['updateRunIf'];
        $handle = $job->start(id: 'batch-1');
        $this->assertSame('ok', $handle->finish()->status);
        $this->assertSame(2, $store->resends);
        $this->assertSame(['failed', 'recovered'], $this->capture->types(), 'the finish was judged, not taken for another process\'s');

        $store->breakAfter = ['deleteRunIf'];
        $store->insertRun(new Run('gone', 'flaky', 'running', 1));
        $this->assertTrue($store->deleteRunIf('gone', 'flaky', 'running'));
        $this->assertSame([], $this->errors);
    }
}
