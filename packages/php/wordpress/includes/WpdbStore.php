<?php

declare(strict_types=1);

namespace Cronwatch\WordPress;

\defined('ABSPATH') || exit;

use Cronwatch\JobDefinition;
use Cronwatch\JobState;
use Cronwatch\Js;
use Cronwatch\Run;
use Cronwatch\Store\ComparesAndSetsState;
use Cronwatch\Store\Sql;
use Cronwatch\Store\Store;
use Cronwatch\Store\UpdatesRunIf;
use Cronwatch\StoredJob;

/**
 * Keeps everything in the site's own database through $wpdb: the library's
 * three tables in MySQL's dialect (Sql::mysqlSchema), named with the site's
 * table prefix plus "cronwatch_" (wp_cronwatch_jobs, wp_cronwatch_runs,
 * wp_cronwatch_state), with the same statements, parameters and JSON as
 * MysqlStore, so the stored bytes are the same whichever wrote them.
 *
 * Each statement's values go through $wpdb->prepare() with placeholders,
 * %s for a string and %d for an integer (placeholders()). It shares
 * WordPress's connection.
 */
final class WpdbStore implements Store, UpdatesRunIf, ComparesAndSetsState
{
    /** Bumped when the tables change; kept in the cronwatch_db_version option. */
    public const DB_VERSION = '1';
    public const OPTION = 'cronwatch_db_version';

    public readonly string $prefix;
    /** @var array<string, string> */
    private readonly array $sql;

    public function __construct(private readonly \wpdb $wpdb)
    {
        // WordPress allows capitals in a table prefix, and its tables are named
        // with them as written; the library refuses them only because Postgres
        // would fold them, so here any prefix WordPress takes is kept as it is.
        $prefix = $wpdb->prefix . 'cronwatch_';
        if (preg_match('/^[A-Za-z0-9_]+$/D', $prefix) !== 1 || strlen($prefix) > 64 - strlen('runs_job_started')) {
            throw new \InvalidArgumentException(esc_html("CronWatch cannot name tables with the prefix {$prefix}"));
        }
        $this->prefix = $prefix;
        $this->sql = Sql::statements('mysql', $prefix);
    }

    /** Creates the tables when this version has not yet: CREATE TABLE IF NOT EXISTS, as MysqlStore::init() does. */
    public function init(): void
    {
        if (get_option(self::OPTION) === self::DB_VERSION) {
            return;
        }
        $this->install();
    }

    /** Creates the tables (whatever the option says) and records the version. */
    public function install(): void
    {
        $why = self::unsupported($this->wpdb->db_server_info());
        if ($why !== null) {
            throw new \RuntimeException(esc_html($why));
        }
        foreach (self::schema($this->prefix, $this->wpdb->db_server_info()) as $statement) {
            $this->query($statement);
        }
        update_option(self::OPTION, self::DB_VERSION, true);
    }

    /** Drops the tables, for uninstall. */
    public function drop(): void
    {
        $this->query("DROP TABLE IF EXISTS {$this->prefix}jobs, {$this->prefix}runs, {$this->prefix}state");
        delete_option(self::OPTION);
    }

    /**
     * [name, version] of the server from its version string ("8.4.3",
     * "5.5.5-10.11.8-MariaDB", "10.6.21-MariaDB-log").
     *
     * @return array{string, string}
     */
    public static function server(string $info): array
    {
        if (stripos($info, 'mariadb') !== false) {
            preg_match('/(?:^5\.5\.5-)?([0-9]+\.[0-9]+\.[0-9]+)/', $info, $m);
            return ['MariaDB', $m[1] ?? '0'];
        }
        preg_match('/([0-9]+\.[0-9]+\.[0-9]+)/', $info, $m);
        return ['MySQL', $m[1] ?? '0'];
    }

    /**
     * Why the tables cannot live on this server, or null. JSON_EXTRACT reads
     * a state's version (MySQL 5.7.8, MariaDB 10.2.3), and a VARCHAR(255)
     * utf8mb4 key needs the large index prefixes those servers have on.
     */
    public static function unsupported(string $info): ?string
    {
        [$server, $version] = self::server($info);
        $floor = $server === 'MariaDB' ? '10.3.0' : '5.7.8';
        if (version_compare($version, $floor, '<')) {
            return "CronWatch needs MySQL 5.7.8 or MariaDB 10.3 or newer; this site's database is {$server} {$version}.";
        }
        return null;
    }

    /**
     * Sql::mysqlSchema(), less the one expression default MySQL before 8.0.13
     * cannot take (metrics DEFAULT ('{}')). Every writer supplies metrics, so
     * no stored value differs.
     *
     * @return list<string>
     */
    public static function schema(string $prefix, string $info): array
    {
        [$server, $version] = self::server($info);
        $statements = Sql::mysqlSchema($prefix);
        if ($server === 'MySQL' && version_compare($version, '8.0.13', '<')) {
            $statements = array_map(fn (string $s) => str_replace("metrics LONGTEXT NOT NULL DEFAULT ('{}')", 'metrics LONGTEXT NOT NULL', $s), $statements);
        }
        return $statements;
    }

    // ------------------------------------------------------------ running statements

    /**
     * A statement's text for $wpdb->prepare(), with its arguments: each ?
     * becomes %s (a string) or %d (an integer or a boolean) and its value an
     * argument, as $wpdb->prepare() takes them. A null is written as NULL, and
     * a number that is not a safe integer as its digits (Js::number, the
     * number MysqlStore binds), since prepare() has no placeholder for either
     * that keeps the value: its %f would round to six places.
     *
     * The text is the library's (Sql::statements: fixed text naming this
     * site's cronwatch_ tables, whose prefix the constructor checked). Table
     * names are not placeholders: %i needs WordPress 6.2, and the plugin
     * supports 6.1.
     *
     * @return array{string, list<int|string>}
     */
    private static function placeholders(string $text, array $params): array
    {
        $values = array_values($params);
        $args = [];
        $i = 0;
        $template = (string) preg_replace_callback('/\?/', function () use (&$i, &$args, $values): string {
            $value = $values[$i++] ?? null;
            if (is_float($value) && Js::isInteger($value) && abs($value) <= Js::MAX_SAFE_INTEGER) {
                $value = (int) $value;
            }
            if ($value === null) {
                return 'NULL';
            }
            if (is_bool($value) || is_int($value)) {
                $args[] = (int) $value;
                return '%d';
            }
            if (is_float($value) && is_finite($value)) {
                $digits = Js::number($value);
                if (preg_match('/^-?[0-9]+(\.[0-9]+)?(e[+-]?[0-9]+)?$/D', $digits) !== 1) {
                    throw new \InvalidArgumentException(esc_html("CronWatch cannot store the number {$digits}"));
                }
                return $digits;
            }
            $args[] = (string) $value;
            return '%s';
        }, $text);
        return [$template, $args];
    }

    /**
     * Runs a statement; returns the rows it read, or the rows it changed.
     * Throws with $wpdb's error, which it keeps off the page.
     *
     * Every value goes through $wpdb->prepare(), called here with the
     * statement's placeholders (see placeholders()); a statement with no
     * values (a list, the schema, a transaction) is the library's fixed text.
     * They are on the plugin's own tables, so there is no WordPress API to
     * use instead, and nothing to cache: a run or a state is read to be
     * changed.
     */
    private function query(string $text, array $params = [], bool $select = false): array|int
    {
        [$template, $args] = self::placeholders($text, $params);
        $wpdb = $this->wpdb;
        $suppressed = $wpdb->suppress_errors(true);
        try {
            // phpcs:disable WordPress.DB.PreparedSQL.NotPrepared, WordPress.DB.DirectDatabaseQuery, PluginCheck.Security.DirectDB.UnescapedDBParameter -- the library's statements on the plugin's own tables (see above); every value is a placeholder of $wpdb->prepare().
            if ($select) {
                $rows = $args === []
                    ? $wpdb->get_results($template, ARRAY_A)
                    : $wpdb->get_results($wpdb->prepare($template, ...$args), ARRAY_A);
                $result = is_array($rows) ? $rows : [];
            } else {
                $result = $args === []
                    ? $wpdb->query($template)
                    : $wpdb->query($wpdb->prepare($template, ...$args));
            }
            // phpcs:enable WordPress.DB.PreparedSQL.NotPrepared, WordPress.DB.DirectDatabaseQuery, PluginCheck.Security.DirectDB.UnescapedDBParameter
            if ($wpdb->last_error !== '') {
                throw new \RuntimeException(esc_html('WordPress database error: ' . $wpdb->last_error));
            }
            return $select ? $result : (int) $result;
        } finally {
            $wpdb->suppress_errors($suppressed);
        }
    }

    /** @return list<array<string, mixed>> */
    private function rows(string $text, array $params = []): array
    {
        return array_values((array) $this->query($text, $params, true));
    }

    private static function duplicate(\Throwable $error): bool
    {
        return str_contains($error->getMessage(), 'Duplicate entry');
    }

    // ------------------------------------------------------------ the store

    public function upsertJob(JobDefinition $definition, int|float $now): void
    {
        $this->query($this->sql['upsertJob'], Sql::upsertJobParams($definition, $now));
    }

    public function getJob(string $name): ?StoredJob
    {
        $rows = $this->rows($this->sql['getJob'], [$name]);
        return $rows === [] ? null : Sql::rowToJob($rows[0]);
    }

    public function listJobs(): array
    {
        return array_map(Sql::rowToJob(...), $this->rows($this->sql['listJobs']));
    }

    public function deleteJob(string $name): void
    {
        $this->query('START TRANSACTION');
        try {
            $this->query($this->sql['deleteRuns'], [$name]);
            $this->query($this->sql['deleteState'], [$name]);
            $this->query($this->sql['deleteJob'], [$name]);
            $this->query('COMMIT');
        } catch (\Throwable $error) {
            try {
                $this->query('ROLLBACK');
            } catch (\Throwable) {
            }
            throw $error;
        }
    }

    public function insertRun(Run $run): void
    {
        $this->query($this->sql['insertRun'], Sql::insertRunParams($run));
    }

    public function updateRun(Run $run): void
    {
        $this->query($this->sql['updateRun'], Sql::updateRunParams($run));
    }

    public function updateRunIf(Run $run, array $fromStatuses): bool
    {
        if ($fromStatuses === []) {
            return false;
        }
        if ($this->query(Sql::updateRunIfSql($this->prefix, count($fromStatuses)), Sql::updateRunIfParams($run, $fromStatuses)) > 0) {
            return true;
        }
        // MySQL counts only the rows an UPDATE changed, so a row that already
        // held these values (and matched) answers 0: it was written all the same.
        $stored = $this->getRun($run->id);
        return $stored !== null && in_array($stored->status, $fromStatuses, true)
            && Js::stringify(Sql::updateRunParams($stored)) === Js::stringify(Sql::updateRunParams($run));
    }

    public function getRun(string $id): ?Run
    {
        $rows = $this->rows($this->sql['getRun'], [$id]);
        return $rows === [] ? null : Sql::rowToRun($rows[0]);
    }

    public function listRuns(string $job, int $limit): array
    {
        return array_map(Sql::rowToRun(...), $this->rows($this->sql['listRuns'], [$job, max(0, $limit)]));
    }

    public function lastRun(string $job): ?Run
    {
        $rows = $this->rows($this->sql['listRuns'], [$job, 1]);
        return $rows === [] ? null : Sql::rowToRun($rows[0]);
    }

    public function runningRuns(): array
    {
        return array_map(Sql::rowToRun(...), $this->rows($this->sql['runningRuns']));
    }

    public function getState(string $job): ?JobState
    {
        $rows = $this->rows($this->sql['getState'], [$job]);
        return $rows === [] ? null : Sql::rowToState($rows[0]);
    }

    public function setState(JobState $state): void
    {
        $this->query($this->sql['setState'], Sql::stateParams($state));
    }

    public function compareAndSetState(JobState $state, int|float $expectedVersion): bool
    {
        if ($expectedVersion != 0) {
            return $this->query($this->sql['casUpdate'], Sql::casUpdateParams($state, $expectedVersion)) > 0;
        }
        // Version 0 is a row at version 0 (or with none), or no row at all.
        [$job, $json] = Sql::stateParams($state);
        if ($this->query($this->sql['casFromZero'], [$json, $job]) > 0) {
            return true;
        }
        try {
            $this->query($this->sql['casInsert'], [$job, $json]);
            return true;
        } catch (\RuntimeException $error) {
            // A row is there, at another version: another process wrote first.
            if (self::duplicate($error)) {
                return false;
            }
            throw $error;
        }
    }

    public function prune(int|float $before): int
    {
        return (int) $this->query($this->sql['prune'], [$before]);
    }

    public function close(): void
    {
    }
}
