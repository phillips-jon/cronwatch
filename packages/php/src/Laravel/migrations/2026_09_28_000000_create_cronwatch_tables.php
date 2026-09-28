<?php

declare(strict_types=1);

use Cronwatch\Laravel\ClientFactory;
use Cronwatch\Store\MysqlStore;
use Cronwatch\Store\PostgresStore;
use Cronwatch\Store\Sql;
use Cronwatch\Store\SqliteStore;
use Illuminate\Database\Migrations\Migration;

/**
 * CronWatch's three tables (jobs, runs, state), made by the store itself so
 * their CREATE text is the SDK's for the database, byte for byte: through
 * the store's own connection, with CREATE TABLE IF NOT EXISTS, so running
 * it where the tables are already there (made by another port, or by the
 * store at first use) changes nothing.
 */
return new class extends Migration
{
    public function up(): void
    {
        app(ClientFactory::class)->store(ignoreCreateTables: true)->init();
    }

    public function down(): void
    {
        $store = app(ClientFactory::class)->store(ignoreCreateTables: true);
        if (!$store instanceof SqliteStore && !$store instanceof MysqlStore && !$store instanceof PostgresStore) {
            return;
        }
        $config = (array) config('cronwatch.store', []);
        $prefix = Sql::tablePrefix(is_string($config['prefix'] ?? null) ? $config['prefix'] : Sql::DEFAULT_PREFIX);
        $connection = ($config['driver'] ?? 'database') === 'database'
            ? app('db')->connection(is_string($config['connection'] ?? null) && $config['connection'] !== '' ? $config['connection'] : null)
            : null;
        foreach (['runs', 'state', 'jobs'] as $table) {
            $sql = "DROP TABLE IF EXISTS {$prefix}{$table}";
            if ($connection !== null) {
                $connection->statement($sql);
            }
        }
        if ($connection === null && $store instanceof SqliteStore && $store->path !== ':memory:' && is_file($store->path)) {
            $pdo = new PDO('sqlite:' . $store->path);
            foreach (['runs', 'state', 'jobs'] as $table) {
                $pdo->exec("DROP TABLE IF EXISTS {$prefix}{$table}");
            }
        }
    }
};
