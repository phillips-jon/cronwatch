<?php

declare(strict_types=1);

namespace Cronwatch\Tests;

use Cronwatch\Cronwatch;
use Cronwatch\JobDefinition;
use Cronwatch\JobState;
use Cronwatch\Js;
use Cronwatch\Run;
use Cronwatch\Store\MysqlStore;
use Cronwatch\Tests\Support\Backend;
use Cronwatch\Tests\Support\Clock;
use PHPUnit\Framework\Attributes\DataProvider;
use PHPUnit\Framework\TestCase;

/**
 * The MySQL store's own tests, against MySQL 8 and MariaDB when
 * CRONWATCH_TEST_MYSQL and CRONWATCH_TEST_MARIADB name them: its schema, the
 * JSON it keeps byte for byte, its own connection beside the app's
 * transaction, and the ways MySQL counts affected rows.
 */
final class MysqlStoreTest extends TestCase
{
    public function testAUrlBecomesADsnWithUtf8mb4(): void
    {
        if (!extension_loaded('pdo_mysql')) {
            $this->markTestSkipped('needs pdo_mysql');
        }
        $password = 'p' . '%40ss';
        $this->assertSame(
            ['mysql:host=db.internal;port=3307;dbname=app;charset=utf8mb4', 'app user', 'p@ss'],
            MysqlStore::connection("mysql://app%20user:{$password}@db.internal:3307/app"),
        );
        $this->assertSame(['mysql:host=127.0.0.1;dbname=cw;charset=latin1', null, null], MysqlStore::connection('mariadb://127.0.0.1/cw?charset=latin1'));
        $this->assertSame(['mysql:unix_socket=/tmp/mysql.sock;dbname=cw;charset=utf8mb4', 'u', null], MysqlStore::connection('mysql://u@localhost/cw?unix_socket=/tmp/mysql.sock'));
        $this->assertSame(['mysql:host=h;dbname=d;charset=utf8mb4', 'u', 'x'], MysqlStore::connection('mysql:host=h;dbname=d', 'u', 'x'), 'a DSN passes through');
        $this->assertSame(['mysql:host=h;charset=latin1', null, null], MysqlStore::connection('mysql:host=h;charset=latin1'));
        $this->expectExceptionMessage('mysql:// or mariadb://');
        MysqlStore::connection('postgres://h/d');
    }

    public function testWithoutAUrlItReadsDatabaseUrl(): void
    {
        if (!extension_loaded('pdo_mysql')) {
            $this->markTestSkipped('needs pdo_mysql');
        }
        $saved = getenv('DATABASE_URL');
        try {
            putenv('DATABASE_URL=postgres://h/d');
            try {
                new MysqlStore();
                $this->fail('a Postgres DATABASE_URL is not taken');
            } catch (\InvalidArgumentException $error) {
                $this->assertStringContainsString('DATABASE_URL', $error->getMessage());
            }
            putenv('DATABASE_URL=mysql://u@127.0.0.1:1/none');
            $this->assertInstanceOf(MysqlStore::class, new MysqlStore(), 'nothing connects until first use');
        } finally {
            putenv($saved === false ? 'DATABASE_URL' : "DATABASE_URL={$saved}");
        }
    }

    public static function servers(): iterable
    {
        yield 'mysql' => ['mysql'];
        yield 'mariadb' => ['mariadb'];
    }

    private function backend(string $kind): Backend
    {
        $why = Backend::unavailable($kind);
        if ($why !== null) {
            $this->markTestSkipped($why);
        }
        return Backend::make($kind);
    }

    private static function admin(Backend $backend): \PDO
    {
        [$dsn, $user, $password] = MysqlStore::connection((string) $backend->url);
        return new \PDO($dsn, $user, $password, [\PDO::ATTR_ERRMODE => \PDO::ERRMODE_EXCEPTION]);
    }

    #[DataProvider('servers')]
    public function testTheSchemaKeepsTheSdksJsonByteForByte(string $kind): void
    {
        $backend = $this->backend($kind);
        try {
            $store = $backend->open();
            $store->init();
            $store->init(); // IF NOT EXISTS: a second init changes nothing
            $p = $backend->prefix;
            $admin = self::admin($backend);
            $columns = $admin->query("SELECT TABLE_NAME, COLUMN_NAME, DATA_TYPE, COLLATION_NAME FROM information_schema.COLUMNS WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME LIKE '{$p}%' ORDER BY TABLE_NAME, ORDINAL_POSITION")->fetchAll(\PDO::FETCH_NUM);
            $types = [];
            foreach ($columns as [$table, $column, $type, $collation]) {
                $types[substr($table, strlen($p)) . ".{$column}"] = $type . ($collation === null ? '' : " {$collation}");
            }
            $this->assertSame('longtext utf8mb4_bin', $types['jobs.definition'], 'text, never the JSON type, which rewrites what it holds');
            $this->assertSame('longtext utf8mb4_bin', $types['runs.metrics']);
            $this->assertSame('longtext utf8mb4_bin', $types['state.state']);
            $this->assertSame('varchar utf8mb4_bin', $types['jobs.name'], 'names compare as bytes: "b" and "B" are two jobs');
            $this->assertSame(['seq', 'id', 'job', 'status', 'started_at', 'finished_at', 'duration_ms', 'error', 'output', 'metrics', 'trigger'], array_values(array_map(
                fn (string $key) => substr($key, 5),
                array_filter(array_keys($types), fn (string $key) => str_starts_with($key, 'runs.')),
            )));

            $definition = new JobDefinition(['grace' => '15m', 'schedule' => '0 2 * * *', 'budget' => ['cost' => 2], 'tags' => ['café ☃ 😀'], 'name' => 'nightly']);
            $store->upsertJob($definition, 1);
            $run = new Run('r1', 'nightly', 'ok', 1, 2, 1, null, "tab\tand \"quotes\" 😀", ['ratio' => 0.30000000000000004, 'tiny' => 1e-7, 'huge' => 1e21, 'üml' => 7], 'run');
            $store->insertRun($run);
            $state = new JobState('nightly', ['failed' => 5], 1, null, null, ['missed'], [], 3);
            $store->setState($state);
            $this->assertSame(Js::stringify($definition), $admin->query("SELECT definition FROM {$p}jobs")->fetchColumn());
            $this->assertSame('{"ratio":0.30000000000000004,"tiny":1e-7,"huge":1e+21,"üml":7}', $admin->query("SELECT metrics FROM {$p}runs")->fetchColumn());
            $this->assertSame(Js::stringify($state), $admin->query("SELECT state FROM {$p}state")->fetchColumn());
            $this->assertSame(Js::stringify($run), Js::stringify($store->getRun('r1')));
        } finally {
            $backend->done();
        }
    }

    #[DataProvider('servers')]
    public function testARunRecordedInsideTheAppsTransactionSurvivesItsRollback(string $kind): void
    {
        $backend = $this->backend($kind);
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
            $shared = new MysqlStore(pdo: $app, prefix: $backend->prefix);
            $app->beginTransaction();
            $shared->insertRun(new Run('in-tx', 'import', 'running', 1));
            $app->rollBack();
            $this->assertNull($shared->getRun('in-tx'));
            $app->exec("DROP TABLE {$backend->prefix}orders");
        } finally {
            $backend->done();
        }
    }

    #[DataProvider('servers')]
    public function testConditionalWritesDoNotLeanOnHowTheConnectionCountsRows(string $kind): void
    {
        $backend = $this->backend($kind);
        try {
            $backend->open()->init();
            [$dsn, $user, $password] = MysqlStore::connection((string) $backend->url);
            // PHP 8.4 moved the constant to Pdo\Mysql, and 8.5 deprecates the old one.
            $attribute = constant(defined('Pdo\Mysql::ATTR_FOUND_ROWS') ? 'Pdo\Mysql::ATTR_FOUND_ROWS' : 'PDO::MYSQL_ATTR_FOUND_ROWS');
            foreach ([false, true] as $foundRows) {
                // FOUND_ROWS: an app's connection may count rows matched rather than changed.
                $pdo = new \PDO($dsn, $user, $password, [\PDO::ATTR_ERRMODE => \PDO::ERRMODE_EXCEPTION, $attribute => $foundRows]);
                $store = new MysqlStore(pdo: $pdo, prefix: $backend->prefix);
                $job = $foundRows ? 'found' : 'changed';
                $v = fn (int $version, int $failures = 0) => new JobState($job, [], $failures, null, null, null, null, $version);
                $this->assertTrue($store->compareAndSetState($v(1), 0));
                $this->assertFalse($store->compareAndSetState($v(1, 9), 0), 'a write from a stale read is refused');
                $this->assertFalse($store->compareAndSetState($v(3), 1 + 1));
                $this->assertTrue($store->compareAndSetState($v(2, 1), 1));
                $this->assertSame(2, $store->getState($job)->version);
                $store->setState(new JobState("{$job}-old", [], 3));
                $this->assertTrue($store->compareAndSetState(new JobState("{$job}-old", [], 4, null, null, null, null, 1), 0), 'state written before versions counts as 0');

                // A flush that writes what the row already holds still wrote.
                $run = new Run("{$job}-r", $job, 'running', 1, null, null, null, 'same', ['n' => 1]);
                $store->insertRun($run);
                $this->assertTrue($store->updateRunIf($run, ['running']));
                $this->assertFalse($store->updateRunIf($run, ['timeout']));
            }
        } finally {
            $backend->done();
        }
    }

    #[DataProvider('servers')]
    public function testItConnectsAgainWhenTheServerHasGoneAway(string $kind): void
    {
        $backend = $this->backend($kind);
        try {
            $store = $backend->open();
            $store->init();
            $store->upsertJob(new JobDefinition(['name' => 'a']), 1);
            $connection = (new \ReflectionProperty(MysqlStore::class, 'db'))->getValue($store);
            $id = $connection->query('SELECT CONNECTION_ID()')->fetchColumn();
            self::admin($backend)->exec("KILL {$id}");
            usleep(100_000);
            $this->assertSame('a', $store->getJob('a')->name);
        } finally {
            $backend->done();
        }
    }
}
