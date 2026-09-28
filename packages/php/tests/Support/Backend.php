<?php

declare(strict_types=1);

namespace Cronwatch\Tests\Support;

use Cronwatch\Store\MemoryStore;
use Cronwatch\Store\MysqlStore;
use Cronwatch\Store\SqliteStore;
use Cronwatch\Store\Store;

/**
 * One database for a test, and as many stores over it as the test wants,
 * as several processes would have. SQLite is a file in a temporary
 * directory; MySQL and MariaDB are servers named by CRONWATCH_TEST_MYSQL and
 * CRONWATCH_TEST_MARIADB (mysql:// URLs), with tables under a prefix of
 * their own that done() drops.
 */
final class Backend
{
    /** @var list<Store> */
    private array $opened = [];
    private ?MemoryStore $memory = null;
    private ?string $dir = null;
    public readonly string $prefix;

    private function __construct(public readonly string $kind, public readonly ?string $url)
    {
        $this->prefix = 't' . getmypid() . '_' . random_int(0, 999_999) . '_';
        if ($kind === 'sqlite') {
            $this->dir = sys_get_temp_dir() . '/cronwatch-php-' . getmypid() . '-' . bin2hex(random_bytes(4));
            mkdir($this->dir, 0777, true);
        }
    }

    /** The environment variable naming a server for this kind, or null for one that needs none. */
    public static function variable(string $kind): ?string
    {
        return ['mysql' => 'CRONWATCH_TEST_MYSQL', 'mariadb' => 'CRONWATCH_TEST_MARIADB'][$kind] ?? null;
    }

    /** Why this kind cannot run here, or null when it can. */
    public static function unavailable(string $kind): ?string
    {
        $variable = self::variable($kind);
        if ($variable !== null && (getenv($variable) === false || getenv($variable) === '')) {
            return "set {$variable} to a mysql:// URL to run";
        }
        if ($kind === 'sqlite' && !extension_loaded('pdo_sqlite')) {
            return 'needs pdo_sqlite';
        }
        if ($variable !== null && !extension_loaded('pdo_mysql')) {
            return 'needs pdo_mysql';
        }
        return null;
    }

    public static function make(string $kind): self
    {
        $variable = self::variable($kind);
        return new self($kind, $variable === null ? null : (string) getenv($variable));
    }

    /** A store over this backend's database, as another process would open one. */
    public function open(): Store
    {
        $store = match ($this->kind) {
            'memory' => $this->memory ??= new MemoryStore(),
            'sqlite' => new SqliteStore("{$this->dir}/cw.db"),
            default => new MysqlStore($this->url, prefix: $this->prefix),
        };
        $this->opened[] = $store;
        return $store;
    }

    /** What a worker process needs to open the same store (see tests/workers/worker.php). */
    public function spec(): array
    {
        return match ($this->kind) {
            'sqlite' => ['kind' => 'sqlite', 'path' => "{$this->dir}/cw.db"],
            default => ['kind' => 'mysql', 'url' => $this->url, 'prefix' => $this->prefix],
        };
    }

    public function path(string $name): string
    {
        return "{$this->dir}/{$name}";
    }

    public function done(): void
    {
        foreach ($this->opened as $store) {
            $store->close();
        }
        if ($this->kind === 'sqlite' && $this->dir !== null) {
            foreach (glob("{$this->dir}/*") ?: [] as $file) {
                @unlink($file);
            }
            @rmdir($this->dir);
        }
        if ($this->url !== null) {
            self::dropTables($this->url, $this->prefix);
        }
    }

    public static function dropTables(string $url, string $prefix): void
    {
        [$dsn, $user, $password] = MysqlStore::connection($url);
        $pdo = new \PDO($dsn, $user, $password, [\PDO::ATTR_ERRMODE => \PDO::ERRMODE_EXCEPTION]);
        $pdo->exec("DROP TABLE IF EXISTS {$prefix}jobs, {$prefix}runs, {$prefix}state");
    }
}
