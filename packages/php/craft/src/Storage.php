<?php

declare(strict_types=1);

namespace Cronwatch\Craft;

use Cronwatch\Store\MysqlStore;
use Cronwatch\Store\PdoStore;
use Cronwatch\Store\PostgresStore;
use Cronwatch\Store\Sql;
use Craft;
use yii\db\Connection;

/**
 * The store in Craft's own database: the library's MySQL (and MariaDB) or
 * Postgres store, made from Craft's database connection (its DSN,
 * credentials, PDO attributes, and Postgres schema), through a PDO
 * connection of its own. So CronWatch's writes never join a transaction
 * Craft has open (a run recorded inside one survives its rollback), and the
 * tables are the library's, byte for byte, as every port writes them.
 *
 * The tables are Craft's table prefix and "cronwatch_", made by the
 * plugin's install migration with the library's CREATE text and dropped
 * when the plugin is uninstalled.
 */
final class Storage
{
    public static function db(): Connection
    {
        return Craft::$app->getDb();
    }

    /** The tables' prefix: Craft's own, lowercased, then "cronwatch_". */
    public static function prefix(?Connection $db = null): string
    {
        $db ??= self::db();
        return Sql::tablePrefix(strtolower((string) $db->tablePrefix) . 'cronwatch_');
    }

    public static function store(?Connection $db = null): PdoStore
    {
        $db ??= self::db();
        [$kind, $dsn, $username, $password, $options] = self::connection($db);
        return $kind === 'mysql'
            ? new MysqlStore($dsn, $username, $password, prefix: self::prefix($db), options: $options)
            : new PostgresStore($dsn, $username, $password, prefix: self::prefix($db), options: $options);
    }

    /**
     * The PDO DSN, credentials, and attributes of Craft's connection.
     *
     * @return array{string, string, ?string, ?string, array<int, mixed>}
     */
    public static function connection(Connection $db): array
    {
        $driver = $db->getDriverName();
        $dsn = (string) $db->dsn;
        if ($driver === 'mysql') {
            // The tables are utf8mb4 whatever the connection uses; the store adds it.
            $dsn = (string) preg_replace('/;?charset=[^;]*/i', '', $dsn);
            $kind = 'mysql';
        } elseif ($driver === 'pgsql') {
            $schema = (string) (Craft::$app->getConfig()->getDb()->schema ?? '');
            $schema = (string) preg_replace('/[^A-Za-z0-9_$]/', '', $schema);
            if ($schema !== '' && $schema !== 'public' && stripos($dsn, 'options=') === false) {
                $dsn = rtrim($dsn, ';') . ";options='--search_path={$schema}'";
            }
            $kind = 'pgsql';
        } else {
            throw new \RuntimeException("CronWatch keeps its tables in MySQL, MariaDB, or Postgres; Craft's database driver is {$driver}.");
        }
        $options = [];
        foreach ((array) $db->attributes as $key => $value) {
            if (is_int($key) && $value !== null) {
                $options[$key] = $value;
            }
        }
        unset($options[\PDO::ATTR_ERRMODE], $options[\PDO::ATTR_EMULATE_PREPARES], $options[\PDO::ATTR_STRINGIFY_FETCHES], $options[\PDO::ATTR_CASE]);
        return [$kind, $dsn, $db->username === null ? null : (string) $db->username, $db->password === null ? null : (string) $db->password, $options];
    }

    /** Drops the three tables (the plugin's uninstall). */
    public static function drop(?Connection $db = null): void
    {
        $db ??= self::db();
        $prefix = self::prefix($db);
        foreach (['runs', 'state', 'jobs'] as $table) {
            $db->createCommand("DROP TABLE IF EXISTS {$prefix}{$table}")->execute();
        }
    }
}
