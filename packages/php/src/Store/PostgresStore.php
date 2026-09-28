<?php

declare(strict_types=1);

namespace Cronwatch\Store;

use Cronwatch\Env;
use Cronwatch\JobState;

/**
 * Keeps everything in Postgres through PDO (stores/postgres.ts): the same
 * tables, statements and JSON as the SDK's store, so a Node, a Ruby, a
 * Python and a PHP process can share the database. For apps on Heroku,
 * Laravel Cloud, Fly, Neon, Supabase and the like, where there is no disk to
 * keep a SQLite file on. Times are stored as BIGINT epoch milliseconds.
 *
 *     new PostgresStore('postgres://user:password@db.internal:5432/app?sslmode=require')
 *     new PostgresStore('pgsql:host=127.0.0.1;dbname=app', 'user', 'password')
 *     new PostgresStore(pdo: $pdo)         // the app's connection
 *     new PostgresStore()                  // reads DATABASE_URL (postgres:// or postgresql://)
 *
 * Given a URL or DSN it opens a connection of its own, in autocommit mode,
 * so its writes never join a transaction the app has open (a run recorded
 * inside one survives a rollback, and a check waiting on a job's row cannot
 * deadlock with a job holding it), and it connects again once when the
 * connection broke outside a transaction. Given the app's PDO it shares it,
 * transactions and all.
 */
final class PostgresStore extends PdoStore
{
    private readonly ?string $dsn;
    private readonly ?string $username;
    private readonly ?string $password;
    /** Whether a transaction this store opened is under way, when a statement must not be sent again elsewhere. */
    private bool $transacting = false;

    /** @param array<int, mixed> $options more PDO attributes for a connection of its own */
    public function __construct(
        #[\SensitiveParameter] ?string $url = null,
        ?string $username = null,
        #[\SensitiveParameter] ?string $password = null,
        ?\PDO $pdo = null,
        string $prefix = Sql::DEFAULT_PREFIX,
        private readonly array $options = [],
    ) {
        if (!extension_loaded('pdo_pgsql')) {
            throw new \LogicException('PostgresStore needs the pdo_pgsql extension');
        }
        parent::__construct($prefix, 'postgres', $pdo, $pdo === null);
        if ($pdo !== null) {
            $this->dsn = $this->username = $this->password = null;
            return;
        }
        $url ??= self::databaseUrl();
        if ($url === null) {
            throw new \InvalidArgumentException('PostgresStore needs a postgres:// URL, a PDO DSN or a PDO (or DATABASE_URL set to a postgres:// URL)');
        }
        [$this->dsn, $this->username, $this->password] = self::connection($url, $username, $password);
    }

    /** DATABASE_URL, when it names Postgres. */
    private static function databaseUrl(): ?string
    {
        $url = Env::read('DATABASE_URL');
        return $url !== null && preg_match('/^postgres(ql)?:\/\//i', $url) === 1 ? $url : null;
    }

    /**
     * A PDO DSN, user and password from a postgres:// (or postgresql://) URL,
     * its query parameters (sslmode and the rest) passed on as libpq takes
     * them, or a pgsql: DSN passed through.
     *
     * @return array{string, ?string, ?string}
     */
    public static function connection(#[\SensitiveParameter] string $url, ?string $username = null, #[\SensitiveParameter] ?string $password = null): array
    {
        if (preg_match('/^pgsql:/i', $url) === 1) {
            return [$url, $username, $password];
        }
        // parse_url() cannot read a URL with no host (postgres:///app?host=/socket/dir).
        $hostless = preg_match('/^postgres(ql)?:\/\/\//i', $url) === 1;
        $parts = parse_url($hostless ? preg_replace('/:\/\/\//', '://none/', $url, 1) : $url);
        if ($hostless && is_array($parts)) {
            unset($parts['host']);
        }
        if ($parts === false || !isset($parts['scheme']) || !in_array(strtolower($parts['scheme']), ['postgres', 'postgresql'], true)) {
            throw new \InvalidArgumentException('PostgresStore takes a postgres:// or postgresql:// URL, or a PDO DSN starting pgsql:');
        }
        $query = [];
        parse_str($parts['query'] ?? '', $query);
        $fields = [];
        if (isset($parts['host']) && $parts['host'] !== '') {
            $fields['host'] = rawurldecode(trim($parts['host'], '[]'));
        } elseif (isset($query['host']) && is_string($query['host'])) {
            // A socket directory: postgres:///app?host=/var/run/postgresql
            $fields['host'] = $query['host'];
        }
        if (isset($parts['port'])) {
            $fields['port'] = (string) $parts['port'];
        }
        $database = ltrim(rawurldecode($parts['path'] ?? ''), '/');
        if ($database !== '') {
            $fields['dbname'] = $database;
        }
        foreach ($query as $key => $value) {
            if (is_string($value) && $key !== 'host' && preg_match('/^[a-z_]+$/', (string) $key) === 1) {
                $fields[(string) $key] = $value;
            }
        }
        return [
            self::dsn($fields),
            $username ?? (isset($parts['user']) ? rawurldecode($parts['user']) : null),
            $password ?? (isset($parts['pass']) ? rawurldecode($parts['pass']) : null),
        ];
    }

    /**
     * A pgsql: DSN from libpq's keywords, each value quoted as libpq reads
     * one (key='value', with \ and ' escaped), so a space in a value never
     * starts another keyword. A value holding ";" is refused: PDO turns every
     * ";" into a space before libpq reads the string, quotes or not.
     *
     * @param array<string, string> $fields
     */
    public static function dsn(array $fields): string
    {
        $pairs = [];
        foreach ($fields as $key => $value) {
            if (str_contains($value, ';')) {
                throw new \InvalidArgumentException("PostgresStore cannot put a {$key} holding \";\" in a DSN");
            }
            $pairs[] = "{$key}='" . str_replace(['\\', "'"], ['\\\\', "\\'"], $value) . "'";
        }
        return 'pgsql:' . implode(';', $pairs);
    }

    protected function open(): \PDO
    {
        if ($this->db !== null) {
            return $this->db;
        }
        $this->forgetStatements();
        return $this->db = new \PDO((string) $this->dsn, $this->username, $this->password, [
            \PDO::ATTR_ERRMODE => \PDO::ERRMODE_EXCEPTION,
            \PDO::ATTR_EMULATE_PREPARES => false,
            \PDO::ATTR_STRINGIFY_FETCHES => false,
        ] + $this->options);
    }

    /** Whether an error says the connection is gone: SQLSTATE class 08, or the server shutting it (57P01 to 57P03). */
    public static function isDisconnect(\Throwable $error): bool
    {
        if (!$error instanceof \PDOException) {
            return false;
        }
        $state = (string) ($error->errorInfo[0] ?? $error->getCode());
        if (str_starts_with($state, '08') || in_array($state, ['57P01', '57P02', '57P03'], true)) {
            return true;
        }
        // libpq reports a dropped socket without a SQLSTATE of its own.
        return str_contains($error->getMessage(), 'server closed the connection') || str_contains($error->getMessage(), 'no connection to the server');
    }

    /** A statement, sent again once on a connection of its own opened afresh when the old one broke. */
    protected function run(string $text, array $params = []): \PDOStatement
    {
        try {
            return parent::run($text, $params);
        } catch (\PDOException $error) {
            // A broken connection reads as one inside a transaction (libpq's
            // status is unknown), so the store keeps its own count of the
            // transactions it opened; nothing else opens one on its connection.
            if (!$this->own || $this->transacting || !self::isDisconnect($error)) {
                throw $error;
            }
            $this->db = null;
            $this->resent = true;
            return parent::run($text, $params);
        }
    }

    /** Runs a transaction of this store's own, which a broken connection must fail rather than half repeat. */
    private function transacting(\Closure $work): mixed
    {
        $this->transacting = true;
        try {
            return $work();
        } finally {
            $this->transacting = false;
        }
    }

    public function deleteJob(string $name): void
    {
        $this->transacting(fn () => parent::deleteJob($name));
    }

    /**
     * Many instances starting at once would race CREATE TABLE IF NOT EXISTS,
     * which Postgres can reject with a unique violation on pg_type. A lock
     * per prefix makes them take turns. Inside the app's open transaction
     * (a shared PDO), it joins that transaction.
     */
    public function init(): void
    {
        $this->transacting($this->createTables(...));
    }

    private function createTables(): void
    {
        $db = $this->open();
        $own = !$db->inTransaction();
        if ($own) {
            $db->beginTransaction();
        }
        try {
            $this->run('SELECT pg_advisory_xact_lock(hashtext(?))', ["cronwatch:{$this->prefix}"])->closeCursor();
            $db->exec(Sql::postgresSchema($this->prefix));
            if ($own) {
                $db->commit();
            }
        } catch (\Throwable $error) {
            if ($own && $db->inTransaction()) {
                $db->rollBack();
            }
            throw $error;
        }
    }

    public function compareAndSetState(JobState $state, int|float $expectedVersion): bool
    {
        $this->resent = false;
        $statement = $expectedVersion == 0
            ? $this->run($this->sql['casInsert'], Sql::stateParams($state))
            : $this->run($this->sql['casUpdate'], Sql::casUpdateParams($state, $expectedVersion));
        return $statement->rowCount() > 0 || $this->stateLanded($state);
    }
}
