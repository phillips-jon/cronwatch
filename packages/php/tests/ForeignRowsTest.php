<?php

declare(strict_types=1);

namespace Cronwatch\Tests;

use Cronwatch\Cronwatch;
use Cronwatch\Evaluate;
use Cronwatch\JobDefinition;
use Cronwatch\RunStatus;
use Cronwatch\Tests\Support\Backend;
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
     * The job is silenced: an alert's text shows the start as a date, and no
     * date is that far back.
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
            $pdo->exec("INSERT INTO {$p}state (job, state) VALUES ('far', '{\"job\":\"far\",\"open\":{},\"consecutiveFailures\":0,\"silencedUntil\":4102444800000,\"lastAlertAt\":null,\"version\":1.5}')");
            $cw = new Cronwatch(store: $store, alerts: [], cronSecret: false, onError: function (\Throwable $e): void {
                throw $e;
            });
            $cw->check();
            $cw->check();
            $run = $store->getRun('far1');
            $this->assertSame(RunStatus::TIMEOUT, $run?->status);
            $this->assertSame(9007199254740991, $run->durationMs, 'the duration is held at 2^53 - 1');
            $state = $store->getState('far');
            $this->assertSame(1, $state?->version, "the state's 1.5 counted as 0 and was written over");
            $this->assertSame(1, $state->consecutiveFailures);
        } finally {
            $backend->done();
        }
    }
}
