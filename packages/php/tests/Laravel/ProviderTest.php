<?php

declare(strict_types=1);

namespace Cronwatch\Tests\Laravel;

use Cronwatch\Alerts\Discord;
use Cronwatch\Alerts\Slack;
use Cronwatch\Alerts\Webhook;
use Cronwatch\Cronwatch;
use Cronwatch\Env;
use Cronwatch\Laravel\ClientFactory;
use Cronwatch\Laravel\DatabaseStore;
use Cronwatch\Laravel\LogChannel;
use Cronwatch\Laravel\MailChannel;
use Cronwatch\Laravel\Settings;
use Cronwatch\Store\MemoryStore;
use Cronwatch\Store\Migrated;
use Cronwatch\Store\MysqlStore;
use Cronwatch\Store\PostgresStore;
use Cronwatch\Store\Sql;
use Cronwatch\Store\SqliteStore;
use Illuminate\Support\Facades\DB;
use Orchestra\Testbench\Attributes\DefineEnvironment;

/**
 * The client the service provider binds, from config/cronwatch.php: its
 * store in the app's database through a connection of its own (SQLite
 * here, and MySQL, MariaDB and Postgres when CRONWATCH_TEST_MYSQL,
 * CRONWATCH_TEST_MARIADB and CRONWATCH_TEST_PG are set), the migration, the
 * alert channels, and the environment.
 */
final class ProviderTest extends TestCase
{
    private string $dir = '';

    protected function setUp(): void
    {
        $this->dir = sys_get_temp_dir() . '/cw-laravel-db-' . getmypid() . '-' . bin2hex(random_bytes(4));
        mkdir($this->dir);
        parent::setUp();
    }

    protected function tearDown(): void
    {
        parent::tearDown();
        foreach (glob("{$this->dir}/*") ?: [] as $file) {
            @unlink($file);
        }
        @rmdir($this->dir);
    }

    protected function defineEnvironment($app): void
    {
        parent::defineEnvironment($app);
        touch("{$this->dir}/app.db");
        $app['config']->set('database.connections.app', ['driver' => 'sqlite', 'database' => "{$this->dir}/app.db", 'prefix' => 'app_', 'foreign_key_constraints' => true]);
        $app['config']->set('database.default', 'app');
        $app['config']->set('cronwatch.store.driver', 'database');
    }

    public function testTheClientIsASingletonStoringInTheAppsDatabaseThroughItsOwnConnection(): void
    {
        $cw = $this->app->make(Cronwatch::class);
        $this->assertSame($cw, $this->app->make(Cronwatch::class));
        $this->assertInstanceOf(SqliteStore::class, $cw->store);
        $this->assertSame("{$this->dir}/app.db", $cw->store->path);

        // A run recorded inside the app's transaction survives its rollback.
        try {
            DB::transaction(function () use ($cw): void {
                $cw->job('inside')->run(fn () => 'ran');
                throw new \RuntimeException('roll back');
            });
        } catch (\RuntimeException) {
        }
        $this->assertSame('ran', $cw->runs('inside')[0]->output);
        // The tables are CronWatch's names, not the connection's prefix.
        $this->assertSame(1, DB::connection('app')->getPdo()->query("SELECT COUNT(*) FROM cronwatch_runs")->fetchColumn());
    }

    public function testTheMigrationMakesTheTablesWithTheSdksText(): void
    {
        $this->artisan('migrate')->assertExitCode(0);
        $pdo = new \PDO("sqlite:{$this->dir}/app.db");
        $made = $pdo->query("SELECT sql FROM sqlite_master WHERE name LIKE 'cronwatch_%' ORDER BY name")->fetchAll(\PDO::FETCH_COLUMN);
        $expected = new \PDO('sqlite::memory:');
        $expected->exec(Sql::sqliteSchema('cronwatch_'));
        $this->assertSame($expected->query("SELECT sql FROM sqlite_master WHERE name LIKE 'cronwatch_%' ORDER BY name")->fetchAll(\PDO::FETCH_COLUMN), $made);
        $this->artisan('migrate:rollback')->assertExitCode(0);
        $this->assertSame([], $pdo->query("SELECT name FROM sqlite_master WHERE name LIKE 'cronwatch_%'")->fetchAll(\PDO::FETCH_COLUMN));
    }

    protected function noCreate($app): void
    {
        $app['config']->set('cronwatch.create_tables', false);
    }

    #[DefineEnvironment('noCreate')]
    public function testWithoutCreateTablesTheStoreLeavesTheTablesToTheMigration(): void
    {
        $cw = $this->app->make(Cronwatch::class);
        $this->assertInstanceOf(Migrated::class, $cw->store);
        $this->artisan('migrate')->assertExitCode(0);
        $cw->job('after-migrate')->run(fn () => null);
        $this->assertCount(1, $cw->runs('after-migrate'));
    }

    /** A config/cronwatch.php published before 1.0, with the keys 1.0 renamed. */
    protected function keysBefore10($app): void
    {
        $app['config']->set('cronwatch.store', ['driver' => 'database', 'prefix' => 'old_', 'create_tables' => false, 'migrations' => true]);
        $app['config']->set('cronwatch.schedule', ['watch' => true, 'exclude' => [], 'check' => true, 'check_cron' => '*/7 * * * *']);
    }

    #[DefineEnvironment('keysBefore10')]
    public function testTheKeysRenamedIn10AreStillReadWithADeprecationNotice(): void
    {
        Settings::forgetReported();
        $notices = [];
        set_error_handler(function (int $level, string $message) use (&$notices): bool {
            $notices[] = [$level, $message];
            return true;
        }, E_USER_DEPRECATED);
        try {
            $cw = $this->app->make(Cronwatch::class);
            $config = $this->app->make('config');
            $read = [Settings::scheduleCheck($config), Settings::checkFrequency($config)];
            Settings::tablePrefix($config);
        } finally {
            restore_error_handler();
        }
        $this->assertInstanceOf(Migrated::class, $cw->store);
        $this->assertSame([true, '*/7 * * * *'], $read);
        $this->assertTrue(collect($this->app->make(\Illuminate\Console\Scheduling\Schedule::class)->events())
            ->contains(fn ($e) => str_contains((string) $e->command, 'cronwatch:check') && $e->expression === '*/7 * * * *'));
        $this->artisan('migrate')->assertExitCode(0);
        $pdo = new \PDO("sqlite:{$this->dir}/app.db");
        $this->assertSame(['old_jobs', 'old_runs', 'old_state'], $pdo->query("SELECT name FROM sqlite_master WHERE type = 'table' AND name LIKE 'old_%' ORDER BY name")->fetchAll(\PDO::FETCH_COLUMN));
        // Once per key per process, naming the new key.
        $this->assertSame([
            [E_USER_DEPRECATED, 'The cronwatch.store.prefix setting is deprecated and is read until 2.0; rename it to cronwatch.table_prefix in config/cronwatch.php.'],
            [E_USER_DEPRECATED, 'The cronwatch.store.create_tables setting is deprecated and is read until 2.0; rename it to cronwatch.create_tables in config/cronwatch.php.'],
            [E_USER_DEPRECATED, 'The cronwatch.schedule.check setting is deprecated and is read until 2.0; rename it to cronwatch.check.schedule in config/cronwatch.php.'],
            [E_USER_DEPRECATED, 'The cronwatch.schedule.check_cron setting is deprecated and is read until 2.0; rename it to cronwatch.check.frequency in config/cronwatch.php.'],
        ], $notices);
    }

    public function testTheKeysOf10AloneGiveNoNotice(): void
    {
        Settings::forgetReported();
        $notices = 0;
        set_error_handler(function () use (&$notices): bool {
            $notices++;
            return true;
        }, E_USER_DEPRECATED);
        try {
            $this->app['config']->set('cronwatch.table_prefix', 'new_');
            $config = $this->app->make('config');
            $read = [Settings::tablePrefix($config), Settings::createTables($config), Settings::scheduleCheck($config), Settings::checkFrequency($config)];
        } finally {
            restore_error_handler();
        }
        $this->assertSame(['new_', true, true, '*/5 * * * *'], $read);
        $this->assertSame(0, $notices);
    }

    public function testASqliteFileOfItsOwn(): void
    {
        $this->app['config']->set('cronwatch.store.driver', 'sqlite');
        $this->app['config']->set('cronwatch.store.path', "{$this->dir}/own.db");
        $this->app['config']->set('cronwatch.table_prefix', 'cw_');
        $cw = $this->app->make(Cronwatch::class);
        $this->assertInstanceOf(SqliteStore::class, $cw->store);
        $this->assertSame("{$this->dir}/own.db", $cw->store->path);
        $this->assertSame('cw_', $cw->store->prefix);
    }

    protected function memoryDatabase($app): void
    {
        $app['config']->set('database.connections.mem', ['driver' => 'sqlite', 'database' => ':memory:', 'prefix' => '']);
        $app['config']->set('cronwatch.store.connection', 'mem');
    }

    #[DefineEnvironment('memoryDatabase')]
    public function testAnInMemorySqliteConnectionIsShared(): void
    {
        $cw = $this->app->make(Cronwatch::class);
        $cw->job('shared')->run(fn () => null);
        $this->assertSame(1, DB::connection('mem')->table('cronwatch_runs')->count());
    }

    public function testTheConnectionsSettingsBecomeTheStoresOwn(): void
    {
        $this->assertSame('mysql:host=db.internal;port=3307;dbname=app;charset=utf8mb4', DatabaseStore::mysqlDsn(['host' => 'db.internal', 'port' => '3307', 'database' => 'app', 'charset' => 'utf8']));
        $this->assertSame('mysql:unix_socket=/tmp/mysql.sock;dbname=app;charset=utf8mb4', DatabaseStore::mysqlDsn(['host' => 'x', 'unix_socket' => '/tmp/mysql.sock', 'database' => 'app']));
        $this->assertSame(
            "pgsql:host='pg.internal';port='5432';dbname='app';sslmode='require';options='--search_path=tenant,public'",
            DatabaseStore::pgsqlDsn(['host' => 'pg.internal', 'port' => 5432, 'database' => 'app', 'sslmode' => 'require', 'search_path' => 'tenant, public']),
        );
        $this->assertSame("pgsql:host='pg';dbname='app'", DatabaseStore::pgsqlDsn(['host' => 'pg', 'database' => 'app', 'search_path' => 'public']));
        $this->assertSame(
            ['driver' => 'mysql', 'database' => 'app', 'host' => 'primary', 'username' => 'writer'],
            DatabaseStore::writeConfig(['driver' => 'mysql', 'database' => 'app', 'read' => ['host' => ['replica']], 'write' => ['host' => ['primary', 'other'], 'username' => 'writer']]),
        );
    }

    /** @return iterable<string, array{string, string, class-string}> */
    public static function servers(): iterable
    {
        yield 'mysql' => ['CRONWATCH_TEST_MYSQL', 'mysql', MysqlStore::class];
        yield 'mariadb' => ['CRONWATCH_TEST_MARIADB', 'mariadb', MysqlStore::class];
        yield 'postgres' => ['CRONWATCH_TEST_PG', 'pgsql', PostgresStore::class];
    }

    #[\PHPUnit\Framework\Attributes\DataProvider('servers')]
    public function testTheAppsServerDatabase(string $variable, string $driver, string $class): void
    {
        $url = getenv($variable);
        if (!is_string($url) || $url === '') {
            $this->markTestSkipped("set {$variable} to run");
        }
        $prefix = 'cwl' . bin2hex(random_bytes(3)) . '_';
        $parts = parse_url($url);
        $this->app['config']->set("database.connections.server", [
            'driver' => $driver, 'host' => $parts['host'], 'port' => $parts['port'] ?? null, 'database' => ltrim($parts['path'], '/'),
            'username' => rawurldecode($parts['user'] ?? ''), 'password' => rawurldecode($parts['pass'] ?? ''), 'charset' => $driver === 'pgsql' ? 'utf8' : 'utf8mb4', 'prefix' => '',
        ]);
        $this->app['config']->set('cronwatch.store', ['driver' => 'database', 'connection' => 'server']);
        $this->app['config']->set('cronwatch.table_prefix', $prefix);
        $this->app->forgetInstance(Cronwatch::class);
        $cw = $this->app->make(Cronwatch::class);
        $this->assertInstanceOf($class, $cw->store);
        $db = DB::connection('server');
        try {
            $db->statement("CREATE TABLE {$prefix}app_table (id INT)");
            try {
                $db->transaction(function () use ($cw, $db, $prefix): void {
                    $db->insert("INSERT INTO {$prefix}app_table (id) VALUES (1)");
                    $cw->job('inside')->run(fn () => 'ran');
                    throw new \RuntimeException('roll back');
                });
            } catch (\RuntimeException) {
            }
            $this->assertSame(0, (int) $db->table("{$prefix}app_table")->count(), 'the app\'s write rolled back');
            $this->assertSame('ran', $cw->runs('inside')[0]->output, 'CronWatch\'s did not');
        } finally {
            foreach (['app_table', 'runs', 'state', 'jobs'] as $table) {
                $db->statement("DROP TABLE IF EXISTS {$prefix}{$table}");
            }
            $cw->close();
        }
    }

    protected function channels($app): void
    {
        $app['config']->set('cronwatch.alerts.mail.to', 'ops@example.com, oncall@example.com');
        $app['config']->set('cronwatch.alerts.mail.from', 'CronWatch <alerts@example.com>');
        $app['config']->set('cronwatch.alerts.slack', 'https://hooks.slack.test/services/T/B/x');
        $app['config']->set('cronwatch.alerts.discord', 'https://discord.test/api/webhooks/1/x');
        $app['config']->set('cronwatch.alerts.webhook', ['url' => 'https://hooks.example.com/cron', 'secret' => 'sign-' . 'with-this']);
        $app['config']->set('cronwatch.alerts.log', 'stack');
    }

    #[DefineEnvironment('channels')]
    public function testChannelsComeFromConfig(): void
    {
        $alerts = $this->app->make(Cronwatch::class)->alerts;
        $this->assertSame([MailChannel::class, Slack::class, Discord::class, Webhook::class, LogChannel::class], array_map(fn ($c) => $c::class, $alerts));
    }

    public function testWithNoChannelAlertsGoToTheLog(): void
    {
        $this->assertSame([LogChannel::class], array_map(fn ($c) => $c::class, $this->app->make(ClientFactory::class)->alerts()));
    }

    public function testTheMailChannelSendsThroughTheAppsMailer(): void
    {
        $this->app['config']->set('mail.mailers.array', ['transport' => 'array']);
        $cw = $this->client(['alerts' => [new MailChannel($this->app->make('mail.manager'), 'ops@example.com', 'CronWatch <alerts@example.com>', 'array', '[test]')]]);
        try {
            $cw->job('mailed')->run(fn () => throw new \RuntimeException('boom'));
        } catch (\RuntimeException) {
        }
        $messages = $this->app->make('mail.manager')->mailer('array')->getSymfonyTransport()->messages();
        $this->assertCount(1, $messages);
        $email = $messages[0]->getOriginalMessage();
        $this->assertSame('[test] mailed failed', $email->getSubject());
        $this->assertSame('alerts@example.com', $email->getFrom()[0]->getAddress());
        $this->assertSame('CronWatch', $email->getFrom()[0]->getName());
        $this->assertStringContainsString('RuntimeException: boom', $email->getTextBody());
        $this->assertStringContainsString('<', (string) $email->getHtmlBody());
    }

    public function testTheEnvironmentIsTheAppsWhenNoVariableNamesOne(): void
    {
        $saved = [getenv('CRONWATCH_ENV'), getenv('APP_ENV')];
        putenv('CRONWATCH_ENV');
        putenv('APP_ENV');
        $server = [$_SERVER['APP_ENV'] ?? null, $_ENV['APP_ENV'] ?? null];
        unset($_SERVER['APP_ENV'], $_ENV['APP_ENV']);
        try {
            $this->app['env'] = 'local';
            $this->assertTrue(Env::isDevelopment());
            $this->app['env'] = 'production';
            $this->assertTrue(Env::isProduction());
        } finally {
            foreach (['CRONWATCH_ENV', 'APP_ENV'] as $i => $name) {
                putenv($saved[$i] === false ? $name : "{$name}={$saved[$i]}");
            }
            if ($server[0] !== null) {
                $_SERVER['APP_ENV'] = $server[0];
            }
            if ($server[1] !== null) {
                $_ENV['APP_ENV'] = $server[1];
            }
        }
    }

    public function testAMemoryStoreForTests(): void
    {
        $this->app['config']->set('cronwatch.store.driver', 'memory');
        $this->assertInstanceOf(MemoryStore::class, $this->app->make(ClientFactory::class)->store());
    }
}
