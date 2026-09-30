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
    /** @var array<int, mixed> the PDO attributes the URL's TLS parameters ask for */
    private readonly array $tls;

    /** @param array<int, mixed> $options more PDO attributes for a connection of its own */
    public function __construct(
        #[\SensitiveParameter] ?string $url = null,
        ?string $username = null,
        #[\SensitiveParameter] ?string $password = null,
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
            $this->tls = [];
            return;
        }
        $url ??= self::databaseUrl();
        if ($url === null) {
            throw new \InvalidArgumentException('MysqlStore needs a mysql:// URL, a PDO DSN or a PDO (or DATABASE_URL set to a mysql:// URL)');
        }
        [$this->dsn, $this->username, $this->password] = self::connection($url, $username, $password);
        $this->tls = self::urlOptions($url);
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
    public static function connection(#[\SensitiveParameter] string $url, ?string $username = null, #[\SensitiveParameter] ?string $password = null): array
    {
        if (preg_match('/^mysql:/i', $url) === 1 && !str_starts_with(strtolower($url), 'mysql://')) {
            $dsn = stripos($url, 'charset=') === false ? rtrim($url, ';') . ';charset=utf8mb4' : $url;
            return [$dsn, $username, $password];
        }
        $parts = parse_url($url);
        if ($parts === false || !isset($parts['scheme']) || !in_array(strtolower($parts['scheme']), ['mysql', 'mariadb'], true)) {
            throw new \InvalidArgumentException('MysqlStore takes a mysql:// or mariadb:// URL, or a PDO DSN starting mysql:');
        }
        $query = self::query($parts['query'] ?? '');
        // A value holding ";" would end its DSN field and start another.
        $field = function (string $name, string $value): string {
            if (str_contains($value, ';')) {
                throw new \InvalidArgumentException("MysqlStore cannot put a {$name} holding \";\" in a DSN");
            }
            return $value;
        };
        $dsn = 'mysql:';
        if (isset($query['unix_socket'])) {
            $dsn .= 'unix_socket=' . $field('unix_socket', $query['unix_socket']);
        } else {
            $dsn .= 'host=' . $field('host', $parts['host'] ?? '127.0.0.1') . (isset($parts['port']) ? ';port=' . $parts['port'] : '');
        }
        $database = ltrim(rawurldecode($parts['path'] ?? ''), '/');
        if ($database !== '') {
            $dsn .= ';dbname=' . $field('database name', $database);
        }
        $dsn .= ';charset=' . $field('charset', $query['charset'] ?? 'utf8mb4');
        return [
            $dsn,
            $username ?? (isset($parts['user']) ? rawurldecode($parts['user']) : null),
            $password ?? (isset($parts['pass']) ? rawurldecode($parts['pass']) : null),
        ];
    }

    /**
     * The PDO attributes a mysql:// URL's TLS parameters ask for, so a URL
     * that asks for TLS never connects without it:
     *
     * - `ssl-mode` (or `sslmode`): DISABLED or PREFERRED ask for nothing;
     *   REQUIRED is TLS without checking the server's certificate;
     *   VERIFY_CA and VERIFY_IDENTITY check it. TLS without `ssl-ca` uses
     *   OpenSSL's default CA file.
     * - `ssl-ca` (`sslca`, `sslrootcert`), `ssl-cert` (`sslcert`), `ssl-key`
     *   (`sslkey`): files, which turn TLS on. A CA with no mode checks the
     *   server's certificate against it (as VERIFY_CA).
     *
     * Doctrine's `serverVersion` is ignored; any other parameter is refused,
     * rather than dropped without a word. A DSN (mysql:host=...) has none.
     *
     * @return array<int, mixed>
     */
    public static function urlOptions(string $url): array
    {
        if (!str_starts_with(strtolower($url), 'mysql://') && !str_starts_with(strtolower($url), 'mariadb://')) {
            return [];
        }
        $parts = parse_url($url);
        $query = self::query(is_array($parts) ? ($parts['query'] ?? '') : '');
        $files = ['ssl-ca' => 'SSL_CA', 'sslca' => 'SSL_CA', 'sslrootcert' => 'SSL_CA', 'ssl-cert' => 'SSL_CERT', 'sslcert' => 'SSL_CERT', 'ssl-key' => 'SSL_KEY', 'sslkey' => 'SSL_KEY'];
        $options = [];
        $mode = null;
        foreach ($query as $key => $value) {
            $lower = strtolower($key);
            if (in_array($lower, ['unix_socket', 'charset', 'serverversion'], true)) {
                continue;
            }
            if ($lower === 'ssl-mode' || $lower === 'sslmode') {
                $mode = strtoupper(str_replace('-', '_', $value));
                if (!in_array($mode, ['DISABLED', 'PREFERRED', 'REQUIRED', 'VERIFY_CA', 'VERIFY_IDENTITY', 'REQUIRE', 'DISABLE', 'PREFER', 'VERIFY_FULL'], true)) {
                    throw new \InvalidArgumentException("MysqlStore does not know the ssl-mode {$value}: DISABLED, PREFERRED, REQUIRED, VERIFY_CA or VERIFY_IDENTITY");
                }
                continue;
            }
            if (isset($files[$lower])) {
                $options[self::attribute($files[$lower])] = $value;
                continue;
            }
            throw new \InvalidArgumentException("MysqlStore does not know the URL parameter {$key}: give PDO attributes as options: instead");
        }
        $mode = match ($mode) {
            'REQUIRE' => 'REQUIRED',
            'DISABLE' => 'DISABLED',
            'PREFER' => 'PREFERRED',
            'VERIFY_FULL' => 'VERIFY_IDENTITY',
            default => $mode,
        };
        if ($mode === 'DISABLED') {
            return [];
        }
        $tls = $options !== [] || in_array($mode, ['REQUIRED', 'VERIFY_CA', 'VERIFY_IDENTITY'], true);
        if ($tls && !isset($options[self::attribute('SSL_CA')]) && in_array($mode, ['REQUIRED', 'VERIFY_CA', 'VERIFY_IDENTITY'], true)) {
            $default = function_exists('openssl_get_cert_locations') ? (openssl_get_cert_locations()['default_cert_file'] ?? '') : '';
            if ($default === '' || !is_readable($default)) {
                throw new \InvalidArgumentException("MysqlStore needs ssl-ca for ssl-mode {$mode}: OpenSSL has no default CA file here");
            }
            $options[self::attribute('SSL_CA')] = $default;
        }
        if ($tls) {
            // A CA given with no mode is checked against, as PHP and MySQL's
            // own client do; only REQUIRED or PREFERRED, said outright, skip the check.
            $verify = in_array($mode, ['VERIFY_CA', 'VERIFY_IDENTITY'], true) || ($mode === null && isset($options[self::attribute('SSL_CA')]));
            $options[self::attribute('SSL_VERIFY_SERVER_CERT')] = $verify;
        }
        return $options;
    }

    /** A pdo_mysql attribute by name, from Pdo\Mysql on PHP 8.4 and newer (8.5 deprecates PDO::MYSQL_ATTR_*). */
    private static function attribute(string $name): int
    {
        return (int) constant(\PHP_VERSION_ID >= 80400 ? "Pdo\\Mysql::ATTR_{$name}" : "PDO::MYSQL_ATTR_{$name}");
    }

    /** @return array<string, string> a URL's query parameters that have a text value */
    private static function query(string $text): array
    {
        $query = [];
        parse_str($text, $query);
        return array_filter($query, 'is_string');
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
        ] + $this->options + $this->tls);
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
            $this->resent = true;
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
        $this->resent = false;
        if ($expectedVersion != 0) {
            return $this->run($this->sql['casUpdate'], Sql::casUpdateParams($state, $expectedVersion))->rowCount() > 0
                || $this->stateLanded($state);
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
            // A row is there, at another version: another process wrote first
            // (or this one did, and the answer was lost with the connection).
            if (($error->errorInfo[1] ?? null) === 1062) {
                return $this->stateLanded($state);
            }
            throw $error;
        }
    }
}
