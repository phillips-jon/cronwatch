<?php

declare(strict_types=1);

namespace Cronwatch\Store;

use Cronwatch\JobState;

/**
 * Keeps everything in one SQLite file through PDO (stores/sqlite.ts): the
 * same tables, statements and JSON as the SDK's store, so a Node, a Python
 * and a PHP process can share the file. WAL mode, so the app's reads never
 * block on a run being written. The right choice for a single server.
 *
 *     new SqliteStore('/var/lib/app/cronwatch.db')
 *     new SqliteStore(pdo: $pdo)          // an open connection of your own
 *
 * The directory is created when missing and the file made private (0600).
 * ":memory:" works too. `prefix` names the tables: lowercase letters, digits
 * and underscores, default "cronwatch_".
 */
final class SqliteStore extends PdoStore
{
    /** How long opening SQLite keeps retrying a busy database before it gives up. */
    public const BUSY_RETRY_MS = 2_000;

    public function __construct(
        public readonly string $path = './data/cronwatch.db',
        ?\PDO $pdo = null,
        string $prefix = Sql::DEFAULT_PREFIX,
    ) {
        if (!extension_loaded('pdo_sqlite')) {
            throw new \LogicException('SqliteStore needs the pdo_sqlite extension');
        }
        parent::__construct($prefix, 'sqlite', $pdo, $pdo === null);
    }

    protected function open(): \PDO
    {
        if ($this->db !== null) {
            return $this->db;
        }
        $file = $this->path;
        if ($file !== ':memory:' && $file !== '') {
            $dir = dirname($file);
            if (!is_dir($dir)) {
                @mkdir($dir, 0777, true);
            }
            // Create the file private before SQLite opens it. SQLite gives the
            // -wal and -shm files the main file's mode, so the whole set stays
            // 0600; the chmods cover files left by an earlier open.
            $handle = @fopen($file, 'a');
            if ($handle !== false) {
                fclose($handle);
                foreach ([$file, "{$file}-wal", "{$file}-shm"] as $f) {
                    if (file_exists($f)) {
                        @chmod($f, 0600);
                    }
                }
            }
        }
        // No busy handler until WAL is on: switching journal mode can answer
        // SQLITE_BUSY at once while another process is doing the same on a new
        // file, so that is retried here. The connection is kept only once every
        // pragma has gone through; a failed open is tried afresh next time.
        $opened = new \PDO('sqlite:' . $file, null, null, [\PDO::ATTR_ERRMODE => \PDO::ERRMODE_EXCEPTION, \PDO::ATTR_TIMEOUT => 0]);
        self::retryBusy(fn () => $opened->query('PRAGMA journal_mode = WAL')->fetchAll());
        $opened->exec('PRAGMA busy_timeout = 5000');
        $opened->exec('PRAGMA synchronous = NORMAL');
        $this->forgetStatements();
        return $this->db = $opened;
    }

    /** Whether SQLite answered SQLITE_BUSY or SQLITE_LOCKED (codes 5 and 6, and their extended codes). */
    public static function isBusy(\Throwable $error): bool
    {
        if (!$error instanceof \PDOException) {
            return false;
        }
        $code = $error->errorInfo[1] ?? null;
        if (is_int($code)) {
            return in_array($code & 0xFF, [5, 6], true);
        }
        return str_contains($error->getMessage(), 'database is locked') || str_contains($error->getMessage(), 'database table is locked');
    }

    /**
     * Runs `fn`, retrying while SQLite answers SQLITE_BUSY (or SQLITE_LOCKED),
     * with a short growing pause, for up to `budgetMs` in all.
     *
     * @template T
     * @param callable(): T $fn
     * @param (callable(int): void)|null $sleep
     * @return T
     */
    public static function retryBusy(callable $fn, int $budgetMs = self::BUSY_RETRY_MS, ?callable $sleep = null): mixed
    {
        $sleep ??= fn (int $ms) => usleep($ms * 1000);
        $waited = 0;
        for ($attempt = 0; ; $attempt++) {
            try {
                return $fn();
            } catch (\Throwable $error) {
                if (!self::isBusy($error) || $waited >= $budgetMs) {
                    throw $error;
                }
                $pause = min(10 * 2 ** $attempt, 200, $budgetMs - $waited);
                $sleep($pause);
                $waited += $pause;
            }
        }
    }

    /**
     * A statement, tried again while SQLite answers busy, outside a
     * transaction. The busy timeout waits out another writer, but not a
     * snapshot another process's write made stale between a statement's read
     * and its write (SQLITE_BUSY_SNAPSHOT), which one retry of that one
     * statement settles.
     */
    protected function run(string $text, array $params = []): \PDOStatement
    {
        if ($this->db?->inTransaction()) {
            return parent::run($text, $params);
        }
        return self::retryBusy(fn () => parent::run($text, $params));
    }

    public function init(): void
    {
        $this->open()->exec(Sql::sqliteSchema($this->prefix));
    }

    public function compareAndSetState(JobState $state, int|float $expectedVersion): bool
    {
        $statement = $expectedVersion == 0
            ? $this->run($this->sql['casInsert'], Sql::stateParams($state))
            : $this->run($this->sql['casUpdate'], Sql::casUpdateParams($state, $expectedVersion));
        return $statement->rowCount() > 0;
    }
}
