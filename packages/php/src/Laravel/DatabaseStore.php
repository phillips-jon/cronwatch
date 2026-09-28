<?php

declare(strict_types=1);

namespace Cronwatch\Laravel;

use Cronwatch\Store\MysqlStore;
use Cronwatch\Store\PdoStore;
use Cronwatch\Store\PostgresStore;
use Cronwatch\Store\SqliteStore;
use Illuminate\Database\ConnectionResolverInterface;

/**
 * A store in the app's database, made from one of config/database.php's
 * connections: MySQL and MariaDB (MysqlStore), Postgres (PostgresStore) or
 * SQLite (SqliteStore). It reads the connection's settings (host, port,
 * database, credentials, socket, SSL and other PDO options, Postgres's
 * sslmode and search_path, the write side of a read/write split) and opens
 * a connection of its own with them, so CronWatch's writes never join a
 * transaction the app has open: a run recorded inside one survives its
 * rollback, as in every port. An in-memory SQLite database (":memory:", as
 * tests use) cannot be opened twice, so that one is shared.
 *
 * The tables are CronWatch's own names (the prefix, "cronwatch_" by
 * default); the connection's table prefix does not apply to them.
 */
final class DatabaseStore
{
    /** Postgres connection settings passed on to libpq as they are. */
    private const PGSQL_KEYS = ['sslmode', 'sslcert', 'sslkey', 'sslrootcert', 'sslcrl', 'application_name', 'connect_timeout'];

    public static function make(ConnectionResolverInterface $db, ?string $connection, string $prefix): PdoStore
    {
        $name = $connection ?? $db->getDefaultConnection();
        $laravel = $db->connection($name);
        $config = self::writeConfig($laravel->getConfig());
        $driver = (string) ($config['driver'] ?? '');
        return match ($driver) {
            'sqlite' => self::sqlite($laravel, $config, $prefix),
            'mysql', 'mariadb' => new MysqlStore(self::mysqlDsn($config), self::text($config['username'] ?? null), self::text($config['password'] ?? null), prefix: $prefix, options: self::options($config)),
            'pgsql' => new PostgresStore(self::pgsqlDsn($config), self::text($config['username'] ?? null), self::text($config['password'] ?? null), prefix: $prefix, options: self::options($config)),
            default => throw new \InvalidArgumentException("CronWatch keeps its tables in MySQL, MariaDB, Postgres or SQLite; the {$name} connection is {$driver}. Set cronwatch.store.connection to another connection, or cronwatch.store.driver to sqlite."),
        };
    }

    /**
     * The settings the write side of a connection uses: the base settings
     * with its "write" ones on top, the first host of a list.
     *
     * @param array<string, mixed> $config
     * @return array<string, mixed>
     */
    public static function writeConfig(array $config): array
    {
        $write = $config['write'] ?? [];
        unset($config['read'], $config['write']);
        if (is_array($write)) {
            $config = array_replace($config, array_is_list($write) ? ($write[0] ?? []) : $write);
        }
        if (is_array($config['host'] ?? null)) {
            $config['host'] = $config['host'][0] ?? null;
        }
        return $config;
    }

    /** @param array<string, mixed> $config */
    private static function sqlite(object $laravel, array $config, string $prefix): SqliteStore
    {
        $path = (string) ($config['database'] ?? '');
        if ($path === ':memory:' || $path === '' || str_contains($path, 'mode=memory')) {
            return new SqliteStore(pdo: $laravel->getPdo(), prefix: $prefix);
        }
        return new SqliteStore($path, prefix: $prefix);
    }

    /** @param array<string, mixed> $config */
    public static function mysqlDsn(array $config): string
    {
        // A value holding ";" would end its DSN field and start another.
        $field = function (mixed $value): ?string {
            $text = self::text($value);
            if ($text !== null && str_contains($text, ';')) {
                throw new \InvalidArgumentException('CronWatch cannot put a host, port, socket or database name holding ";" in a DSN');
            }
            return $text;
        };
        $socket = $field($config['unix_socket'] ?? null);
        $port = $field($config['port'] ?? null);
        $dsn = 'mysql:' . ($socket !== null && $socket !== ''
            ? "unix_socket={$socket}"
            : 'host=' . ($field($config['host'] ?? null) ?? '127.0.0.1') . ($port !== null && $port !== '' ? ";port={$port}" : ''));
        $database = $field($config['database'] ?? null);
        if ($database !== null && $database !== '') {
            $dsn .= ";dbname={$database}";
        }
        // The tables are utf8mb4 whatever the app's connection uses.
        return "{$dsn};charset=utf8mb4";
    }

    /** @param array<string, mixed> $config */
    public static function pgsqlDsn(array $config): string
    {
        $fields = [];
        $host = self::text($config['host'] ?? null);
        if ($host !== null && $host !== '') {
            $fields['host'] = $host;
        }
        if (isset($config['port']) && $config['port'] !== '') {
            $fields['port'] = (string) $config['port'];
        }
        $database = self::text($config['database'] ?? null);
        if ($database !== null && $database !== '') {
            $fields['dbname'] = $database;
        }
        foreach (self::PGSQL_KEYS as $key) {
            $value = self::text($config[$key] ?? null);
            if ($value !== null && $value !== '') {
                $fields[$key] = $value;
            }
        }
        // The schema the app's tables are in (Laravel's search_path, once "schema").
        $path = $config['search_path'] ?? $config['schema'] ?? null;
        $schemas = is_array($path) ? $path : (is_string($path) ? preg_split('/\s*,\s*/', trim($path)) : []);
        $schemas = array_values(array_filter(array_map(fn ($s) => (string) preg_replace('/[^A-Za-z0-9_$]/', '', (string) $s), (array) $schemas), fn (string $s) => $s !== ''));
        if ($schemas !== [] && $schemas !== ['public']) {
            $fields['options'] = '--search_path=' . implode(',', $schemas);
        }
        return PostgresStore::dsn($fields);
    }

    /**
     * PDO attributes from the connection's "options" (SSL and the like).
     *
     * @param array<string, mixed> $config
     * @return array<int, mixed>
     */
    private static function options(array $config): array
    {
        $options = [];
        foreach ((array) ($config['options'] ?? []) as $key => $value) {
            if (is_int($key) && $value !== null) {
                $options[$key] = $value;
            }
        }
        // The store's own connection keeps its own error mode and prepares.
        unset($options[\PDO::ATTR_ERRMODE], $options[\PDO::ATTR_EMULATE_PREPARES], $options[\PDO::ATTR_STRINGIFY_FETCHES], $options[\PDO::ATTR_CASE]);
        return $options;
    }

    private static function text(mixed $value): ?string
    {
        return is_scalar($value) ? (string) $value : null;
    }
}
