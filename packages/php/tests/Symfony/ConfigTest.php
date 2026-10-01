<?php

declare(strict_types=1);

namespace Cronwatch\Tests\Symfony;

use Cronwatch\Alerts\Console;
use Cronwatch\Alerts\Discord;
use Cronwatch\Alerts\Slack;
use Cronwatch\Alerts\Webhook;
use Cronwatch\Cronwatch;
use Cronwatch\Env;
use Cronwatch\Store\MemoryStore;
use Cronwatch\Store\Migrated;
use Cronwatch\Store\MysqlStore;
use Cronwatch\Store\PostgresStore;
use Cronwatch\Store\SqliteStore;
use Cronwatch\Symfony\ClientFactory;
use Cronwatch\Symfony\LoggerChannel;
use Cronwatch\Symfony\Stores;

/**
 * config/packages/cronwatch.yaml: the store from a URL written as Doctrine
 * writes one (DATABASE_URL works as it is), the channels, and the kernel's
 * environment.
 */
final class ConfigTest extends TestCase
{
    public function testAStoreFromADoctrineStyleUrl(): void
    {
        $dir = sys_get_temp_dir() . '/cw-symfony-' . bin2hex(random_bytes(4));
        $sqlite = Stores::fromUrl("sqlite://{$dir}/var/data.db", 'cw_');
        $this->assertInstanceOf(SqliteStore::class, $sqlite);
        $this->assertSame("{$dir}/var/data.db", $sqlite->path);
        $this->assertSame('cw_', $sqlite->prefix);
        $this->assertSame(':memory:', Stores::fromUrl('sqlite:///:memory:')->path);
        $this->assertInstanceOf(MemoryStore::class, Stores::fromUrl('memory'));
        if (extension_loaded('pdo_mysql')) {
            $this->assertInstanceOf(MysqlStore::class, Stores::fromUrl('mysql://app:pw@127.0.0.1:3306/app?serverVersion=8.0.32&charset=utf8mb4'));
            $this->assertInstanceOf(MysqlStore::class, Stores::fromUrl('pdo-mysql://app:pw@db/app'));
        }
        if (extension_loaded('pdo_pgsql')) {
            $this->assertInstanceOf(PostgresStore::class, Stores::fromUrl('postgresql://app:pw@127.0.0.1:5432/app?serverVersion=16&charset=utf8'));
        }
        try {
            Stores::fromUrl('sqlsrv://app@db/app');
            $this->fail('a sqlsrv URL is refused');
        } catch (\InvalidArgumentException $error) {
            $this->assertSame('CronWatch stores in MySQL, MariaDB, Postgres or SQLite; a sqlsrv URL is not one of them', $error->getMessage());
        }
    }

    public function testADoctrinePostgresUrlConnects(): void
    {
        $url = getenv('CRONWATCH_TEST_PG');
        if (!is_string($url) || $url === '') {
            $this->markTestSkipped('set CRONWATCH_TEST_PG to run');
        }
        // Doctrine's serverVersion and charset are not libpq's; the store leaves them out.
        $store = Stores::fromUrl(str_replace('postgres://', 'postgresql://', $url) . '?serverVersion=16&charset=utf8', 'cwsym_');
        $store->init();
        $this->assertSame([], $store->listJobs());
        $store->close();
        $pdo = new \PDO(...PostgresStore::connection($url));
        foreach (['runs', 'state', 'jobs'] as $table) {
            $pdo->exec("DROP TABLE IF EXISTS cwsym_{$table}");
        }
    }

    public function testChannelsTheStoreAndCreateTablesFromTheBundlesConfig(): void
    {
        $dir = sys_get_temp_dir() . '/cw-symfony-' . bin2hex(random_bytes(4));
        self::bootKernel(['cronwatch' => [
            'store' => "sqlite://{$dir}/cw.db",
            'create_tables' => false,
            'alerts' => [
                'slack' => 'https://hooks.slack.test/services/T/B/x',
                'discord' => 'https://discord.test/api/webhooks/1/x',
                'webhook' => ['url' => 'https://hooks.example.com/cron', 'secret' => 'sign-' . 'with-this'],
                'log' => true,
            ],
        ]]);
        $cw = static::getContainer()->get(Cronwatch::class);
        $this->assertSame([Slack::class, Discord::class, Webhook::class, LoggerChannel::class], array_map(fn ($c) => $c::class, $cw->alerts));
        $this->assertInstanceOf(Migrated::class, $cw->store);
        $this->assertSame("{$dir}/cw.db", $cw->store->inner->path);
        $this->assertSame($cw, static::getContainer()->get('cronwatch'));
    }

    public function testWithNoChannelAlertsGoToTheLogger(): void
    {
        self::bootKernel();
        $this->assertSame([LoggerChannel::class], array_map(fn ($c) => $c::class, static::getContainer()->get(Cronwatch::class)->alerts));
        $this->assertInstanceOf(MemoryStore::class, static::getContainer()->get(Cronwatch::class)->store);
        // Without a logger, the console.
        $this->assertSame([Console::class], array_map(fn ($c) => $c::class, ClientFactory::client(['store' => 'memory'], sys_get_temp_dir())->alerts));
    }

    public function testTheStoreDefaultsToDatabaseUrlElseAFileInVar(): void
    {
        $saved = getenv('DATABASE_URL');
        putenv('DATABASE_URL');
        try {
            $store = ClientFactory::store([], '/srv/app');
            $this->assertInstanceOf(SqliteStore::class, $store);
            $this->assertSame('/srv/app/var/cronwatch.db', $store->path);
            putenv('DATABASE_URL=sqlite:///srv/app/var/app.db');
            $this->assertSame('/srv/app/var/app.db', ClientFactory::store([], '/srv/app')->path);
        } finally {
            putenv($saved === false ? 'DATABASE_URL' : "DATABASE_URL={$saved}");
        }
    }

    public function testTheEnvironmentIsTheKernelsWhenNoVariableNamesOne(): void
    {
        $saved = [getenv('CRONWATCH_ENV'), getenv('APP_ENV'), $_SERVER['APP_ENV'] ?? null, $_ENV['APP_ENV'] ?? null];
        putenv('CRONWATCH_ENV');
        putenv('APP_ENV');
        unset($_SERVER['APP_ENV'], $_ENV['APP_ENV']);
        try {
            self::bootKernel(['environment' => 'prod']);
            $this->assertTrue(Env::isProduction());
            self::ensureKernelShutdown();
            self::bootKernel(['environment' => 'dev']);
            $this->assertTrue(Env::isDevelopment());
        } finally {
            putenv($saved[0] === false ? 'CRONWATCH_ENV' : "CRONWATCH_ENV={$saved[0]}");
            putenv($saved[1] === false ? 'APP_ENV' : "APP_ENV={$saved[1]}");
            if ($saved[2] !== null) {
                $_SERVER['APP_ENV'] = $saved[2];
            }
            if ($saved[3] !== null) {
                $_ENV['APP_ENV'] = $saved[3];
            }
            Env::setFallback(null);
        }
    }

    public function testAnUnsetCronSecretIsReadFromTheEnvironmentAndFalseTurnsItOff(): void
    {
        $saved = getenv('CRON_SECRET');
        try {
            putenv('CRON_SECRET=from-the-environment');
            $cw = ClientFactory::client(['store' => 'memory'], sys_get_temp_dir());
            $this->assertSame('from-the-environment', $cw->cronSecret);
            $this->assertFalse($cw->secretOptOut);
            $this->assertTrue(ClientFactory::client(['store' => 'memory', 'cron_secret' => false], sys_get_temp_dir())->secretOptOut);
            // A blank one (JavaScript's whitespace, U+00A0 included) is unset, and CRON_SECRET is read.
            $this->assertSame('from-the-environment', ClientFactory::client(['store' => 'memory', 'cron_secret' => " \u{00A0}\u{FEFF}"], sys_get_temp_dir())->cronSecret);
        } finally {
            putenv($saved === false ? 'CRON_SECRET' : "CRON_SECRET={$saved}");
        }
    }

}
