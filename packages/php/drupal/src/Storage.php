<?php

declare(strict_types=1);

namespace Drupal\cronwatch;

use Cronwatch\Store\MysqlStore;
use Cronwatch\Store\PdoStore;
use Cronwatch\Store\PostgresStore;
use Cronwatch\Store\Sql;
use Cronwatch\Store\SqliteStore;
use Drupal\Core\Database\Database;
use Drupal\Core\Site\Settings;

/**
 * The store in the site's own database.
 *
 * The library's MySQL (and MariaDB), Postgres, or SQLite store, made from the
 * connection settings.php describes ($databases['default']['default'], or
 * the key named by $settings['cronwatch_database']), through a PDO
 * connection of its own. So CronWatch's writes never join a transaction
 * Drupal has open (a run recorded inside one survives its rollback), and its
 * tables are the library's, byte for byte, as every port writes them.
 *
 * The tables are the site's table prefix and "cronwatch_" (cronwatch_jobs,
 * cronwatch_runs, and cronwatch_state on a site without a prefix), made on
 * install with the library's CREATE text and dropped on uninstall.
 */
final class Storage {

  /**
   * Drupal's database drivers the library has a store for.
   */
  public const DRIVERS = [
    'mysql' => 'mysql',
    'mysqli' => 'mysql',
    'pgsql' => 'pgsql',
    'sqlite' => 'sqlite',
  ];

  /**
   * The connection's settings, as settings.php gives them.
   *
   * @return array<string, mixed>
   *   The connection info.
   */
  public static function info(): array {
    $key = Settings::get('cronwatch_database', 'default');
    $key = is_string($key) && $key !== '' ? $key : 'default';
    $info = Database::getConnectionInfo($key);
    if (!is_array($info) || !is_array($info['default'] ?? NULL)) {
      throw new \RuntimeException("CronWatch: settings.php has no database connection \"{$key}\"");
    }
    return $info['default'];
  }

  /**
   * The tables' prefix: the connection's own, lowercased, then "cronwatch_".
   */
  public static function prefix(?array $info = NULL): string {
    $info ??= self::info();
    $prefix = $info['prefix'] ?? '';
    if (is_array($prefix)) {
      // Per-table prefixes, from before Drupal 10: the default one.
      $prefix = $prefix['default'] ?? '';
    }
    return Sql::tablePrefix(strtolower((string) $prefix) . 'cronwatch_');
  }

  /**
   * The library's store for the connection.
   */
  public static function store(?array $info = NULL): PdoStore {
    $info ??= self::info();
    $prefix = self::prefix($info);
    [$kind, $dsn, $username, $password, $options] = self::connection($info);
    return match ($kind) {
      'mysql' => new MysqlStore($dsn, $username, $password, prefix: $prefix, options: $options),
      'pgsql' => new PostgresStore($dsn, $username, $password, prefix: $prefix, options: $options),
      default => new SqliteStore(substr($dsn, strlen('sqlite:')), prefix: $prefix),
    };
  }

  /**
   * The PDO DSN, credentials, and attributes for a connection.
   *
   * @return array{string, string, ?string, ?string, array<int, mixed>}
   *   The kind (mysql, pgsql, or sqlite), the DSN, user, password, and
   *   attributes.
   */
  public static function connection(array $info): array {
    $driver = (string) ($info['driver'] ?? '');
    $kind = self::DRIVERS[$driver] ?? NULL;
    if ($kind === NULL) {
      throw new \RuntimeException("CronWatch keeps its tables in MySQL, MariaDB, Postgres, or SQLite; this site's database driver is {$driver}. Point \$settings['cronwatch_database'] at another connection in settings.php.");
    }
    if ($kind === 'sqlite') {
      $path = (string) ($info['database'] ?? '');
      if ($path === '' || $path === ':memory:') {
        throw new \RuntimeException('CronWatch cannot share an in-memory SQLite database; give the site a database file');
      }
      if (!str_starts_with($path, '/') && preg_match('/^[A-Za-z]:[\\\\\/]/', $path) !== 1) {
        // Drupal opens a relative path from its root, where index.php and
        // Drush run.
        $path = \Drupal::root() . '/' . $path;
      }
      return ['sqlite', "sqlite:{$path}", NULL, NULL, []];
    }
    $fields = [];
    $socket = self::text($info['unix_socket'] ?? NULL);
    if ($kind === 'mysql' && $socket !== NULL && $socket !== '') {
      $fields['unix_socket'] = $socket;
    }
    else {
      $host = self::text($info['host'] ?? NULL);
      if ($host !== NULL && $host !== '') {
        $fields['host'] = $host;
      }
      $port = self::text($info['port'] ?? NULL);
      if ($port !== NULL && $port !== '') {
        $fields['port'] = $port;
      }
    }
    $database = self::text($info['database'] ?? NULL);
    if ($database !== NULL && $database !== '') {
      $fields['dbname'] = $database;
    }
    if ($kind === 'mysql') {
      // The tables are utf8mb4 whatever the site's connection uses.
      $fields['charset'] = 'utf8mb4';
    }
    $dsn = $kind . ':' . implode(';', array_map(fn (string $k, string $v) => "{$k}={$v}", array_keys($fields), $fields));
    return [
      $kind,
      $dsn,
      self::text($info['username'] ?? NULL),
      self::text($info['password'] ?? NULL),
      self::options($info),
    ];
  }

  /**
   * A connection of its own to the same database, for dropping the tables.
   */
  public static function pdo(?array $info = NULL): \PDO {
    $info ??= self::info();
    [, $dsn, $username, $password, $options] = self::connection($info);
    return new \PDO($dsn, $username, $password, [\PDO::ATTR_ERRMODE => \PDO::ERRMODE_EXCEPTION] + $options);
  }

  /**
   * Drops the three tables, for the module's uninstall.
   */
  public static function drop(): void {
    $info = self::info();
    $prefix = self::prefix($info);
    $pdo = self::pdo($info);
    foreach (['runs', 'state', 'jobs'] as $table) {
      $pdo->exec("DROP TABLE IF EXISTS {$prefix}{$table}");
    }
  }

  /**
   * PDO attributes from the connection's "pdo" settings (SSL and the like).
   *
   * @return array<int, mixed>
   *   The attributes, without the ones the store sets itself.
   */
  private static function options(array $info): array {
    $options = [];
    foreach ((array) ($info['pdo'] ?? []) as $key => $value) {
      if (is_int($key) && $value !== NULL) {
        $options[$key] = $value;
      }
    }
    unset(
      $options[\PDO::ATTR_ERRMODE],
      $options[\PDO::ATTR_EMULATE_PREPARES],
      $options[\PDO::ATTR_STRINGIFY_FETCHES],
      $options[\PDO::ATTR_CASE],
      $options[\PDO::ATTR_STATEMENT_CLASS],
    );
    return $options;
  }

  /**
   * A scalar setting as text.
   */
  private static function text(mixed $value): ?string {
    return is_scalar($value) ? (string) $value : NULL;
  }

}
