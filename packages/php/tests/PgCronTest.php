<?php

declare(strict_types=1);

namespace Cronwatch\Tests;

use Cronwatch\Cronwatch;
use Cronwatch\JobSummary;
use Cronwatch\Js;
use Cronwatch\Pattern;
use Cronwatch\Sources\PgCron;
use Cronwatch\Store\MemoryStore;
use Cronwatch\Store\PostgresStore;
use Cronwatch\Store\Store;
use Cronwatch\Tests\Support\Capture;
use Cronwatch\Tests\Support\Clock;
use PHPUnit\Framework\TestCase;

/**
 * The pg_cron source (sources/pgcron.ts): conformance/pgcron.json replayed,
 * then the SDK's pgcron.test.ts against cron.job and cron.job_run_details
 * held in memory, and, when CRONWATCH_TEST_PGCRON is the URL of a Postgres
 * with pg_cron, against the real thing through PDO.
 */
final class PgCronTest extends TestCase
{
    private const T0 = Clock::T0;
    private const MIN = Clock::MIN;
    private const HOUR = Clock::HOUR;
    private const DAY = 24 * Clock::HOUR;

    // ------------------------------------------------------------ conformance/pgcron.json

    private static function fixture(): \stdClass
    {
        static $fixture = null;
        return $fixture ??= Js::parse((string) file_get_contents(__DIR__ . '/../../../conformance/pgcron.json'));
    }

    private static function differs(mixed $expected, mixed $actual): ?string
    {
        $e = Js::stringify($expected);
        $a = Js::stringify($actual);
        return $e === $a ? null : "expected {$e}\n    got      {$a}";
    }

    /** @param \Closure(\stdClass): ?string $check */
    private function eachCase(array $cases, \Closure $check): void
    {
        $failures = [];
        foreach ($cases as $i => $case) {
            try {
                $message = $check($case);
            } catch (\Throwable $error) {
                $message = 'threw ' . get_class($error) . ': ' . $error->getMessage();
            }
            if ($message !== null) {
                $failures[] = "#{$i} " . substr(Js::stringify($case), 0, 300) . "\n    {$message}";
            }
        }
        $this->assertSame([], $failures, implode("\n", $failures));
    }

    public function testTheHoldIsTheSdks(): void
    {
        $this->assertSame(self::fixture()->holdMs, PgCron::HOLD_MS);
    }

    public function testSchedules(): void
    {
        $this->eachCase(self::fixture()->schedules, fn (\stdClass $c) => self::differs($c->result, PgCron::schedule($c->schedule)));
    }

    public function testNames(): void
    {
        $this->eachCase(self::fixture()->names, fn (\stdClass $c) => self::differs($c->name, PgCron::jobName(Js::fields($c->job))));
    }

    public function testRowsAsRuns(): void
    {
        $this->eachCase(self::fixture()->runs, fn (\stdClass $c) => self::differs($c->run, PgCron::run($c->row, 'db:j', 'pgcron:db:', $c->fallbackAt ?? self::T0)));
    }

    // ------------------------------------------------------------ the pure parts

    public function testSchedulesAndNames(): void
    {
        $this->assertSame('every 30s', PgCron::schedule('30 seconds'));
        $this->assertSame('every 1s', PgCron::schedule('1 second'));
        $this->assertSame('0 0 L * *', PgCron::schedule('0 0 $ * *'));
        $this->assertSame('*/5 * * * *', PgCron::schedule(' */5  * * * * '));
        $this->assertNull(PgCron::schedule('@reboot'));
        $this->assertSame('0 5 * * *', PgCron::schedule('0 5 * * * *'), 'pg_cron ignores fields past the fifth');
        $this->assertSame('@hourly', PgCron::schedule('@hourly'));
        $this->assertSame('nightly-vacuum', PgCron::jobName(['jobid' => 7, 'jobname' => 'nightly vacuum']));
        $this->assertSame('pg_cron:7', PgCron::jobName(['jobid' => 7, 'jobname' => null]));
        $this->assertSame('pg_cron:7', PgCron::jobName(['jobid' => 7, 'jobname' => '  ']));
    }

    public function testRowsBecomeRuns(): void
    {
        $row = ['runid' => '9', 'jobid' => '1', 'status' => 'failed', 'return_message' => "  ERROR:  boom\n", 'start_time' => self::T0, 'end_time' => '2026-01-05 09:30:02.5+00'];
        $run = PgCron::run($row, 'vacuum', 'pgcron:');
        $this->assertSame(['pgcron:9', 'failed', self::T0, self::T0 + 2500, 2500, 'ERROR:  boom', null, 'pg_cron'], [$run->id, $run->status, $run->startedAt, $run->finishedAt, $run->durationMs, $run->error, $run->output, $run->trigger]);
        $this->assertSame('pg_cron reported the run as failed', PgCron::run(['return_message' => ' '] + $row, 'vacuum', 'pgcron:')->error);
        $going = PgCron::run(['status' => 'running', 'end_time' => null] + $row, 'vacuum', 'pgcron:');
        $this->assertSame(['running', null, null, null], [$going->status, $going->finishedAt, $going->durationMs, $going->error]);
        $this->assertNull(PgCron::run(['status' => 'starting', 'start_time' => null, 'end_time' => null] + $row, 'vacuum', 'pgcron:'), 'not started yet');
        // A run a server restart cut off: failed, no start_time; it starts at its end_time, else at the fallback.
        $cut = PgCron::run(['start_time' => null, 'return_message' => 'server restarted'] + $row, 'vacuum', 'pgcron:', self::T0 - self::HOUR);
        $this->assertSame(['failed', self::T0 + 2500, self::T0 + 2500, 0, 'server restarted'], [$cut->status, $cut->startedAt, $cut->finishedAt, $cut->durationMs, $cut->error]);
        $timeless = PgCron::run(['start_time' => null, 'end_time' => null] + $row, 'vacuum', 'pgcron:', self::T0 - self::HOUR);
        $this->assertSame([self::T0 - self::HOUR, self::T0 - self::HOUR, 0], [$timeless->startedAt, $timeless->finishedAt, $timeless->durationMs]);
    }

    public function testTimestampsAreReadAsTheSdksDriverReadsThem(): void
    {
        $this->assertSame(self::T0, PgCron::epochMs('2026-01-05 09:30:00+00'));
        $this->assertSame(self::T0 + 123, PgCron::epochMs('2026-01-05 09:30:00.123456+00'), 'microseconds cut to milliseconds');
        $this->assertSame(self::T0 - 330 * self::MIN, PgCron::epochMs('2026-01-05 09:30:00+05:30'));
        $this->assertSame(self::T0 + 8 * self::HOUR, PgCron::epochMs('2026-01-05 09:30:00-08'));
        // pg's postgres-date takes the fraction as 1000 * parseFloat(".999999"), cut to a whole number.
        $this->assertSame(self::T0 + 999, PgCron::epochMs('2026-01-05 09:30:00.999999+00'));
        $this->assertSame(self::T0 + 291, PgCron::epochMs('2026-01-05T09:30:00.291Z'), 'an ISO string as Date parses it');
        $this->assertSame(self::T0 + 5, PgCron::epochMs(new \DateTimeImmutable('2026-01-05 09:30:00.005', new \DateTimeZone('UTC'))));
    }

    public function testWhatItQueriesThrough(): void
    {
        $this->expectException(\InvalidArgumentException::class);
        new PgCron(new \stdClass());
    }

    // ------------------------------------------------------------ a pg_cron in memory

    private static function client(FakeCron $cron, ?Clock $clock = null, ?Store $store = null, ?array &$errors = null, ?Capture $capture = null, array $options = []): Cronwatch
    {
        return new Cronwatch(
            store: $store ?? new MemoryStore(),
            alerts: $capture !== null ? [$capture] : [],
            now: $clock ?? new Clock(),
            cronSecret: false,
            onError: function (\Throwable $error) use (&$errors): void {
                if (is_array($errors)) {
                    $errors[] = $error->getMessage();
                }
            },
            sources: [new PgCron($cron, ...$options)],
        );
    }

    /** @param list<JobSummary> $jobs */
    private static function named(array $jobs, string $name): JobSummary
    {
        foreach ($jobs as $job) {
            if ($job->name === $name) {
                return $job;
            }
        }
        throw new \LogicException("no job {$name}");
    }

    /** @param list<string> $errors */
    private static function unexpected(array $errors): array
    {
        return array_values(array_filter($errors, fn (string $e) => !str_contains($e, 'cron.') && !str_contains($e, 'row level')));
    }

    public function testJobsAreDeclaredHistoryIsCopiedQuietlyAndImportsAreIdempotent(): void
    {
        $clock = new Clock();
        $cron = new FakeCron();
        $cron->job(1, 'nightly vacuum', '0 3 * * *');
        $cron->job(2, null, '10 seconds');
        $cron->job(3, 'paused', '0 * * * *', false);
        $cron->job(4, 'other', '0 * * * *');
        $three = Js::dateUtc(2026, 0, 5, 3);
        for ($i = 24; $i > 0; $i--) {
            $cron->add(1, 'succeeded', $three - $i * self::DAY, $three - $i * self::DAY + 5000, 'VACUUM');
        }
        $cron->add(1, 'failed', $three, $three + 2000, "ERROR:  deadlock detected\n");
        $store = new MemoryStore();
        $capture = new Capture();
        $fresh = fn () => self::client($cron, $clock, $store, capture: $capture, options: ['jobs' => fn (array $j) => $j['jobid'] !== 4, 'prefix' => 'db:']);

        $cw = $fresh();
        $first = $cw->check();
        $this->assertSame(['db:nightly-vacuum', 'db:paused', 'db:pg_cron:2'], array_map(fn ($j) => $j->name, $first->jobs));
        $vacuum = self::named($first->jobs, 'db:nightly-vacuum');
        $this->assertSame('0 3 * * *', $vacuum->definition->schedule);
        $this->assertSame('UTC', $vacuum->definition->timezone);
        $this->assertSame(['pg_cron'], $vacuum->definition->tags);
        $this->assertSame('every 10s', self::named($first->jobs, 'db:pg_cron:2')->definition->schedule);
        $this->assertNull(self::named($first->jobs, 'db:paused')->definition->schedule, 'a paused job is not expected to run');
        $runs = $cw->runs('db:nightly-vacuum', 100);
        $this->assertCount(20, $runs, 'twenty newest runs copied on first sight');
        $this->assertSame(['pgcron:db:25', 'failed', 'ERROR:  deadlock detected', 2000, 'pg_cron'], [$runs[0]->id, $runs[0]->status, $runs[0]->error, $runs[0]->durationMs, $runs[0]->trigger]);
        $this->assertSame('VACUUM', $runs[1]->output);
        $this->assertSame(['failed'], $capture->types(), 'only the newest finished run is judged; history does not alert');

        $cw->check();
        $cw = $fresh();
        $cw->check();
        $this->assertCount(20, $cw->runs('db:nightly-vacuum', 100), 'a re-import, even after a restart, adds nothing');
        $this->assertSame(['failed'], $capture->types());

        // A run not yet started holds the cursor; the run after it is copied now and it is copied once it starts.
        $starting = $cron->add(2, 'starting', null, null);
        $cron->add(2, 'succeeded', self::T0 - 5000, self::T0 - 4000, '1 row');
        $clock->advance(1000);
        $cw->check();
        $this->assertSame(['pgcron:db:27'], array_map(fn ($r) => $r->id, $cw->runs('db:pg_cron:2')));
        $starting->status = 'running';
        $starting->start = self::T0 - 3000;
        $cw->check();
        $this->assertSame('running', $cw->getRun('pgcron:db:26')->status);
        $starting->status = 'failed';
        $starting->end = self::T0 - 1000;
        $starting->message = 'ERROR:  boom';
        $clock->advance(1000);
        $cw->check();
        $finished = $cw->getRun('pgcron:db:26');
        $this->assertSame(['failed', 2000], [$finished->status, $finished->durationMs]);
        $this->assertSame(['failed', 'failed'], $capture->types(), 'a run that was running and then failed is judged when it finishes');

        // The nightly job stops running: missed, from its schedule, with no run details at all.
        $clock->set(Js::dateUtc(2026, 0, 6, 3, 11));
        $cron->add(2, 'succeeded', $clock->now - 2000, $clock->now - 1000, '1 row');
        $later = $cw->check();
        $seen = array_map(fn ($a) => "{$a->type} {$a->job}", $later->alerts);
        sort($seen);
        $this->assertSame(['missed db:nightly-vacuum', 'recovered db:pg_cron:2'], $seen);
        $this->assertSame([], $cw->check()->alerts, 'each condition alerts once');

        // Unscheduled: its name keeps its history but loses its schedule, so it is never missed again,
        // and the missed alert it had open closes with a recovery that says so.
        array_shift($cron->jobs);
        $clock->set(Js::dateUtc(2026, 0, 8, 3, 11));
        $gone = $cw->check();
        $now = self::named($gone->jobs, 'db:nightly-vacuum');
        $this->assertNull($now->definition->schedule);
        $this->assertStringContainsString('no longer watched', $now->definition->description);
        $this->assertSame(['failed'], $now->open, 'its failure stays open until a successful run');
        $closed = array_values(array_filter($gone->alerts, fn ($a) => $a->job === 'db:nightly-vacuum'));
        $this->assertSame(['recovered'], array_map(fn ($a) => $a->type, $closed));
        $this->assertSame('db:nightly-vacuum is no longer scheduled', $closed[0]->title);
        $this->assertSame(['after' => ['missed'], 'reason' => 'unscheduled', 'since' => Js::dateUtc(2026, 0, 6, 3, 11)], $closed[0]->details);
        $this->assertSame([], array_filter($cw->check()->alerts, fn ($a) => $a->job === 'db:nightly-vacuum'), 'once');
        $this->assertCount(20, $cw->runs('db:nightly-vacuum', 100), 'its history is kept');
    }

    public function testJobOptionsApplyAndAnUnreadableScheduleIsReported(): void
    {
        $cron = new FakeCron();
        $cron->job(1, 'odd', 'not a schedule');
        $errors = [];
        $cw = self::client($cron, null, null, $errors, options: ['options' => ['grace' => '1m', 'expect' => new Pattern('/rows?/')]]);
        $cron->add(1, 'succeeded', self::T0 - 1000, self::T0, 'nothing');
        $result = $cw->check();
        $this->assertNull($result->jobs[0]->definition->schedule);
        $this->assertSame('1m', $result->jobs[0]->definition->grace);
        $this->assertStringContainsString('watching it without a schedule', implode("\n", $errors));
        $run = $cw->runs('odd')[0];
        $this->assertSame('failed', $run->status, 'expect applies to imported output');
        $this->assertStringContainsString('did not match', (string) $run->error);
    }

    public function testWarningsComeOnce(): void
    {
        $cron = new FakeCron();
        $cron->settingsDenied = true;
        $errors = [];
        $cw = new Cronwatch(alerts: [], cronSecret: false, onError: function (\Throwable $e, string $where) use (&$errors): void {
            $errors[] = "{$where}: {$e->getMessage()}";
        }, sources: [new PgCron($cron)]);
        $cw->check();
        $cw->check();
        $this->assertCount(2, $errors, implode("\n", $errors));
        $this->assertStringContainsString('could not read cron.timezone; assuming UTC', $errors[0]);
        $this->assertStringContainsString('cron.job shows no jobs', $errors[1]);
    }

    public function testARunCutOffByARestartIsRecordedAndOneHeldRunNeverStopsTheOthers(): void
    {
        $clock = new Clock();
        $cron = new FakeCron();
        $cron->job(1, 'fast', '30 seconds');
        $cron->job(2, 'other', '0 * * * *');
        $errors = [];
        $capture = new Capture();
        $cw = self::client($cron, $clock, null, $errors, $capture);
        $cron->add(1, 'succeeded', self::T0 - 60_000, self::T0 - 59_000, '1 row');
        $cw->check();
        // pg_cron restarts while a run is queued: it marks it failed, "server restarted", with no times at all.
        $restarted = $cron->add(1, 'failed', null, null, 'server restarted');
        // The fast job then runs far more than a page's worth, and the other job fails after all of them.
        for ($i = 0; $i < 520; $i++) {
            $cron->add(1, 'succeeded', self::T0 - 50_000 + $i, self::T0 - 50_000 + $i + 1, '1 row');
        }
        $failure = $cron->add(2, 'failed', self::T0 - 1000, self::T0 - 500, 'ERROR:  disk full');
        $queued = $cron->add(1, 'starting', null, null);
        $clock->advance(1000);
        $cw->check();
        $cw->check();
        $cut = $cw->getRun("pgcron:{$restarted->runid}");
        $this->assertSame(['failed', 'server restarted'], [$cut->status, $cut->error]);
        $this->assertSame(self::T0 - 60_000, $cut->startedAt, "placed at the job's newest run before it");
        $this->assertSame('failed', $cw->getRun("pgcron:{$failure->runid}")->status, "the other job's failure is not starved");
        $this->assertNotEmpty(array_filter($capture->alerts, fn ($a) => $a->type === 'failed' && $a->job === 'other'));
        $this->assertNull($cw->getRun("pgcron:{$queued->runid}"), 'a queued run is held');

        // Held only so long: then it is copied as running from when it was first seen, and a late start updates nothing but its end.
        $clock->advance(11 * self::MIN);
        $cw->check();
        $waiting = $cw->getRun("pgcron:{$queued->runid}");
        $this->assertSame(['running', self::T0 + 1000], [$waiting->status, $waiting->startedAt]);
        $queued->status = 'succeeded';
        $queued->start = $clock->now - 2000;
        $queued->end = $clock->now - 1000;
        $clock->advance(1000);
        $cw->check();
        $this->assertSame('ok', $cw->getRun("pgcron:{$queued->runid}")->status);
        $this->assertSame([], self::unexpected($errors));
    }

    public function testFirstSightNeverJudgesHistoryEvenWithAHeldOrCutOffRunAmongTheNewest(): void
    {
        $cron = new FakeCron();
        $cron->job(1, 'nightly', '0 3 * * *');
        for ($i = 0; $i < 30; $i++) {
            $cron->add(1, 'failed', self::T0 - (40 - $i) * self::HOUR, self::T0 - (40 - $i) * self::HOUR + 1000, 'ERROR:  old');
        }
        $cron->add(1, 'failed', null, null, 'server restarted');
        for ($i = 0; $i < 19; $i++) {
            $start = self::T0 - (int) ((10 - $i / 2) * self::HOUR);
            $cron->add(1, 'succeeded', $start, $start + 1000, 'ok');
        }
        $capture = new Capture();
        $cw = self::client($cron, capture: $capture);
        $cw->check();
        $cw->check();
        $this->assertCount(20, $cw->runs('nightly', 500), 'only the newest twenty are copied');
        $this->assertSame([], $capture->types(), 'no alert from history');
    }

    public function testAJobPausedOrRenamedWhileMissedClosesMissedWithARecovery(): void
    {
        $clock = new Clock();
        $cron = new FakeCron();
        $cron->job(1, 'hourly', '0 * * * *');
        $cron->job(2, 'rollup', '0 * * * *');
        $cron->add(1, 'succeeded', self::T0 - 3 * self::HOUR, self::T0 - 3 * self::HOUR + 1000);
        $cron->add(2, 'succeeded', self::T0 - 3 * self::HOUR, self::T0 - 3 * self::HOUR + 1000);
        $capture = new Capture();
        $cw = self::client($cron, $clock, capture: $capture);
        $cw->check();
        $seen = array_map(fn ($a) => "{$a->type} {$a->job}", $capture->alerts);
        sort($seen);
        $this->assertSame(['missed hourly', 'missed rollup'], $seen);
        $cron->jobs[0]['active'] = false;
        $cron->jobs[1]['jobname'] = 'rollup-v2';
        $clock->advance(self::MIN);
        $seen = array_map(fn ($a) => "{$a->type} {$a->job} {$a->title}", $cw->check()->alerts);
        sort($seen);
        $this->assertSame(['recovered hourly hourly is no longer scheduled', 'recovered rollup rollup is no longer scheduled'], $seen);
        $clock->advance(self::MIN);
        $this->assertSame([], $cw->check()->alerts);
    }

    public function testARenamedJobLeavesNoScheduledGhostInThisProcessOrTheNext(): void
    {
        $clock = new Clock();
        $cron = new FakeCron();
        $cron->job(1, 'rollup', '*/5 * * * *');
        $cron->add(1, 'succeeded', self::T0 - 60_000, self::T0 - 59_000, '1 row');
        $store = new MemoryStore();
        $capture = new Capture();
        $errors = [];
        $cw = self::client($cron, $clock, $store, $errors, $capture);
        $cw->check();
        $cron->jobs[0]['jobname'] = 'rollup-v2';
        $running = $cron->add(1, 'running', self::T0 - 1000, null);
        $cw->check();
        $summary = $cw->jobs();
        $old = self::named($summary, 'rollup');
        $this->assertNull($old->definition->schedule, 'the old name has no schedule');
        $this->assertStringContainsString('renamed to rollup-v2', $old->definition->description);
        $this->assertSame('*/5 * * * *', self::named($summary, 'rollup-v2')->definition->schedule);
        $this->assertSame('rollup-v2', $cw->getRun("pgcron:{$running->runid}")->job);
        $running->status = 'succeeded';
        $running->end = self::T0;
        $clock->advance(self::HOUR);
        $cron->add(1, 'succeeded', $clock->now - 2000, $clock->now - 1000, '1 row');
        $cw->check();
        $this->assertSame('ok', $cw->getRun("pgcron:{$running->runid}")->status);
        $this->assertSame([], array_filter($capture->alerts, fn ($a) => $a->job === 'rollup'), 'the old name is never missed');

        // Renamed again while no process watched: the next process retires the name the store still schedules.
        $cron->jobs[0]['jobname'] = 'rollup-v3';
        $cw = self::client($cron, $clock, $store, $errors, $capture);
        $clock->advance(self::MIN);
        $cw->check();
        $summary = $cw->jobs();
        $v2 = self::named($summary, 'rollup-v2');
        $this->assertNull($v2->definition->schedule);
        $this->assertStringContainsString('renamed to rollup-v3', $v2->definition->description);
        $this->assertSame('*/5 * * * *', self::named($summary, 'rollup-v3')->definition->schedule);
        $this->assertSame([], $cw->runs('rollup-v3'), 'runs already copied under an old name are not copied again');
        $clock->advance(self::HOUR);
        $cw->check();
        $this->assertSame([], array_values(array_map(fn ($a) => "{$a->type} {$a->job}", array_filter($capture->alerts, fn ($a) => $a->job !== 'rollup-v3'))), "only the job's current name can be missed");
        $this->assertSame([], self::unexpected($errors));
    }

    public function testARunMarkedTimeoutByACheckIsStillReadAndItsLateFinishRecorded(): void
    {
        $clock = new Clock();
        $cron = new FakeCron();
        $cron->job(1, 'vacuum', '0 3 * * *');
        $capture = new Capture();
        $cw = self::client($cron, $clock, capture: $capture, options: ['options' => ['timeout' => '30m']]);
        $long = $cron->add(1, 'running', self::T0, null);
        $cw->check();
        $this->assertSame('running', $cw->getRun("pgcron:{$long->runid}")->status);
        $clock->advance(45 * self::MIN);
        $cw->check();
        $this->assertSame('timeout', $cw->getRun("pgcron:{$long->runid}")->status);
        $this->assertSame(['stuck'], $capture->types());
        $clock->advance(10 * self::MIN);
        $long->status = 'succeeded';
        $long->end = $clock->now - 60_000;
        $long->message = 'VACUUM';
        $cw->check();
        $done = $cw->getRun("pgcron:{$long->runid}");
        $this->assertSame(['ok', 'VACUUM'], [$done->status, $done->output]);
        $this->assertSame(['stuck', 'recovered'], $capture->types());
        $this->assertSame('healthy', $cw->jobSummary('vacuum')->health);
    }

    public function testSettingsARoleMayNotReadAreAssumedAndReportedOnce(): void
    {
        $cron = new FakeCron();
        unset($cron->settings['cron.timezone'], $cron->settings['cron.log_run']);
        $cron->job(1, 'nightly', '0 3 * * *');
        $errors = [];
        $cw = self::client($cron, null, null, $errors);
        $first = $cw->check();
        $cw->check();
        $this->assertSame('UTC', $first->jobs[0]->definition->timezone);
        $this->assertCount(1, array_filter($errors, fn ($e) => str_contains($e, 'cron.timezone')));
        $this->assertSame([], array_filter($errors, fn ($e) => str_contains($e, 'log_run')), 'log_run unreadable is taken as on');
    }

    public function testCronLogRunOffWatchesJobsWithoutSchedules(): void
    {
        $cron = new FakeCron();
        $cron->settings['cron.log_run'] = 'off';
        $cron->job(1, 'nightly', '0 3 * * *');
        $cron->add(1, 'failed', self::T0 - 1000, self::T0, 'ERROR');
        $errors = [];
        $cw = self::client($cron, null, null, $errors);
        $result = $cw->check();
        $this->assertNull($result->jobs[0]->definition->schedule);
        $this->assertSame([], $cw->runs('nightly'), 'nothing is read');
        $this->assertStringContainsString('cron.log_run is off', implode("\n", $errors));
    }

    // ------------------------------------------------------------ a real pg_cron

    private static function url(): string
    {
        $url = getenv('CRONWATCH_TEST_PGCRON');
        if ($url === false || $url === '') {
            self::markTestSkipped('set CRONWATCH_TEST_PGCRON to the postgres:// URL of a Postgres with pg_cron to run');
        }
        if (!extension_loaded('pdo_pgsql')) {
            self::markTestSkipped('needs pdo_pgsql');
        }
        return $url;
    }

    private static function connect(string $url): \PDO
    {
        [$dsn, $user, $password] = PostgresStore::connection($url);
        return new \PDO($dsn, $user, $password, [\PDO::ATTR_ERRMODE => \PDO::ERRMODE_EXCEPTION]);
    }

    private static function one(\PDO $pdo, string $sql, array $params = []): mixed
    {
        $statement = $pdo->prepare($sql);
        $statement->execute($params);
        return $statement->fetchColumn();
    }

    public function testAgainstARealPgCron(): void
    {
        $url = self::url();
        $admin = self::connect($url);
        $tag = 'cwphp' . getmypid();
        $names = ['ok' => "{$tag}-ok", 'fail' => "{$tag}-fail", 'sleep' => "{$tag}-sleep"];
        $offset = 0;
        $store = new MemoryStore();
        $capture = new Capture();
        $conn = self::connect($url);
        $make = fn () => new Cronwatch(
            store: $store,
            alerts: [$capture],
            now: function () use (&$offset) {
                return Js::nowMs() + $offset;
            },
            cronSecret: false,
            sources: [new PgCron($conn, jobs: fn (array $j) => str_starts_with((string) $j['jobname'], $tag), options: ['grace' => '30s'])],
        );
        try {
            $admin->exec('CREATE EXTENSION IF NOT EXISTS pg_cron');
            self::one($admin, "SELECT cron.schedule(?, '1 seconds', 'SELECT 1')", [$names['ok']]);
            self::one($admin, "SELECT cron.schedule(?, '1 seconds', 'SELECT 1/0')", [$names['fail']]);
            self::one($admin, "SELECT cron.schedule(?, '1 seconds', 'SELECT pg_sleep(3)')", [$names['sleep']]);
            usleep(3_500_000);

            $cw = $make();
            $first = $cw->check();
            $ok = self::named($first->jobs, $names['ok']);
            $this->assertSame('every 1s', $ok->definition->schedule);
            $this->assertSame('UTC', $ok->definition->timezone);
            $okRuns = $cw->runs($names['ok']);
            $this->assertGreaterThanOrEqual(2, count($okRuns), 'ok runs imported');
            foreach ($okRuns as $run) {
                $this->assertStringStartsWith('pgcron:', $run->id);
                $this->assertSame('pg_cron', $run->trigger);
            }
            $this->assertNotEmpty(array_filter($okRuns, fn ($r) => $r->status === 'ok' && $r->output === '1 row'));
            $this->assertNotEmpty(array_filter($cw->runs($names['fail']), fn ($r) => $r->status === 'failed' && str_contains((string) $r->error, 'division by zero')), 'failure and its message imported');
            $this->assertSame(["failed {$names['fail']}"], array_map(fn ($a) => "{$a->type} {$a->job}", $first->alerts));
            $this->assertSame('healthy', $ok->health);

            // A run imported while it was going is updated when it finishes.
            $running = null;
            for ($i = 0; $i < 40 && !$running; $i++) {
                $running = self::one($admin, "SELECT d.runid FROM cron.job_run_details d JOIN cron.job j USING (jobid) WHERE j.jobname = ? AND d.status = 'running' AND d.start_time IS NOT NULL", [$names['sleep']]);
                if (!$running) {
                    usleep(250_000);
                }
            }
            $this->assertNotFalse($running, 'saw the sleeping job running');
            $cw->check();
            $this->assertSame('running', $cw->getRun("pgcron:{$running}")->status);
            usleep(3_500_000);
            $cw->check();
            $slept = $cw->getRun("pgcron:{$running}");
            $this->assertSame('ok', $slept->status);
            $this->assertGreaterThanOrEqual(2900, $slept->durationMs);

            // New runs keep arriving; nothing is copied twice.
            $before = count($cw->runs($names['ok'], 500));
            usleep(2_000_000);
            $cw->check();
            $after = $cw->runs($names['ok'], 500);
            $this->assertGreaterThan($before, count($after), 'later runs imported');
            $this->assertCount(count($after), array_unique(array_map(fn ($r) => $r->id, $after)));

            // The ok job is unscheduled: it is gone, not late, so it is never missed.
            self::one($admin, 'SELECT cron.unschedule(?)', [$names['ok']]);
            self::one($admin, 'SELECT cron.alter_job(jobid, active := false) FROM cron.job WHERE jobname = ?', [$names['fail']]);
            usleep(1_500_000);
            $cw = $make();
            $cw->check();
            $settled = count($cw->runs($names['fail'], 500));
            $cw->check();
            $this->assertCount($settled, $cw->runs($names['fail'], 500), 're-import adds nothing');
            $offset = 2 * self::MIN;
            $late = $cw->check();
            $this->assertSame([], array_filter($late->alerts, fn ($a) => $a->type === 'missed'), 'neither the unscheduled nor the paused job is missed');
            $okJob = self::named($late->jobs, $names['ok']);
            $this->assertNull($okJob->definition->schedule);
            $this->assertStringContainsString('no longer in cron.job', $okJob->definition->description);
        } finally {
            try {
                self::one($admin, 'SELECT count(cron.unschedule(jobid)) FROM cron.job WHERE jobname LIKE ?', ["{$tag}%"]);
            } catch (\Throwable) {
            }
        }
    }

    private const DETAIL_COLUMNS = 'jobid, runid, database, username, command, status, return_message, start_time, end_time';

    public function testAgainstARealPgCronRestartRowsACrowdedJobFirstSightAndARename(): void
    {
        $url = self::url();
        $conn = self::connect($url);
        $tag = 'cwphprow' . getmypid();
        $names = ['busy' => "{$tag}-busy", 'quiet' => "{$tag}-quiet", 'hist' => "{$tag}-hist"];
        $insert = fn (int $jobid, string $status, string $times, string $message) => self::one(
            $conn,
            'INSERT INTO cron.job_run_details (' . self::DETAIL_COLUMNS . ") SELECT ?, nextval('cron.runid_seq'), 'postgres', 'postgres', 'select 1', ?, ?, {$times} RETURNING runid",
            [$jobid, $status, $message],
        );
        $many = fn (int $jobid, string $status, string $message, string $times, int $count) => self::one(
            $conn,
            'INSERT INTO cron.job_run_details (' . self::DETAIL_COLUMNS . ") SELECT ?, nextval('cron.runid_seq'), 'postgres', 'postgres', 'select 1', ?, ?, {$times} FROM generate_series(1, {$count}) g RETURNING runid",
            [$jobid, $status, $message],
        );
        try {
            $conn->exec('CREATE EXTENSION IF NOT EXISTS pg_cron');
            $ids = [];
            foreach ($names as $name) {
                $ids[$name] = (int) self::one($conn, "SELECT cron.schedule(?, '0 3 * * *', 'SELECT 1')", [$name]);
                // Paused, so pg_cron itself adds no rows while the test writes its own.
                self::one($conn, 'SELECT cron.alter_job(?, active := false)', [$ids[$name]]);
            }
            // First sight of a job whose newest rows include a run cut off by a restart, and older failures.
            $many($ids[$names['hist']], 'failed', 'ERROR: old', "now() - interval '3 days', now() - interval '3 days'", 5);
            $insert($ids[$names['hist']], 'failed', 'NULL, NULL', 'server restarted');
            $many($ids[$names['hist']], 'succeeded', '1 row', 'now() - make_interval(mins => 30 - g), now() - make_interval(mins => 30 - g)', 19);

            $capture = new Capture();
            $errors = [];
            $cw = new Cronwatch(store: new MemoryStore(), alerts: [$capture], cronSecret: false, onError: function (\Throwable $e) use (&$errors): void {
                $errors[] = $e->getMessage();
            }, sources: [new PgCron($conn, jobs: fn (array $j) => str_starts_with((string) $j['jobname'], $tag), timezone: 'UTC')]);
            $cw->check();
            $this->assertCount(20, $cw->runs($names['hist'], 500), 'twenty newest copied');
            $this->assertSame([], $capture->alerts, 'history is never judged');
            $cw->check();
            $this->assertCount(20, $cw->runs($names['hist'], 500), 'and never read again');

            // A restart cuts off a busy job's queued run; the busy job then runs past a page; then the quiet job fails.
            $cut = $insert($ids[$names['busy']], 'failed', 'NULL, NULL', 'server restarted');
            $many($ids[$names['busy']], 'succeeded', '1 row', 'now() - make_interval(secs => 600 - g), now() - make_interval(secs => 600 - g)', 520);
            $disk = $insert($ids[$names['quiet']], 'failed', 'now(), now()', 'ERROR: disk full');
            for ($i = 0; $i < 3; $i++) {
                $cw->check();
            }
            $this->assertSame('server restarted', $cw->getRun("pgcron:{$cut}")->error);
            $this->assertSame('failed', $cw->getRun("pgcron:{$disk}")->status, "the quiet job's failure is read");
            $this->assertNotEmpty(array_filter($capture->alerts, fn ($a) => $a->type === 'failed' && $a->job === $names['quiet']));

            // Renamed in pg_cron: the old name keeps its runs and loses its schedule.
            self::one($conn, 'UPDATE cron.job SET jobname = ? WHERE jobid = ? RETURNING jobid', ["{$names['quiet']}-v2", $ids[$names['quiet']]]);
            self::one($conn, 'SELECT cron.alter_job(?, active := true)', [$ids[$names['quiet']]]);
            $cw->check();
            $jobs = $cw->jobs();
            $old = self::named($jobs, $names['quiet']);
            $this->assertNull($old->definition->schedule);
            $this->assertStringContainsString('renamed to', $old->definition->description);
            $this->assertSame('0 3 * * *', self::named($jobs, "{$names['quiet']}-v2")->definition->schedule);
            $this->assertSame([], self::unexpected($errors));
        } finally {
            try {
                self::one($conn, 'SELECT count(cron.unschedule(jobid)) FROM cron.job WHERE jobname LIKE ?', ["{$tag}%"]);
            } catch (\Throwable) {
            }
        }
    }

    public function testAgainstARealPgCronARoleThatMayNotReadCronSettingsNeverAbortsTheCallersTransaction(): void
    {
        $url = self::url();
        $admin = self::connect($url);
        $role = 'cwphprole' . getmypid();
        try {
            $admin->exec('CREATE EXTENSION IF NOT EXISTS pg_cron');
            $admin->exec("CREATE ROLE {$role} LOGIN PASSWORD 'pw'");
            $admin->exec("GRANT USAGE ON SCHEMA cron TO {$role}");
            $admin->exec("GRANT SELECT ON cron.job, cron.job_run_details TO {$role}");
            [$dsn] = PostgresStore::connection($url);
            $user = new \PDO($dsn, $role, 'pw', [\PDO::ATTR_ERRMODE => \PDO::ERRMODE_EXCEPTION]);
            self::one($user, "SELECT cron.schedule(?, '0 3 * * *', 'SELECT 1')", ["{$role}-job"]);
            $errors = [];
            $cw = new Cronwatch(store: new MemoryStore(), alerts: [], cronSecret: false, onError: function (\Throwable $e) use (&$errors): void {
                $errors[] = $e->getMessage();
            }, sources: [new PgCron($user)]);
            $user->beginTransaction();
            $user->query('SELECT 1');
            $result = $cw->check();
            $this->assertSame(1, (int) $user->query('SELECT 1 AS one')->fetchColumn(), 'the transaction is still usable');
            $user->rollBack();
            $job = self::named($result->jobs, "{$role}-job");
            $this->assertSame('UTC', $job->definition->timezone, 'assumed');
            $this->assertSame('0 3 * * *', $job->definition->schedule, 'cron.log_run unreadable is taken as on');
            $this->assertStringContainsString('could not read cron.timezone', implode("\n", $errors));
            $user = null;
        } finally {
            // Every job of the role goes before the role: pg_cron's scheduler stops on a job whose role is gone.
            foreach (["SELECT count(cron.unschedule(jobid)) FROM cron.job WHERE username = '{$role}'", "DROP OWNED BY {$role}", "DROP ROLE IF EXISTS {$role}"] as $sql) {
                try {
                    $admin->query($sql);
                } catch (\Throwable) {
                }
            }
        }
    }

    public function testAgainstARealPgCronThroughAUrlAndAPostgresStore(): void
    {
        $url = self::url();
        $admin = self::connect($url);
        $tag = 'cwphpurl' . getmypid();
        $prefix = 'tpgc' . getmypid() . '_';
        $store = new PostgresStore($url, prefix: $prefix);
        try {
            $jobid = (int) self::one($admin, "SELECT cron.schedule(?, '0 3 * * *', 'SELECT 1')", [$tag]);
            self::one($admin, 'SELECT cron.alter_job(?, active := false)', [$jobid]);
            self::one($admin, 'INSERT INTO cron.job_run_details (' . self::DETAIL_COLUMNS . ") SELECT ?, nextval('cron.runid_seq'), 'postgres', 'postgres', 'select 1', 'succeeded', '1 row', now() - interval '1 minute', now() - interval '59 seconds' RETURNING runid", [$jobid]);
            $cw = new Cronwatch(store: $store, alerts: [], cronSecret: false, sources: [new PgCron($url, jobs: [$tag], timezone: 'UTC')]);
            $cw->check();
            $runs = $cw->runs($tag);
            $this->assertCount(1, $runs);
            $this->assertSame(['ok', '1 row', 'pg_cron', 1000], [$runs[0]->status, $runs[0]->output, $runs[0]->trigger, $runs[0]->durationMs]);
        } finally {
            try {
                self::one($admin, 'SELECT cron.unschedule(?)', [$tag]);
            } catch (\Throwable) {
            }
            $store->close();
            $admin->exec("DROP TABLE IF EXISTS {$prefix}jobs, {$prefix}runs, {$prefix}state");
        }
    }
}

/** One row of cron.job_run_details in memory. */
final class FakeDetail
{
    public function __construct(
        public int $runid,
        public int $jobid,
        public string $status,
        public ?string $message,
        public int|float|null $start,
        public int|float|null $end,
    ) {
    }
}

/** cron.job and cron.job_run_details in memory, answering the source's queries as Postgres would, timestamps as pdo_pgsql's text. */
final class FakeCron
{
    /** @var list<array<string, mixed>> */
    public array $jobs = [];
    /** @var list<FakeDetail> */
    public array $details = [];
    public int $runid = 0;
    /** @var array<string, string> */
    public array $settings = ['cron.timezone' => 'GMT', 'cron.log_run' => 'on'];
    public bool $settingsDenied = false;

    public function job(int $jobid, ?string $jobname, string $schedule, bool $active = true): void
    {
        $this->jobs[] = ['jobid' => $jobid, 'jobname' => $jobname, 'schedule' => $schedule, 'database' => 'postgres', 'username' => 'postgres', 'active' => $active];
    }

    public function add(int $jobid, string $status, int|float|null $start, int|float|null $end, ?string $message = null): FakeDetail
    {
        return $this->details[] = new FakeDetail(++$this->runid, $jobid, $status, $message, $start, $end);
    }

    /** @return list<array<string, mixed>> */
    public function query(string $sql, array $params): array
    {
        if (str_contains($sql, 'pg_settings')) {
            if ($this->settingsDenied) {
                throw new \RuntimeException('permission denied');
            }
            $value = $this->settings[$params[0]] ?? null;
            return $value === null ? [] : [['setting' => $value]];
        }
        if (str_contains($sql, 'FROM cron.job ORDER BY')) {
            return array_map(fn (array $j) => ['jobid' => (string) $j['jobid']] + $j, $this->jobs);
        }
        if (str_contains($sql, 'ORDER BY d.runid DESC')) {
            $rows = array_values(array_filter($this->details, fn (FakeDetail $d) => $d->jobid === $params[0]));
            usort($rows, fn ($a, $b) => $b->runid <=> $a->runid);
            return self::out(array_slice($rows, 0, 20));
        }
        if (str_contains($sql, 'unnest')) {
            [$ids, $afters, $open] = $params;
            $after = array_combine($ids, $afters);
            $opened = array_flip(array_map('intval', $open));
            $rows = array_values(array_filter($this->details, fn (FakeDetail $d) => (isset($after[$d->jobid]) && $d->runid > $after[$d->jobid]) || isset($opened[$d->runid])));
            usort($rows, fn ($a, $b) => $a->runid <=> $b->runid);
            return self::out(array_slice($rows, 0, 500));
        }
        throw new \LogicException("unexpected query {$sql}");
    }

    private static function text(int|float|null $at): ?string
    {
        if ($at === null) {
            return null;
        }
        $iso = Js::iso($at);
        return substr($iso, 0, 10) . ' ' . substr($iso, 11, 12) . '+00';
    }

    /** @param list<FakeDetail> $rows */
    private static function out(array $rows): array
    {
        return array_map(fn (FakeDetail $d) => [
            'runid' => (string) $d->runid, 'jobid' => (string) $d->jobid, 'status' => $d->status,
            'return_message' => $d->message, 'start_time' => self::text($d->start), 'end_time' => self::text($d->end),
        ], $rows);
    }
}
