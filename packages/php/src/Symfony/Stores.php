<?php

declare(strict_types=1);

namespace Cronwatch\Symfony;

use Cronwatch\Store\MemoryStore;
use Cronwatch\Store\MysqlStore;
use Cronwatch\Store\PostgresStore;
use Cronwatch\Store\SqliteStore;
use Cronwatch\Store\Store;

/**
 * A store from a URL written as Doctrine writes one, so the app's
 * DATABASE_URL works as it is: `mysql://` (and `mariadb://`,
 * `pdo-mysql://`), `postgresql://` (and `postgres://`, `pgsql://`,
 * `pdo-pgsql://`), `sqlite:///<absolute path>` (and `sqlite:///:memory:`),
 * or `memory`. Doctrine's own query parameters (serverVersion, charset for
 * Postgres) are left out; the rest go to the driver as the stores take
 * them. The store opens a connection of its own, so its writes never join
 * a transaction the app has open.
 */
final class Stores
{
    public static function fromUrl(string $url, string $prefix = 'cronwatch_'): Store
    {
        $url = trim($url);
        if ($url === 'memory' || $url === 'memory://') {
            return new MemoryStore();
        }
        if (preg_match('#^(?:pdo-)?sqlite3?://(.*)$#i', $url, $m) === 1) {
            $path = explode('?', $m[1], 2)[0];
            $path = $path === '/:memory:' || $path === ':memory:' ? ':memory:' : rawurldecode($path);
            if ($path === '') {
                throw new \InvalidArgumentException('a sqlite:// store URL needs a path: sqlite:///var/lib/app/cronwatch.db');
            }
            return new SqliteStore($path, prefix: $prefix);
        }
        if (preg_match('#^(?:pdo-)?(mysql|mariadb|mysql2)://#i', $url) === 1) {
            return new MysqlStore(self::withoutParams((string) preg_replace('#^[^:]+://#', 'mysql://', $url), ['serverVersion']), prefix: $prefix);
        }
        if (preg_match('#^(?:pdo-)?(postgres|postgresql|pgsql)://#i', $url) === 1) {
            return new PostgresStore(self::withoutParams((string) preg_replace('#^[^:]+://#', 'postgres://', $url), ['serverVersion', 'charset']), prefix: $prefix);
        }
        if (str_starts_with($url, '/')) {
            return new SqliteStore($url, prefix: $prefix);
        }
        $scheme = preg_match('#^([A-Za-z][A-Za-z0-9+.\-]*):#', $url, $m) === 1 ? $m[1] : 'this';
        throw new \InvalidArgumentException("CronWatch stores in MySQL, MariaDB, Postgres or SQLite; a {$scheme} URL is not one of them");
    }

    /** @param list<string> $names */
    private static function withoutParams(string $url, array $names): string
    {
        $parts = explode('?', $url, 2);
        if (count($parts) === 1) {
            return $url;
        }
        $kept = array_filter(explode('&', $parts[1]), function (string $pair) use ($names): bool {
            $key = rawurldecode(explode('=', $pair, 2)[0]);
            return $pair !== '' && !in_array($key, $names, true);
        });
        return $kept === [] ? $parts[0] : $parts[0] . '?' . implode('&', $kept);
    }
}
