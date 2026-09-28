<?php

declare(strict_types=1);

namespace Cronwatch\Tests;

use Cronwatch\Cronwatch;
use Cronwatch\Run;
use Cronwatch\Tests\Support\Backend;
use Cronwatch\Tests\Support\Clock;
use PHPUnit\Framework\Attributes\DataProvider;
use PHPUnit\Framework\TestCase;

/**
 * finish-once.test.ts and concurrency.test.ts with real processes: PHP
 * workers (tests/workers/worker.php) sharing one SQLite file or one MySQL or
 * MariaDB database, each told to act at the same moment. A run is judged
 * once however many processes finish it, and a job's state loses no update
 * however many write it at once.
 */
final class FinishOnceTest extends TestCase
{
    private const WORKER = __DIR__ . '/workers/worker.php';

    public static function backends(): iterable
    {
        foreach (['sqlite', 'mysql', 'mariadb'] as $kind) {
            yield $kind => [$kind];
        }
    }

    private function backend(string $kind): Backend
    {
        if (!function_exists('proc_open')) {
            $this->markTestSkipped('needs proc_open');
        }
        $why = Backend::unavailable($kind);
        if ($why !== null) {
            $this->markTestSkipped($why);
        }
        $backend = Backend::make($kind);
        // The tables exist before the processes start, as a deploy would leave them.
        $backend->open()->init();
        return $backend;
    }

    /**
     * Starts one worker per config, waits until each is ready, lets them all
     * go at once, and returns what each printed.
     *
     * @param list<array<string, mixed>> $configs
     * @return list<array{recorded: list<string>, alerts: list<string>, errors: list<string>}>
     */
    private function together(Backend $backend, array $configs): array
    {
        $dir = sys_get_temp_dir() . '/cronwatch-php-go-' . getmypid() . '-' . bin2hex(random_bytes(4));
        mkdir($dir);
        $go = "{$dir}/go";
        $workers = [];
        try {
            foreach ($configs as $i => $config) {
                $config += ['store' => $backend->spec(), 'ready' => "{$dir}/ready-{$i}", 'go' => $go, 'worker' => $i, 'now' => Clock::T0 + Clock::MIN];
                $process = proc_open([PHP_BINARY, self::WORKER, json_encode($config, JSON_THROW_ON_ERROR)], [1 => ['pipe', 'w'], 2 => ['pipe', 'w']], $pipes);
                $this->assertIsResource($process);
                $workers[] = [$process, $pipes];
            }
            $deadline = microtime(true) + 30;
            foreach (array_keys($configs) as $i) {
                while (!file_exists("{$dir}/ready-{$i}")) {
                    $this->assertLessThan($deadline, microtime(true), "worker {$i} never got ready");
                    usleep(1000);
                }
            }
            touch($go);
            $results = [];
            foreach ($workers as $i => [$process, $pipes]) {
                $out = stream_get_contents($pipes[1]);
                $err = stream_get_contents($pipes[2]);
                fclose($pipes[1]);
                fclose($pipes[2]);
                $status = proc_close($process);
                $this->assertSame(0, $status, "worker {$i} failed: {$err}{$out}");
                $results[] = json_decode((string) $out, true, 512, JSON_THROW_ON_ERROR);
            }
            return $results;
        } finally {
            foreach (glob("{$dir}/*") ?: [] as $file) {
                unlink($file);
            }
            rmdir($dir);
        }
    }

    private static function all(array $results, string $key): array
    {
        return array_merge(...array_map(fn (array $r) => $r[$key], $results));
    }

    private static function client(Backend $backend): Cronwatch
    {
        return new Cronwatch(store: $backend->open(), now: fn () => Clock::T0, alerts: [], cronSecret: false);
    }

    #[DataProvider('backends')]
    public function testTwoProcessesFinishingOneRunOneRecordsAndJudgesItTheOtherReportsIt(string $kind): void
    {
        $backend = $this->backend($kind);
        try {
            $options = ['failuresBeforeAlert' => 2];
            $cw = self::client($backend);
            $cw->job('webhook-ingest', $options)->start(id: 'delivery-1');
            $results = $this->together($backend, array_fill(0, 2, ['action' => 'fail', 'job' => 'webhook-ingest', 'options' => $options, 'id' => 'delivery-1']));
            $this->assertSame(['delivery-1'], self::all($results, 'recorded'), 'one finish recorded');
            $this->assertStringContainsString('already finished as failed; ignored', implode("\n", self::all($results, 'errors')));
            $this->assertCount(1, $cw->runs('webhook-ingest'));
            $this->assertSame(1, $cw->store->getState('webhook-ingest')->consecutiveFailures, 'the failure counted once');
            $this->assertSame([], self::all($results, 'alerts'), 'one failure is below failuresBeforeAlert 2');
        } finally {
            $backend->done();
        }
    }

    #[DataProvider('backends')]
    public function testTwoProcessesRecordingOneFinishedRunFromASourceItIsJudgedOnce(string $kind): void
    {
        $backend = $this->backend($kind);
        try {
            $options = ['failuresBeforeAlert' => 2];
            $cw = self::client($backend);
            $cw->job('db:rollup', $options);
            $t = Clock::T0 - Clock::MIN;
            $cw->recordRun(new Run('pgcron:9', 'db:rollup', 'running', $t, trigger: 'pg_cron'));
            $done = new Run('pgcron:9', 'db:rollup', 'failed', $t, $t + 1000, 1000, 'ERROR: deadlock detected', null, [], 'pg_cron');
            $results = $this->together($backend, array_fill(0, 2, ['action' => 'record', 'job' => 'db:rollup', 'options' => $options, 'run' => $done->toJson()]));
            $this->assertSame(1, $cw->store->getState('db:rollup')->consecutiveFailures);
            $this->assertSame([], self::all($results, 'alerts'));
            // A process that reads the run after the other finished it leaves it
            // alone quietly; one whose read came first loses the claim and says so.
            foreach (self::all($results, 'errors') as $error) {
                $this->assertSame('recording db:rollup: run pgcron:9 of db:rollup was already finished as failed; ignored', $error);
            }
        } finally {
            $backend->done();
        }
    }

    #[DataProvider('backends')]
    public function testManyProcessesStartingAndFinishingOneIdExactlyOneFinishIsRecorded(string $kind): void
    {
        $backend = $this->backend($kind);
        try {
            $ids = array_map(fn (int $k) => "evt_{$k}", range(0, 4));
            $results = $this->together($backend, array_fill(0, 6, ['action' => 'startFinish', 'job' => 'ingest', 'ids' => $ids]));
            $recorded = self::all($results, 'recorded');
            sort($recorded);
            $this->assertSame($ids, $recorded, 'each id: one finish recorded');
            $runs = self::client($backend)->runs('ingest', 500);
            $this->assertCount(5, $runs);
            $this->assertSame(['ok'], array_values(array_unique(array_map(fn (Run $r) => $r->status, $runs))));
            $unexpected = array_values(array_filter(self::all($results, 'errors'), fn (string $e) => !str_contains($e, 'already finished')));
            $this->assertSame([], $unexpected);
        } finally {
            $backend->done();
        }
    }

    #[DataProvider('backends')]
    public function testProcessesFailingAJobAtOnceAllFailuresCountAndTheAlertGoesOutOnce(string $kind): void
    {
        $backend = $this->backend($kind);
        try {
            $options = ['failuresBeforeAlert' => 2];
            $cw = self::client($backend);
            $cw->run('shared', fn () => null, $options);
            $results = $this->together($backend, array_fill(0, 3, ['action' => 'runFails', 'job' => 'shared', 'options' => $options, 'slowReads' => true]));
            $state = $cw->store->getState('shared');
            $this->assertSame(3, $state->consecutiveFailures, 'no failure was lost');
            $this->assertSame(['failed'], array_keys($state->open), 'the condition opened');
            $this->assertSame(['failed'], self::all($results, 'alerts'), 'one alert, from whichever process counted the second failure');
            $this->assertGreaterThanOrEqual(4, $state->version, 'every write bumped the version');
            $this->assertSame([], self::all($results, 'errors'));
        } finally {
            $backend->done();
        }
    }
}
