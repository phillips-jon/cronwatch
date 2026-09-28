<?php

declare(strict_types=1);

namespace Cronwatch\Store;

use Cronwatch\Env;
use Cronwatch\JobState;

/**
 * Keeps everything in MySQL (8.0.13 or newer) or MariaDB (10.6 or newer), through PDO. The
 * same three tables as the SDK's SQL stores, in MySQL's dialect (see
 * Sql::mysqlSchema()), with the SDK's JSON held as text byte for byte.
 *
 *     new MysqlStore('mysql://user:password@db.internal:3306/app')
 *     new MysqlStore('mysql:host=127.0.0.1;dbname=app', 'user', 'password')
 *     new MysqlStore(pdo: $pdo)            // the app's connection
 *     new MysqlStore()                     // reads DATABASE_URL (mysql:// or mariadb://)
 *
 * Given a URL or DSN it opens a connection of its own, utf8mb4, in
 * autocommit mode, so its writes never join a transaction the app has open
 * (a run recorded inside one survives a rollback), and it connects again
 * once when the server has gone away. Given the app's PDO it shares it,
 * transactions and all. init() runs CREATE TABLE, which MySQL commits at
 * once, so call it when nothing is open (a deploy step, or the first check).
 */
final class MysqlStore extends PdoStore
{
    private readonly ?string $dsn;
    private readonly ?string $username;
    private readonly ?string $password;

    /** @param array<int, mixed> $options more PDO attributes for a connection of its own */
    public function __construct(
        ?string $url = null,
        ?string $username = null,
        ?string $password = null,
        ?\PDO $pdo = null,
        string $prefix = Sql::DEFAULT_PREFIX,
        private readonly array $options = [],
    ) {
        if (!extension_loaded('pdo_mysql')) {
            throw new \LogicException('MysqlStore needs the pdo_mysql extension');
        }
        parent::__construct($prefix, 'mysql', $pdo, $pdo === null);
        if ($pdo !== null) {
            $this->dsn = $this->username = $this->password = null;
            return;
        }
        $url ??= self::databaseUrl();
        if ($url === null) {
            throw new \InvalidArgumentException('MysqlStore needs a mysql:// URL, a PDO DSN or a PDO (or DATABASE_URL set to a mysql:// URL)');
        }
        [$this->dsn, $this->username, $this->password] = self::connection($url, $username, $password);
    }

    /** DATABASE_URL, when it names MySQL or MariaDB. */
    private static function databaseUrl(): ?string
    {
        $url = Env::read('DATABASE_URL');
        return $url !== null && preg_match('/^(mysql|mariadb):\/\//i', $url) === 1 ? $url : null;
    }

    /**
     * A PDO DSN, user and password from a mysql:// (or mariadb://) URL, or a
     * DSN passed through with utf8mb4 added when it names no charset.
     *
     * @return array{string, ?string, ?string}
     */
    public static function connection(string $url, ?string $username = null, ?string $password = null): array
    {
        if (preg_match('/^mysql:/i', $url) === 1 && !str_starts_with(strtolower($url), 'mysql://')) {
            $dsn = stripos($url, 'charset=') === false ? rtrim($url, ';') . ';charset=utf8mb4' : $url;
            return [$dsn, $username, $password];
        }
        $parts = parse_url($url);
        if ($parts === false || !isset($parts['scheme']) || !in_array(strtolower($parts['scheme']), ['mysql', 'mariadb'], true)) {
            throw new \InvalidArgumentException('MysqlStore takes a mysql:// or mariadb:// URL, or a PDO DSN starting mysql:');
        }
        $query = [];
        parse_str($parts['query'] ?? '', $query);
        $dsn = 'mysql:';
        if (isset($query['unix_socket']) && is_string($query['unix_socket'])) {
            $dsn .= 'unix_socket=' . $query['unix_socket'];
        } else {
            $dsn .= 'host=' . ($parts['host'] ?? '127.0.0.1') . (isset($parts['port']) ? ';port=' . $parts['port'] : '');
        }
        $database = ltrim(rawurldecode($parts['path'] ?? ''), '/');
        if ($database !== '') {
            $dsn .= ';dbname=' . $database;
        }
        $dsn .= ';charset=' . (is_string($query['charset'] ?? null) ? $query['charset'] : 'utf8mb4');
        return [
            $dsn,
            $username ?? (isset($parts['user']) ? rawurldecode($parts['user']) : null),
            $password ?? (isset($parts['pass']) ? rawurldecode($parts['pass']) : null),
        ];
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

    /** A statement, sent again once on a connection of its own opened afresh when the server had gone away (errors 2006 and 2013). */
    protected function run(string $text, array $params = []): \PDOStatement
    {
        try {
            return parent::run($text, $params);
        } catch (\PDOException $error) {
            $code = $error->errorInfo[1] ?? null;
            if (!$this->own || !in_array($code, [2006, 2013], true) || ($this->db?->inTransaction() ?? false)) {
                throw $error;
            }
            $this->db = null;
            return parent::run($text, $params);
        }
    }

    public function init(): void
    {
        foreach (Sql::mysqlSchema($this->prefix) as $statement) {
            $this->open()->exec($statement);
        }
    }

    public function compareAndSetState(JobState $state, int|float $expectedVersion): bool
    {
        if ($expectedVersion != 0) {
            return $this->run($this->sql['casUpdate'], Sql::casUpdateParams($state, $expectedVersion))->rowCount() > 0;
        }
        // Version 0 is a row at version 0 (or with none), or no row at all.
        [$job, $json] = Sql::stateParams($state);
        if ($this->run($this->sql['casFromZero'], [$json, $job])->rowCount() > 0) {
            return true;
        }
        try {
            $this->run($this->sql['casInsert'], [$job, $json]);
            return true;
        } catch (\PDOException $error) {
            // A row is there, at another version: another process wrote first.
            if (($error->errorInfo[1] ?? null) === 1062) {
                return false;
            }
            throw $error;
        }
    }
}
