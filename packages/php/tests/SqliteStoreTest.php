<?php

declare(strict_types=1);

namespace Cronwatch\Tests;

use Cronwatch\JobDefinition;
use Cronwatch\Store\Sql;
use Cronwatch\Store\SqliteStore;
use PHPUnit\Framework\TestCase;

/** stores.test.ts's SQLite tests. */
final class SqliteStoreTest extends TestCase
{
    private string $dir;

    protected function setUp(): void
    {
        $this->dir = sys_get_temp_dir() . '/cronwatch-sqlite-' . getmypid() . '-' . bin2hex(random_bytes(4));
    }

    protected function tearDown(): void
    {
        $remove = function (string $path) use (&$remove): void {
            if (is_dir($path)) {
                foreach (scandir($path) ?: [] as $entry) {
                    if ($entry !== '.' && $entry !== '..') {
                        $remove("{$path}/{$entry}");
                    }
                }
                rmdir($path);
            } elseif (file_exists($path)) {
                unlink($path);
            }
        };
        $remove($this->dir);
    }

    public function testTheFilePersistsBetweenOpensAndItsDirectoryIsCreated(): void
    {
        $file = "{$this->dir}/nested/persist.db";
        $a = new SqliteStore($file);
        $a->init();
        $a->upsertJob(new JobDefinition(['name' => 'keep']), 1);
        $a->close();
        $b = new SqliteStore($file);
        $b->init();
        $this->assertSame(1, $b->getJob('keep')->createdAt);
        $b->close();
    }

    /**
     * The default file is the app's (data/cronwatch.db beside its vendor
     * directory), not the working directory's, so the dashboard under
     * PHP-FPM (whose working directory is the script's, often public/) and
     * the cron check read the same file, and it is not under public/.
     */
    public function testTheDefaultFileIsTheAppsWhateverTheWorkingDirectory(): void
    {
        $root = realpath(__DIR__ . '/..');
        $was = getcwd();
        mkdir($this->dir);
        try {
            chdir($this->dir);
            $this->assertSame("{$root}/data/cronwatch.db", (new SqliteStore())->path);
            $this->assertSame("{$root}/data/cronwatch.db", SqliteStore::defaultPath());
            $this->assertSame('./given.db', (new SqliteStore('./given.db'))->path, 'a path given is kept as it is');
        } finally {
            chdir((string) $was);
        }
    }

    public function testTheDatabaseFileAndItsWalAndShmFilesArePrivate(): void
    {
        if (PHP_OS_FAMILY === 'Windows') {
            $this->markTestSkipped('no POSIX modes');
        }
        $file = "{$this->dir}/private.db";
        $store = new SqliteStore($file);
        $store->init();
        $store->insertRun(StoreConformanceTest::makeRun('r1', 'a', 'running', 1));
        foreach ([$file, "{$file}-wal", "{$file}-shm"] as $f) {
            clearstatcache();
            $this->assertSame(0600, fileperms($f) & 0777, $f);
        }
        $mode = (new \PDO("sqlite:{$file}"))->query('PRAGMA journal_mode')->fetchColumn();
        $this->assertSame('wal', $mode);
        $store->close();
    }

    public function testOpeningRetriesABusyDatabaseAndKeepsNothingFromAFailedOpen(): void
    {
        mkdir($this->dir);
        $file = "{$this->dir}/busy.db";
        $holder = new \PDO("sqlite:{$file}", null, null, [\PDO::ATTR_ERRMODE => \PDO::ERRMODE_EXCEPTION]);
        $holder->exec('CREATE TABLE t (x)');
        $holder->exec('BEGIN EXCLUSIVE');
        $store = new SqliteStore($file);
        $started = microtime(true);
        try {
            $store->init();
            $this->fail('expected SQLITE_BUSY');
        } catch (\PDOException $error) {
            $this->assertTrue(SqliteStore::isBusy($error), $error->getMessage());
        }
        $this->assertGreaterThanOrEqual(1.5, microtime(true) - $started, 'it kept trying for a while first');
        $holder->exec('COMMIT');
        $holder = null;
        // The next use opens afresh, and gets WAL and the busy timeout this time.
        $store->init();
        $store->upsertJob(new JobDefinition(['name' => 'after']), 1);
        $this->assertSame('wal', (new \PDO("sqlite:{$file}"))->query('PRAGMA journal_mode')->fetchColumn());
        $store->close();
    }

    private static function sqliteError(int $code, string $message): \PDOException
    {
        $error = new \PDOException($message);
        $error->errorInfo = ['HY000', $code, $message];
        return $error;
    }

    public function testRetryBusyRetriesOnlySqliteBusyAndLockedWithinItsBudget(): void
    {
        $pauses = [];
        $sleep = function (int $ms) use (&$pauses): void {
            $pauses[] = $ms;
        };
        $calls = 0;
        $busy = self::sqliteError(5, 'database is locked');
        $this->assertSame('ok', SqliteStore::retryBusy(function () use (&$calls, $busy) {
            if (++$calls < 4) {
                throw $busy;
            }
            return 'ok';
        }, 2_000, $sleep));
        $this->assertSame([10, 20, 40], $pauses);
        $pauses = [];
        try {
            SqliteStore::retryBusy(fn () => throw self::sqliteError(6 | (1 << 8), 'x'), 100, $sleep);
            $this->fail('expected the error once the budget was spent');
        } catch (\PDOException $error) {
            $this->assertSame('x', $error->getMessage());
        }
        $this->assertSame(100, array_sum($pauses), 'gave up once the budget was spent');
        $pauses = [];
        try {
            SqliteStore::retryBusy(fn () => throw self::sqliteError(11, 'corrupt'), 2_000, $sleep);
            $this->fail('expected the error at once');
        } catch (\PDOException $error) {
            $this->assertSame('corrupt', $error->getMessage());
        }
        $this->assertSame([], $pauses, 'anything else is thrown at once');
    }

    public function testTheSchemaIsTheSdksTextForText(): void
    {
        $file = "{$this->dir}/cw.db";
        $store = new SqliteStore($file, prefix: 'mon_');
        $store->init();
        $statement = (new \PDO("sqlite:{$file}"))->query("SELECT name, sql FROM sqlite_master WHERE name LIKE 'mon_%' ORDER BY name");
        $rows = $statement->fetchAll(\PDO::FETCH_KEY_PAIR);
        $this->assertSame(['mon_jobs', 'mon_runs', 'mon_runs_job_started', 'mon_runs_running', 'mon_state'], array_keys($rows));
        $this->assertSame("CREATE INDEX mon_runs_running ON mon_runs (status) WHERE status = 'running'", $rows['mon_runs_running']);
        $store->init(); // IF NOT EXISTS: a second init changes nothing
        $store->close();
    }

    public function testInMemoryAndAConnectionOfYourOwn(): void
    {
        $memory = new SqliteStore(':memory:');
        $memory->init();
        $memory->upsertJob(new JobDefinition(['name' => 'm']), 1);
        $this->assertSame('m', $memory->getJob('m')->name);
        $memory->close();

        mkdir($this->dir);
        $pdo = new \PDO("sqlite:{$this->dir}/own.db", null, null, [\PDO::ATTR_ERRMODE => \PDO::ERRMODE_EXCEPTION]);
        $own = new SqliteStore(pdo: $pdo);
        $own->init();
        $own->upsertJob(new JobDefinition(['name' => 'o']), 2);
        $own->close();
        $this->assertSame(['o'], $pdo->query('SELECT name FROM cronwatch_jobs')->fetchAll(\PDO::FETCH_COLUMN), 'a connection given is left open');
    }

    public function testTablePrefixIsAPlainLowercaseIdentifier(): void
    {
        $this->assertSame('cronwatch_', Sql::tablePrefix());
        $this->assertSame('app_cw_', Sql::tablePrefix('app_cw_'));
        foreach (['Monitoring_', '1st_', 'has-dash_', '', str_repeat('x', 48)] as $bad) {
            try {
                new SqliteStore(':memory:', prefix: $bad);
                $this->fail("expected {$bad} refused");
            } catch (\InvalidArgumentException $error) {
                $this->assertStringContainsString('invalid table prefix', $error->getMessage());
            }
        }
    }
}
