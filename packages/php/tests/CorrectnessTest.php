<?php

declare(strict_types=1);

namespace Cronwatch\Tests;

use Cronwatch\Alert;
use Cronwatch\AlertDraft;
use Cronwatch\Alerts\Custom;
use Cronwatch\Cronwatch;
use Cronwatch\Format;
use Cronwatch\JobDefinition;
use Cronwatch\Js;
use Cronwatch\Pattern;
use Cronwatch\Run;
use Cronwatch\Schedule;
use Cronwatch\Tests\Support\Capture;
use Cronwatch\Tests\Support\Clock;
use PHPUnit\Framework\TestCase;

/** correctness.test.ts, but for the routes test, which comes with the web phase. */
final class CorrectnessTest extends TestCase
{
    private const MIN = Clock::MIN;

    public function testAnAlertStillBeingSentCannotOverwriteWhatARunDidMeanwhile(): void
    {
        $clock = new Clock();
        $sent = [];
        $job = null;
        $cw = new Cronwatch(now: $clock, cronSecret: false, alerts: [
            // The missed alert takes a while (a slow webhook, or triage); the job turns up meanwhile.
            new Custom('slow-for-missed', function (Alert $a) use (&$sent, &$job): void {
                if ($a->type === 'missed') {
                    $job->run(fn () => null);
                }
                $sent[] = $a->type;
            }),
        ]);
        $job = $cw->job('sync', ['schedule' => 'every 5m', 'grace' => '1m']);
        $job->run(fn () => null);
        $clock->advance(7 * self::MIN);
        $cw->check();
        $this->assertSame(['recovered', 'missed'], $sent);
        $this->assertSame([], $cw->store->getState('sync')->open, 'missed stays closed');
        $clock->advance(self::MIN);
        $job->run(fn () => null);
        $this->assertSame(['recovered', 'missed'], $sent, 'no second recovered');
    }

    public function testPruningKeepsEachJobsNewestRunSoAMonthlyJobIsNotReportedMissed(): void
    {
        $clock = new Clock(Js::dateUtc(2026, 0, 1, 0, 0));
        $alerts = new Capture();
        $cw = new Cronwatch(now: $clock, alerts: [$alerts], cronSecret: false, retention: '30d');
        $monthly = $cw->job('monthly', ['schedule' => '0 0 1 * *', 'timezone' => 'UTC']);
        $monthly->run(fn () => null);
        $clock->set(Js::dateUtc(2026, 0, 31, 12));
        $this->assertSame(0, $cw->check()->pruned);
        $clock->advance(2 * 60 * self::MIN);
        $cw->check();
        $this->assertSame([], $alerts->types());
        $this->assertSame('healthy', $cw->jobSummary('monthly')->health);
    }

    public function testAnExpectPatternGivesTheSameAnswerEveryRun(): void
    {
        $cw = new Cronwatch(alerts: [new Capture()], cronSecret: false);
        $job = $cw->job('g', ['expect' => new Pattern('/done/')]);
        for ($i = 0; $i < 4; $i++) {
            $job->run(fn ($j) => $j->log('done'));
        }
        $this->assertSame(['ok', 'ok', 'ok', 'ok'], array_map(fn (Run $r) => $r->status, $cw->runs('g')));
        $this->assertSame('matches /done/', $cw->store->getJob('g')->definition->get('expect'));
    }

    public function testExpectSeesALineLoggedEarlyEvenAfterTheStoredOutputHasDroppedIt(): void
    {
        $cw = new Cronwatch(alerts: [new Capture()], cronSecret: false);
        $cw->run('report', function ($j): void {
            $j->log('Report written: /tmp/r.pdf');
            for ($i = 0; $i < 3000; $i++) {
                $j->log("row {$i} " . str_repeat('x', 40));
            }
        }, ['expect' => 'Report written']);
        $run = $cw->runs('report')[0];
        $this->assertSame('ok', $run->status);
        $this->assertStringNotContainsString('Report written', $run->output, 'the stored output is still only the tail');
    }

    public function testAnIntervalJobWhoseRunIsStillGoingIsBusyNotMissed(): void
    {
        $clock = new Clock();
        $alerts = new Capture();
        $cw = new Cronwatch(now: $clock, alerts: [$alerts], cronSecret: false);
        $job = $cw->job('long', ['schedule' => 'every 5m', 'grace' => '2m']);
        $job->run(function () use ($cw, $clock): void {
            $clock->advance(8 * self::MIN);
            $cw->check();
        });
        $this->assertSame([], $alerts->types(), 'and no recovered for a miss that never was');
    }

    public function testARunACheckMarkedStuckThatThenFailsCountsOnce(): void
    {
        $clock = new Clock();
        $alerts = new Capture();
        $cw = new Cronwatch(now: $clock, alerts: [$alerts], cronSecret: false);
        $job = $cw->job('slowpoke', ['timeout' => '1m', 'failuresBeforeAlert' => 2]);
        try {
            $job->run(function () use ($cw, $clock): never {
                $clock->advance(2 * self::MIN);
                $cw->check();
                $this->assertSame(1, $cw->store->getState('slowpoke')->consecutiveFailures);
                throw new \RuntimeException('gave up');
            });
        } catch (\RuntimeException) {
        }
        $this->assertSame(1, $cw->store->getState('slowpoke')->consecutiveFailures);
        $this->assertSame([], $alerts->types(), 'one run is one failure, under the threshold of two');
        $this->assertSame('RuntimeException: gave up', explode("\n", $cw->runs('slowpoke')[0]->error)[0], 'the run keeps its real error');
    }

    public function testALateSuccessAfterAStuckMarkClosesStuckAndRecovers(): void
    {
        $clock = new Clock();
        $alerts = new Capture();
        $cw = new Cronwatch(now: $clock, alerts: [$alerts], cronSecret: false);
        $job = $cw->job('late', ['timeout' => '30s']);
        $job->run(function () use ($cw, $clock): void {
            $clock->advance(self::MIN);
            $fromCheck = $cw->check()->alerts;
            $this->assertStringStartsWith('Still running after 30s;', $fromCheck[0]->run->error);
        });
        $this->assertSame(['stuck', 'recovered'], $alerts->types());
    }

    public function testFireTimesAroundTheAutumnClockChangeAreNeverInThePast(): void
    {
        foreach ([['Europe/London', Js::dateUtc(2026, 9, 24, 22)], ['America/New_York', Js::dateUtc(2026, 10, 1, 3)]] as [$tz, $day]) {
            foreach (['*/15 * * * *', '30 1 * * *', '0 * * * *'] as $expr) {
                $p = Schedule::parse($expr, $tz);
                for ($t = $day; $t < $day + 8 * 3_600_000; $t += 5 * self::MIN) {
                    $next = Schedule::nextFire($p, $t, null);
                    $this->assertGreaterThan($t, $next, "{$tz} {$expr}: next " . Js::iso($next) . ' after ' . Js::iso($t));
                }
            }
        }
    }

    public function testAFailedAlertNamesTheErrorOnce(): void
    {
        $now = Clock::T0;
        $message = fn (string $error) => Format::composeAlert(
            new AlertDraft('failed', new Run('r', 'j', 'failed', $now, $now, 5, $error), ['consecutiveFailures' => 1, 'threshold' => 1]),
            new JobDefinition(['name' => 'j']),
            $now,
        )->message;
        $this->assertMatchesRegularExpression('/^Error: connect ECONNREFUSED/m', $message('Error: connect ECONNREFUSED 10.0.0.12:5432'));
        $this->assertStringNotContainsString('Error: Error:', $message('Error: connect ECONNREFUSED 10.0.0.12:5432'));
        $this->assertMatchesRegularExpression('/^TypeError: x is undefined/m', $message('TypeError: x is undefined'));
        $this->assertMatchesRegularExpression('/^Error: Output did not contain "wrote"/m', $message('Output did not contain "wrote"'));
        $this->assertMatchesRegularExpression('/^Error: HTTP 503/m', $message('HTTP 503 Service Unavailable'));
    }

    public function testAPatternPcreGaveUpOnSaysSo(): void
    {
        $jit = ini_get('pcre.jit');
        $limit = ini_get('pcre.backtrack_limit');
        ini_set('pcre.jit', '0');
        ini_set('pcre.backtrack_limit', '1000');
        try {
            $this->assertSame(
                'Output did not match /(a|aa)+c/ (Backtrack limit exhausted)',
                \Cronwatch\Serialize::checkExpectation(new Pattern('/(a|aa)+c/'), str_repeat('a', 40) . 'b c'),
            );
            $this->assertSame('Output did not match /x/', \Cronwatch\Serialize::checkExpectation(new Pattern('/x/'), 'y'));
        } finally {
            ini_set('pcre.jit', (string) $jit);
            ini_set('pcre.backtrack_limit', (string) $limit);
        }
    }

    public function testAPatternThatBacktracksWithoutEndStopsAtTheLimitAndFailsTheRun(): void
    {
        // Stars back to back over newlines they do not match backtrack
        // polynomially (V8 takes seconds over 100); PCRE's backtrack limit,
        // at its default, stops them in milliseconds and the run fails.
        $cw = new Cronwatch(alerts: [new Capture()], cronSecret: false);
        $output = str_repeat("\n", 32_000);
        $started = hrtime(true);
        $cw->job('slow', ['expect' => new Pattern('/\n*\n*\n*\n*\n*[xy]/')])->run(fn () => $output);
        $took = (hrtime(true) - $started) / 1e9;
        $run = $cw->runs('slow')[0];
        $this->assertSame('failed', $run->status);
        $this->assertSame('Output did not match /\n*\n*\n*\n*\n*[xy]/ (Backtrack limit exhausted)', $run->error);
        $this->assertLessThan(3.0, $took);
        // Without the JIT too, where the limit counts the same way.
        $jit = ini_get('pcre.jit');
        ini_set('pcre.jit', '0');
        try {
            $started = hrtime(true);
            $this->assertSame(
                'Output did not match /\n*\n*\n*\n*\n*[xy]/ (Backtrack limit exhausted)',
                \Cronwatch\Serialize::checkExpectation(new Pattern('/\n*\n*\n*\n*\n*[xy]/'), $output),
            );
            $this->assertLessThan(3.0, (hrtime(true) - $started) / 1e9);
        } finally {
            ini_set('pcre.jit', (string) $jit);
        }
        $this->assertNull(\Cronwatch\Serialize::checkExpectation(new Pattern('/\n*\n*\n*\n*\n*[xy]/'), $output . 'y'));
    }

    public function testADateIntervalIsItsMillisecondsAndANegativeOneIsRefused(): void
    {
        $this->assertSame(5_400_000, \Cronwatch\Duration::parse(new \DateInterval('PT1H30M')));
        $back = new \DateInterval('PT15M');
        $back->invert = 1;
        $this->expectExceptionMessage('retention must be a non-negative number of milliseconds');
        new Cronwatch(retention: $back);
    }
}
