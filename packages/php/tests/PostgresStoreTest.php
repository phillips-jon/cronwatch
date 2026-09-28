<?php

declare(strict_types=1);

namespace Cronwatch\Tests;

use Cronwatch\Cronwatch;
use Cronwatch\Job\JobContext;
use Cronwatch\JobDefinition;
use Cronwatch\JobState;
use Cronwatch\Js;
use Cronwatch\Run;
use Cronwatch\Store\PostgresStore;
use Cronwatch\Store\Sql;
use Cronwatch\Tests\Support\Backend;
use Cronwatch\Tests\Support\Clock;
use PHPUnit\Framework\TestCase;

/**
 * The Postgres store's own tests (test/stores.test.ts's Postgres half), when
 * CRONWATCH_TEST_PG names a server: the SDK's schema read back from the
 * catalogue, the SDK's statements, its own connection beside the app's
 * transaction, several processes initialising at once, and connecting
 * again after the connection broke. The store contract, the conformance
 * scripts and the finish-once tests with real processes run against it in
 * StoreConformanceTest, ConformanceTest and FinishOnceTest.
 */
final class PostgresStoreTest extends TestCase
{
    public function testAUrlBecomesADsn(): void
    {
        $password = 'p' . '%40ss';
        $this->assertSame(
            ["pgsql:host='db.internal';port='5433';dbname='app';sslmode='require'", 'app user', 'p@ss'],
            PostgresStore::connection("postgres://app%20user:{$password}@db.internal:5433/app?sslmode=require"),
        );
        $this->assertSame(["pgsql:host='/var/run/postgresql';dbname='cw'", null, null], PostgresStore::connection('postgresql:///cw?host=/var/run/postgresql'));
        $this->assertSame(['pgsql:host=h;dbname=d', 'u', 'x'], PostgresStore::connection('pgsql:host=h;dbname=d', 'u', 'x'), 'a DSN passes through');
        $this->assertSame("pgsql:host='db';dbname='app';application_name='x sslmode=disable';options='-c search_path=it\\'s'", PostgresStore::connection('postgres://db/app?application_name=x%20sslmode%3Ddisable&options=-c%20search_path%3Dit%27s')[0], 'each value quoted, so a space starts no keyword');
        try {
            PostgresStore::connection('postgres://db/app%3Bsslmode%3Ddisable');
            $this->fail('a ; is refused');
        } catch (\InvalidArgumentException $error) {
            $this->assertStringContainsString('holding ";"', $error->getMessage());
        }
        $this->expectExceptionMessage('postgres:// or postgresql://');
        PostgresStore::connection('mysql://h/d');
    }

    public function testAPrefixThatIsNotAPlainLowercaseIdentifierIsRefused(): void
    {
        if (!extension_loaded('pdo_pgsql')) {
            $this->markTestSkipped('needs pdo_pgsql');
        }
        foreach (['1cw_', 'cw-', 'Cw_', 'cw_;drop', '', str_repeat('x', 48)] as $bad) {
            try {
                new PostgresStore('postgres://unused/db', prefix: $bad);
                $this->fail("{$bad} was taken");
            } catch (\InvalidArgumentException $error) {
                $this->assertStringContainsString('invalid table prefix', $error->getMessage());
            }
        }
    }

    public function testWithoutAUrlItReadsDatabaseUrl(): void
    {
        if (!extension_loaded('pdo_pgsql')) {
            $this->markTestSkipped('needs pdo_pgsql');
        }
        $saved = getenv('DATABASE_URL');
        try {
            putenv('DATABASE_URL=mysql://h/d');
            try {
                new PostgresStore();
                $this->fail('a MySQL DATABASE_URL is not taken');
            } catch (\InvalidArgumentException $error) {
                $this->assertStringContainsString('DATABASE_URL', $error->getMessage());
            }
            putenv('DATABASE_URL=postgres://u@127.0.0.1:1/none');
            $this->assertInstanceOf(PostgresStore::class, new PostgresStore(), 'nothing connects until first use');
        } finally {
            putenv($saved === false ? 'DATABASE_URL' : "DATABASE_URL={$saved}");
        }
    }

    public function testTheStatementsAreTheSdksTheServerNumbersThePlaceholders(): void
    {
        $sql = Sql::statements('postgres', 'cronwatch_');
        $this->assertSame("UPDATE cronwatch_state SET state = ? WHERE job = ? AND COALESCE((state->>'version')::bigint, 0) = ?", $sql['casUpdate']);
        $this->assertSame('SELECT * FROM cronwatch_runs WHERE job = ? ORDER BY started_at DESC, seq DESC LIMIT ?', $sql['listRuns']);
        $this->assertSame('SELECT * FROM cronwatch_jobs ORDER BY name COLLATE "C"', $sql['listJobs']);
        $this->assertStringEndsWith('WHERE id = ? AND status IN (?, ?)', Sql::updateRunIfSql('cronwatch_', 2));
    }

    private function backend(): Backend
    {
        $why = Backend::unavailable('postgres');
        if ($why !== null) {
            $this->markTestSkipped($why);
        }
        return Backend::make('postgres');
    }

    private static function admin(Backend $backend): \PDO
    {
        [$dsn, $user, $password] = PostgresStore::connection((string) $backend->url);
        return new \PDO($dsn, $user, $password, [\PDO::ATTR_ERRMODE => \PDO::ERRMODE_EXCEPTION]);
    }

    public function testTheSchemaIsTheSdks(): void
    {
        $backend = $this->backend();
        try {
            $store = $backend->open();
            $store->init();
            $store->init(); // IF NOT EXISTS: a second init changes nothing
            $p = $backend->prefix;
            $admin = self::admin($backend);
            $types = [];
            $defaults = [];
            $runColumns = [];
            $rows = $admin->query("SELECT table_name, column_name, data_type, column_default FROM information_schema.columns WHERE table_name LIKE '{$p}%' ORDER BY table_name, ordinal_position")->fetchAll(\PDO::FETCH_NUM);
            foreach ($rows as [$table, $column, $type, $default]) {
                $key = substr($table, strlen($p)) . ".{$column}";
                $types[$key] = $type;
                $defaults[$key] = $default;
                if ($table === "{$p}runs") {
                    $runColumns[] = $column;
                }
            }
            $this->assertSame(['seq', 'id', 'job', 'status', 'started_at', 'finished_at', 'duration_ms', 'error', 'output', 'metrics', 'trigger'], $runColumns);
            $this->assertSame('bigint', $types['runs.seq']);
            $this->assertSame('bigint', $types['runs.started_at']);
            $this->assertSame('jsonb', $types['runs.metrics']);
            $this->assertSame('jsonb', $types['jobs.definition']);
            $this->assertSame('jsonb', $types['state.state']);
            $this->assertStringStartsWith('nextval(', (string) $defaults['runs.seq']);
            $this->assertSame("'run'::text", $defaults['runs.trigger']);
            $indexes = $admin->query("SELECT indexname FROM pg_indexes WHERE indexname LIKE '{$p}%' ORDER BY indexname")->fetchAll(\PDO::FETCH_COLUMN);
            $this->assertSame(["{$p}jobs_pkey", "{$p}runs_job_started", "{$p}runs_pkey", "{$p}runs_running", "{$p}state_pkey"], $indexes);
            $partial = $admin->query("SELECT indexdef FROM pg_indexes WHERE indexname = '{$p}runs_running'")->fetchColumn();
            $this->assertStringEndsWith("WHERE (status = 'running'::text)", (string) $partial);

            // Numbers come back as numbers, and JSONB as the SDK reads it.
            $run = new Run('r1', 'nightly', 'ok', 1767605400000, 1767605401000, 1000, null, "tab\tand \"quotes\" \u{1F600}", ['ratio' => 0.30000000000000004, 'tiny' => 1e-7, 'huge' => 1e21], 'run');
            $store->insertRun($run);
            $read = $store->getRun('r1');
            $this->assertSame(1767605400000, $read->startedAt);
            $this->assertSame(1000, $read->durationMs);
            $this->assertSame("tab\tand \"quotes\" \u{1F600}", $read->output);
            // JSONB orders keys by length, then bytes: the SDK reads them in that order too.
            $this->assertSame(['huge' => 1e21, 'tiny' => 1e-7, 'ratio' => 0.30000000000000004], $read->metrics);
        } finally {
            $backend->done();
        }
    }

    public function testOutputAndErrorsWithNulCharactersAreStillRecorded(): void
    {
        $backend = $this->backend();
        try {
            $cw = new Cronwatch(store: $backend->open(), now: new Clock(), alerts: [], cronSecret: false, onError: function (\Throwable $error): never {
                throw $error;
            });
            try {
                $cw->run('nul', function (JobContext $job): never {
                    $job->log("before\0after");
                    throw new \RuntimeException("bad\0byte");
                });
                $this->fail('the job threw');
            } catch (\RuntimeException $error) {
                $this->assertSame("bad\0byte", $error->getMessage());
            }
            $run = $cw->runs('nul')[0];
            $this->assertSame('failed', $run->status);
            $this->assertSame('beforeafter', $run->output);
            $this->assertStringStartsWith('RuntimeException: badbyte', (string) $run->error);
            $this->assertSame(1, $cw->store->getState('nul')->consecutiveFailures, 'the state, with its alert, was written too');
        } finally {
            $backend->done();
        }
    }

    public function testARunRecordedInsideTheAppsTransactionSurvivesItsRollback(): void
    {
        $backend = $this->backend();
        try {
            $store = $backend->open();
            $cw = new Cronwatch(store: $store, now: new Clock(), alerts: [], cronSecret: false);
            $app = self::admin($backend);
            $app->exec("CREATE TABLE IF NOT EXISTS {$backend->prefix}orders (id INT PRIMARY KEY)");
            $app->beginTransaction();
            $app->exec("INSERT INTO {$backend->prefix}orders VALUES (1)");
            $cw->run('import', fn () => 'imported');
            $app->rollBack();
            $this->assertSame(0, (int) $app->query("SELECT COUNT(*) FROM {$backend->prefix}orders")->fetchColumn());
            $this->assertSame('imported', $cw->runs('import')[0]->output, 'the store wrote through a connection of its own');

            // Given the app's connection, the store shares its transaction.
            $shared = new PostgresStore(pdo: $app, prefix: $backend->prefix);
            $app->beginTransaction();
            $shared->insertRun(new Run('in-tx', 'import', 'running', 1));
            $app->rollBack();
            $this->assertNull($shared->getRun('in-tx'));
            $app->exec("DROP TABLE {$backend->prefix}orders");
        } finally {
            $backend->done();
        }
    }

    public function testManyProcessesCanInitAtOnce(): void
    {
        if (!function_exists('proc_open')) {
            $this->markTestSkipped('needs proc_open');
        }
        $backend = $this->backend();
        try {
            $script = 'require ' . var_export(__DIR__ . '/bootstrap.php', true) . ';'
                . '(new Cronwatch\Store\PostgresStore(' . var_export($backend->url, true) . ', prefix: ' . var_export($backend->prefix, true) . '))->init();';
            $processes = [];
            for ($i = 0; $i < 6; $i++) {
                $processes[] = proc_open([PHP_BINARY, '-r', $script], [1 => ['pipe', 'w'], 2 => ['pipe', 'w']], $pipes);
                $processes[$i] = [$processes[$i], $pipes];
            }
            foreach ($processes as $i => [$process, $pipes]) {
                $err = stream_get_contents($pipes[2]) . stream_get_contents($pipes[1]);
                $this->assertSame(0, proc_close($process), "process {$i}: {$err}");
            }
            $store = $backend->open();
            $store->upsertJob(new JobDefinition(['name' => 'a']), 1);
            $this->assertSame(1, $backend->open()->getJob('a')->createdAt);
        } finally {
            $backend->done();
        }
    }

    public function testTwoStoresRacingOnOneJobsStateOneWins(): void
    {
        $backend = $this->backend();
        try {
            $one = $backend->open();
            $two = $backend->open();
            $one->init();
            $state = fn (int $version, int $n) => new JobState('r', [], $n, null, null, null, null, $version);
            // Two connections: the second's write is judged against what the first committed.
            $this->assertSame([true, false], [$one->compareAndSetState($state(1, 1), 0), $two->compareAndSetState($state(1, 2), 0)], 'exactly one insert wins');
            $this->assertSame([true, false], [$two->compareAndSetState($state(2, 3), 1), $one->compareAndSetState($state(2, 4), 1)], 'exactly one update wins');
            $this->assertSame('{"job":"r","open":{},"consecutiveFailures":3,"silencedUntil":null,"lastAlertAt":null,"version":2}', Js::stringify($one->getState('r')));
        } finally {
            $backend->done();
        }
    }

    public function testItConnectsAgainWhenTheConnectionBroke(): void
    {
        $backend = $this->backend();
        try {
            $store = $backend->open();
            $store->init();
            $store->upsertJob(new JobDefinition(['name' => 'a']), 1);
            $connection = (new \ReflectionProperty(PostgresStore::class, 'db'))->getValue($store);
            $pid = $connection->query('SELECT pg_backend_pid()')->fetchColumn();
            self::admin($backend)->query("SELECT pg_terminate_backend({$pid})")->fetchColumn();
            usleep(100_000);
            $this->assertSame('a', $store->getJob('a')->name);
        } finally {
            $backend->done();
        }
    }
}
