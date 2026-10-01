<?php

declare(strict_types=1);

namespace Cronwatch\Tests;

use Cronwatch\Alert;
use Cronwatch\Alerts\Custom;
use Cronwatch\Cronwatch;
use Cronwatch\Evaluate;
use Cronwatch\JobDefinition;
use Cronwatch\RunStatus;
use Cronwatch\Tests\Support\Backend;
use Cronwatch\Web\Request;
use PHPUnit\Framework\Attributes\DataProvider;
use PHPUnit\Framework\TestCase;

/**
 * Rows another process wrote: a running run that started at the lowest
 * BIGINT, and a state whose version is 1.5. Neither may make a statement
 * fail, or refuse every write of the job for good (checkOverForeignRows in
 * the SDK's stores.test.ts).
 */
final class ForeignRowsTest extends TestCase
{
    public static function stores(): iterable
    {
        foreach (['sqlite', 'mysql', 'mariadb', 'postgres'] as $kind) {
            yield $kind => [$kind];
        }
    }

    public function testRunDurationAtPhpsIntegerLimits(): void
    {
        $this->assertSame(Evaluate::MAX_DURATION_MS, Evaluate::runDuration(PHP_INT_MIN, 1767605400000));
        $this->assertSame(Evaluate::MAX_DURATION_MS, Evaluate::runDuration(PHP_INT_MIN, PHP_INT_MAX));
        $this->assertSame(0, Evaluate::runDuration(PHP_INT_MAX, 1767605400000));
        $this->assertSame(0, Evaluate::runDuration(PHP_INT_MAX, PHP_INT_MIN));
        $this->assertSame(0, Evaluate::runDuration(NAN, 1767605400000));
        $this->assertSame(1500, Evaluate::runDuration(1767605398500, 1767605400000));
    }

    /**
     * The stuck alert is sent: its text writes a start before the year 1 as
     * words, not as a date.
     */
    #[DataProvider('stores')]
    public function testACheckOverARunThatStartedAtTheLowestBigintAndAStateWhoseVersionIsOnePointFive(string $kind): void
    {
        $why = Backend::unavailable($kind);
        if ($why !== null) {
            $this->markTestSkipped($why);
        }
        $backend = Backend::make($kind);
        try {
            $store = $backend->open();
            $store->init();
            $store->upsertJob(JobDefinition::fromJson(['name' => 'far', 'timeout' => '5m']), 1);
            $p = $backend->tables();
            $trigger = $kind === 'mysql' || $kind === 'mariadb' ? '`trigger`' : 'trigger';
            $pdo = $backend->pdo();
            $pdo->exec("INSERT INTO {$p}runs (id, job, status, started_at, metrics, {$trigger}) VALUES ('far1', 'far', 'running', -9223372036854775808, '{}', 'run')");
            $pdo->exec("INSERT INTO {$p}state (job, state) VALUES ('far', '{\"job\":\"far\",\"open\":{},\"consecutiveFailures\":0,\"silencedUntil\":null,\"lastAlertAt\":null,\"version\":1.5}')");
            $sent = [];
            $capture = new Custom('capture', function (Alert $alert) use (&$sent): void {
                $sent[] = $alert;
            });
            $cw = new Cronwatch(store: $store, alerts: [$capture], cronSecret: null, onError: function (\Throwable $e): void {
                throw $e;
            });
            $cw->check();
            $cw->check();
            $run = $store->getRun('far1');
            $this->assertSame(RunStatus::TIMEOUT, $run?->status);
            $this->assertSame(9007199254740991, $run->durationMs, 'the duration is held at 2^53 - 1');
            $state = $store->getState('far');
            $this->assertSame(2, $state?->version, "the state's 1.5 counted as 0, then the timeout and the alert each wrote it");
            $this->assertSame(1, $state->consecutiveFailures);
            $this->assertSame(['stuck'], array_map(fn (Alert $a) => $a->type, $sent));
            $this->assertSame('Started before 0001-01-01 00:00:00 UTC and never reported finishing. Marked as timed out after 104249991d 8h.', explode("\n", $sent[0]->message)[0]);
        } finally {
            $backend->done();
        }
    }

    /**
     * A state whose times, conditions and queued alerts hold values of the
     * wrong kind: each reads as absent, so the job is still checked, its
     * failures still alert, and silence and unsilence still work.
     */
    #[DataProvider('stores')]
    public function testAStateWithOddValuesIsStillEvaluatedAndCanBeSilenced(string $kind): void
    {
        $why = Backend::unavailable($kind);
        if ($why !== null) {
            $this->markTestSkipped($why);
        }
        $backend = Backend::make($kind);
        try {
            $store = $backend->open();
            $store->init();
            $store->upsertJob(JobDefinition::fromJson(['name' => 'odd']), 1);
            $p = $backend->tables();
            $alert = '{"type":"failed","job":"odd","definition":{"name":"odd"},"run":"r","title":7,"message":null,"at":"x","triage":5,"details":{}}';
            $state = '{"job":"odd","open":{},"consecutiveFailures":0,"silencedUntil":"soon","lastAlertAt":"x","pendingRecovery":[1,"failed",null],"undelivered":["x",' . $alert . ']}';
            $backend->pdo()->exec("INSERT INTO {$p}state (job, state) VALUES ('odd', '{$state}')");
            $sent = [];
            $capture = new Custom('capture', function (Alert $alert) use (&$sent): void {
                $sent[] = $alert->type;
            });
            $cw = new Cronwatch(store: $store, alerts: [$capture], cronSecret: null, onError: function (\Throwable $e): void {
                throw $e;
            });
            $read = $store->getState('odd');
            $this->assertNull($read->silencedUntil);
            $this->assertNull($read->lastAlertAt);
            $this->assertSame(['failed'], $read->pendingRecovery);
            $this->assertCount(1, $read->undelivered);
            $this->assertSame([0, null, true], [$read->undelivered[0]->at, $read->undelivered[0]->triage, $read->undelivered[0]->triageTried]);
            $cw->check();
            $this->assertSame('never_ran', $cw->jobSummary('odd')->health);
            $this->assertNotNull($cw->silence('odd', '1h')->silencedUntil);
            $this->assertNull($cw->unsilence('odd')->silencedUntil);
            try {
                $cw->run('odd', function (): never {
                    throw new \RuntimeException('boom');
                });
            } catch (\RuntimeException) {
            }
            $this->assertContains('failed', $sent);
        } finally {
            $backend->done();
        }
    }

    /** @return iterable<string, array{string, string}> */
    public static function farCronStarts(): iterable
    {
        foreach (['sqlite', 'mysql', 'mariadb', 'postgres'] as $kind) {
            foreach (['-62135596800001', '253402300800000', '-9223372036854775808', '9223372036854775807'] as $start) {
                yield "{$kind} {$start}" => [$kind, $start];
            }
        }
    }

    /**
     * A cron job's last run as a foreign or damaged row could hold it:
     * before the year 1 (the first fire of the year 1 was missed) or after
     * 9999 (never due again), and at BIGINT's ends. Neither a check nor the
     * dashboard reports an error (cronOverForeignRow in the SDK's
     * stores.test.ts).
     */
    #[DataProvider('farCronStarts')]
    public function testACheckAndTheDashboardOverACronJobWhoseLastRunStartedFarOff(string $kind, string $start): void
    {
        $why = Backend::unavailable($kind);
        if ($why !== null) {
            $this->markTestSkipped($why);
        }
        $backend = Backend::make($kind);
        try {
            $store = $backend->open();
            $store->init();
            $store->upsertJob(JobDefinition::fromJson(['name' => 'far', 'schedule' => '0 2 * * *', 'timezone' => 'UTC', 'grace' => '10m']), 1);
            $p = $backend->tables();
            $trigger = $kind === 'mysql' || $kind === 'mariadb' ? '`trigger`' : 'trigger';
            $backend->pdo()->exec("INSERT INTO {$p}runs (id, job, status, started_at, finished_at, duration_ms, metrics, {$trigger}) VALUES ('far1', 'far', 'ok', {$start}, {$start}, 0, '{}', 'run')");
            $sent = [];
            $errors = [];
            $capture = new Custom('capture', function (Alert $alert) use (&$sent): void {
                $sent[] = $alert;
            });
            $cw = new Cronwatch(store: $store, alerts: [$capture], cronSecret: null, onError: function (\Throwable $e, string $context) use (&$errors): void {
                $errors[] = "{$context}: {$e->getMessage()}";
            });
            $cw->check();
            $web = $cw->routes(token: 'tok', basePath: '/cronwatch');
            foreach (['/cronwatch/', '/cronwatch/jobs/far', '/cronwatch/api/jobs/far'] as $path) {
                $response = $web->handle(Request::create('GET', "http://app.test{$path}", ['authorization' => 'Bearer tok'], ''));
                $this->assertSame(200, $response->status, $path);
            }
            $this->assertSame([], $errors);
            $this->assertSame(str_starts_with($start, '-') ? ['missed'] : [], array_map(fn (Alert $a) => $a->type, $sent));
            if ($sent !== []) {
                $this->assertStringStartsWith('Due 0001-01-01 02:00:00 UTC ', $sent[0]->message);
            }
        } finally {
            $backend->done();
        }
    }
}
