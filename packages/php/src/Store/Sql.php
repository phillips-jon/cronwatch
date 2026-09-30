<?php

declare(strict_types=1);

namespace Cronwatch\Store;

use Cronwatch\JobDefinition;
use Cronwatch\JobState;
use Cronwatch\Js;
use Cronwatch\Output;
use Cronwatch\Run;
use Cronwatch\StoredJob;

/**
 * The schema, statements, parameters and row mapping of the SQL stores.
 * SQLite's are stores/sql.ts's text for text, so a Node, a Ruby, a Python
 * and a PHP process can share one file. MySQL (and MariaDB) has a dialect
 * of its own, since it has no ON CONFLICT, no partial index and no TEXT
 * primary key, but the same tables, columns and values: the JSON columns
 * are text holding the SDK's JSON byte for byte, never MySQL's JSON type,
 * which would rewrite it. See DESIGN.md, "Storage".
 *
 * @internal
 */
final class Sql
{
    public const DEFAULT_PREFIX = 'cronwatch_';

    /** Postgres truncates identifiers past 63 bytes; the longest name built is the prefix plus "runs_job_started". */
    public const MAX_PREFIX = 63 - 16;

    /**
     * Table names are built from the prefix, so it must be a plain lowercase
     * identifier. Uppercase is refused rather than folded: Postgres lowercases
     * unquoted names, so "Monitoring_" would quietly become "monitoring_".
     */
    public static function tablePrefix(string $prefix = self::DEFAULT_PREFIX): string
    {
        if (preg_match('/^[a-z_][a-z0-9_]*$/D', $prefix) !== 1 || strlen($prefix) > self::MAX_PREFIX) {
            throw new \InvalidArgumentException(
                'cronwatch: invalid table prefix ' . Js::quote($prefix) . '. Use lowercase letters, digits and underscores, '
                . 'not starting with a digit, at most ' . self::MAX_PREFIX . ' characters.'
            );
        }
        return $prefix;
    }

    /** The SDK's SQLite schema, text for text, so sqlite_master reads the same whoever created the tables. */
    public static function sqliteSchema(string $p): string
    {
        return "
    CREATE TABLE IF NOT EXISTS {$p}jobs (
      name TEXT PRIMARY KEY,
      definition TEXT NOT NULL,
      created_at INTEGER NOT NULL,
      updated_at INTEGER NOT NULL
    );
    CREATE TABLE IF NOT EXISTS {$p}runs (
      id TEXT PRIMARY KEY,
      job TEXT NOT NULL,
      status TEXT NOT NULL,
      started_at INTEGER NOT NULL,
      finished_at INTEGER,
      duration_ms INTEGER,
      error TEXT,
      output TEXT,
      metrics TEXT NOT NULL DEFAULT '{}',
      trigger TEXT NOT NULL DEFAULT 'run'
    );
    CREATE INDEX IF NOT EXISTS {$p}runs_job_started ON {$p}runs (job, started_at DESC);
    CREATE INDEX IF NOT EXISTS {$p}runs_running ON {$p}runs (status) WHERE status = 'running';
    CREATE TABLE IF NOT EXISTS {$p}state (
      job TEXT PRIMARY KEY,
      state TEXT NOT NULL
    );
  ";
    }

    /** The SDK's Postgres schema, text for text: JSONB for the JSON columns, BIGINT times, `seq` for ties. */
    public static function postgresSchema(string $p): string
    {
        return "
    CREATE TABLE IF NOT EXISTS {$p}jobs (
      name TEXT PRIMARY KEY,
      definition JSONB NOT NULL,
      created_at BIGINT NOT NULL,
      updated_at BIGINT NOT NULL
    );
    CREATE TABLE IF NOT EXISTS {$p}runs (
      seq BIGSERIAL,
      id TEXT PRIMARY KEY,
      job TEXT NOT NULL,
      status TEXT NOT NULL,
      started_at BIGINT NOT NULL,
      finished_at BIGINT,
      duration_ms BIGINT,
      error TEXT,
      output TEXT,
      metrics JSONB NOT NULL DEFAULT '{}',
      trigger TEXT NOT NULL DEFAULT 'run'
    );
    CREATE INDEX IF NOT EXISTS {$p}runs_job_started ON {$p}runs (job, started_at DESC);
    CREATE INDEX IF NOT EXISTS {$p}runs_running ON {$p}runs (status) WHERE status = 'running';
    CREATE TABLE IF NOT EXISTS {$p}state (
      job TEXT PRIMARY KEY,
      state JSONB NOT NULL
    );
  ";
    }

    /**
     * The same tables for MySQL 8.0.13 and MariaDB 10.6 or newer, one statement
     * each. Names and ids are byte-compared (utf8mb4_bin), as SQLite and
     * Postgres compare them, so "b" and "B" are two jobs and names sort in
     * byte order. `seq` breaks ties between runs started in one millisecond,
     * as Postgres's does.
     *
     * @return list<string>
     */
    public static function mysqlSchema(string $p): array
    {
        $table = 'ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_bin';
        return [
            "CREATE TABLE IF NOT EXISTS {$p}jobs (
      name VARCHAR(255) NOT NULL,
      definition LONGTEXT NOT NULL,
      created_at BIGINT NOT NULL,
      updated_at BIGINT NOT NULL,
      PRIMARY KEY (name)
    ) {$table}",
            "CREATE TABLE IF NOT EXISTS {$p}runs (
      seq BIGINT NOT NULL AUTO_INCREMENT,
      id VARCHAR(255) NOT NULL,
      job VARCHAR(255) NOT NULL,
      status VARCHAR(255) NOT NULL,
      started_at BIGINT NOT NULL,
      finished_at BIGINT,
      duration_ms BIGINT,
      error MEDIUMTEXT,
      output MEDIUMTEXT,
      metrics LONGTEXT NOT NULL DEFAULT ('{}'),
      `trigger` VARCHAR(255) NOT NULL DEFAULT 'run',
      PRIMARY KEY (id),
      UNIQUE KEY {$p}runs_seq (seq),
      KEY {$p}runs_job_started (job, started_at DESC),
      KEY {$p}runs_running (status)
    ) {$table}",
            "CREATE TABLE IF NOT EXISTS {$p}state (
      job VARCHAR(255) NOT NULL,
      state LONGTEXT NOT NULL,
      PRIMARY KEY (job)
    ) {$table}",
        ];
    }

    /**
     * The statements, by name, with ? placeholders.
     *
     * @return array<string, string>
     */
    public static function statements(string $dialect, string $p): array
    {
        if ($dialect === 'sqlite' || $dialect === 'postgres') {
            // Text for text as stores/sql.ts writes them. For Postgres the ?
            // placeholders are numbered $1, $2, ... by PDO's native prepare, so
            // the server sees the SDK's text.
            $pg = $dialect === 'postgres';
            // The version inside a state's JSON, as Evaluate::stateVersion()
            // reads it: a whole number from 0 to 2^53 - 1, else 0 (none, or a
            // foreign row's 1.5 or "x", which must neither fail the statement
            // nor refuse every write for good). Each CASE tests the JSON type
            // before any cast.
            $version = $pg
                ? function (string $column): string {
                    $v = "({$column}->>'version')::numeric";
                    return "CASE WHEN jsonb_typeof({$column}->'version') <> 'number' THEN 0 WHEN {$v} % 1 = 0 AND {$v} BETWEEN 0 AND 9007199254740991 THEN {$v}::bigint ELSE 0 END";
                }
                : function (string $column): string {
                    $v = "json_extract({$column}, '\$.version')";
                    return "CASE WHEN json_type({$column}, '\$.version') NOT IN ('integer', 'real') THEN 0 WHEN {$v} = CAST({$v} AS INTEGER) AND {$v} BETWEEN 0 AND 9007199254740991 THEN CAST({$v} AS INTEGER) ELSE 0 END";
                };
            // Insertion order breaks ties; byte order for names whatever the database's collation.
            $seq = $pg ? 'seq' : 'rowid';
            $byName = $pg ? 'name COLLATE "C"' : 'name';
            return [
                'upsertJob' => "INSERT INTO {$p}jobs (name, definition, created_at, updated_at) VALUES (?, ?, ?, ?)
      ON CONFLICT (name) DO UPDATE SET definition = excluded.definition, updated_at = excluded.updated_at",
                'getJob' => "SELECT * FROM {$p}jobs WHERE name = ?",
                'listJobs' => "SELECT * FROM {$p}jobs ORDER BY {$byName}",
                'deleteRuns' => "DELETE FROM {$p}runs WHERE job = ?",
                'deleteState' => "DELETE FROM {$p}state WHERE job = ?",
                'deleteJob' => "DELETE FROM {$p}jobs WHERE name = ?",
                'insertRun' => "INSERT INTO {$p}runs (id, job, status, started_at, finished_at, duration_ms, error, output, metrics, trigger)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
                'updateRun' => "UPDATE {$p}runs SET status = ?, finished_at = ?, duration_ms = ?, error = ?, output = ?, metrics = ? WHERE id = ?",
                'getRun' => "SELECT * FROM {$p}runs WHERE id = ?",
                'listRuns' => "SELECT * FROM {$p}runs WHERE job = ? ORDER BY started_at DESC, {$seq} DESC LIMIT ?",
                'runningRuns' => "SELECT * FROM {$p}runs WHERE status = 'running' ORDER BY started_at, {$seq}",
                'getState' => "SELECT state FROM {$p}state WHERE job = ?",
                'setState' => "INSERT INTO {$p}state (job, state) VALUES (?, ?) ON CONFLICT (job) DO UPDATE SET state = excluded.state",
                // compareAndSetState. Expecting version 0 also matches a missing
                // row, so that case inserts; any other version must find its row.
                'casInsert' => "INSERT INTO {$p}state (job, state) VALUES (?, ?)
      ON CONFLICT (job) DO UPDATE SET state = excluded.state WHERE {$version("{$p}state.state")} = 0",
                'casUpdate' => "UPDATE {$p}state SET state = ? WHERE job = ? AND {$version('state')} = ?",
                // Each job's newest run is kept whatever its age: without it, a job
                // that runs less often than the retention looks like it never ran.
                'prune' => "DELETE FROM {$p}runs WHERE status <> 'running' AND started_at < ?
      AND started_at < (SELECT MAX(r.started_at) FROM {$p}runs r WHERE r.job = {$p}runs.job)",
            ];
        }
        // The version inside a state's JSON text, as Evaluate::stateVersion()
        // reads it: a whole number from 0 to 2^53 - 1, else 0. JSON_TYPE is
        // tested first, so nothing but a number is ever converted (a string's
        // conversion warns, which strict mode makes an error in an UPDATE).
        // MySQL's JSON_EXTRACT answers JSON and MariaDB's text; plus 0, both
        // are a number.
        $version = function (string $column): string {
            $v = "JSON_EXTRACT({$column}, '\$.version') + 0";
            return "CASE WHEN JSON_TYPE(JSON_EXTRACT({$column}, '\$.version')) NOT IN ('INTEGER', 'UNSIGNED INTEGER', 'DOUBLE', 'DECIMAL') THEN 0 "
                . "WHEN {$v} = FLOOR({$v}) AND {$v} BETWEEN 0 AND 9007199254740991 THEN CAST({$v} AS SIGNED) ELSE 0 END";
        };
        return [
            'upsertJob' => "INSERT INTO {$p}jobs (name, definition, created_at, updated_at) VALUES (?, ?, ?, ?)
      ON DUPLICATE KEY UPDATE definition = VALUES(definition), updated_at = VALUES(updated_at)",
            'getJob' => "SELECT * FROM {$p}jobs WHERE name = ?",
            'listJobs' => "SELECT * FROM {$p}jobs ORDER BY name",
            'deleteRuns' => "DELETE FROM {$p}runs WHERE job = ?",
            'deleteState' => "DELETE FROM {$p}state WHERE job = ?",
            'deleteJob' => "DELETE FROM {$p}jobs WHERE name = ?",
            'insertRun' => "INSERT INTO {$p}runs (id, job, status, started_at, finished_at, duration_ms, error, output, metrics, `trigger`)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
            'updateRun' => "UPDATE {$p}runs SET status = ?, finished_at = ?, duration_ms = ?, error = ?, output = ?, metrics = ? WHERE id = ?",
            'getRun' => "SELECT * FROM {$p}runs WHERE id = ?",
            'listRuns' => "SELECT * FROM {$p}runs WHERE job = ? ORDER BY started_at DESC, seq DESC LIMIT ?",
            'runningRuns' => "SELECT * FROM {$p}runs WHERE status = 'running' ORDER BY started_at, seq",
            'getState' => "SELECT state FROM {$p}state WHERE job = ?",
            'setState' => "INSERT INTO {$p}state (job, state) VALUES (?, ?) ON DUPLICATE KEY UPDATE state = VALUES(state)",
            // compareAndSetState from version 0, in two steps that each decide
            // alone: a row at version 0 (or without one) is updated, and failing
            // that the row is inserted, which a row already there refuses. Neither
            // leans on how the connection counts affected rows.
            'casFromZero' => "UPDATE {$p}state SET state = ? WHERE job = ? AND {$version('state')} = 0",
            'casInsert' => "INSERT INTO {$p}state (job, state) VALUES (?, ?)",
            'casUpdate' => "UPDATE {$p}state SET state = ? WHERE job = ? AND {$version('state')} = ?",
            // MySQL refuses a subquery on the table a DELETE deletes from, so
            // the newest start per job is a derived table joined in (grouped,
            // so it is materialized rather than merged).
            'prune' => "DELETE r FROM {$p}runs r
      JOIN (SELECT job, MAX(started_at) AS newest FROM {$p}runs GROUP BY job) n ON n.job = r.job
      WHERE r.status <> 'running' AND r.started_at < ? AND r.started_at < n.newest",
        ];
    }

    /** deleteRunIf: one run, only while it is of the job and in the status given. */
    public static function deleteRunIfSql(string $p): string
    {
        return "DELETE FROM {$p}runs WHERE id = ? AND job = ? AND status = ?";
    }

    /** updateRunIf: the update above, only while the stored status is one of `count` statuses. */
    public static function updateRunIfSql(string $p, int $count): string
    {
        return "UPDATE {$p}runs SET status = ?, finished_at = ?, duration_ms = ?, error = ?, output = ?, metrics = ? WHERE id = ? AND status IN ("
            . implode(', ', array_fill(0, $count, '?')) . ')';
    }

    // Parameters in statement order, so every driver binds the same values.

    /** @return list<mixed> */
    public static function upsertJobParams(JobDefinition $definition, int|float $now): array
    {
        return [(string) $definition->get('name'), self::jsonText($definition), $now, $now];
    }

    /** @return list<mixed> */
    public static function insertRunParams(Run $run): array
    {
        return [
            $run->id, $run->job, $run->status, $run->startedAt, $run->finishedAt, $run->durationMs,
            self::text($run->error), self::text($run->output), self::jsonText(Js::obj($run->metrics)), Output::stripNul($run->trigger),
        ];
    }

    /** @return list<mixed> */
    public static function updateRunParams(Run $run): array
    {
        return [$run->status, $run->finishedAt, $run->durationMs, self::text($run->error), self::text($run->output), self::jsonText(Js::obj($run->metrics)), $run->id];
    }

    /**
     * @param list<string> $fromStatuses
     * @return list<mixed>
     */
    public static function updateRunIfParams(Run $run, array $fromStatuses): array
    {
        return [...self::updateRunParams($run), ...array_values($fromStatuses)];
    }

    /** @return list<mixed> */
    public static function stateParams(JobState $state): array
    {
        return [$state->job, self::jsonText($state)];
    }

    /** @return list<mixed> */
    public static function casUpdateParams(JobState $state, int|float $expectedVersion): array
    {
        return [self::jsonText($state), $state->job, $expectedVersion];
    }

    /*
     * Postgres refuses U+0000 in TEXT and JSONB, and a refused write loses the
     * whole row, so every dialect writes text without it: a run's trigger,
     * output, error and metric names, and every key and string of a
     * definition and a state (stores/sql.ts). Identifiers (a job's name, a
     * run's id) are written as given; the client refuses one with a NUL
     * before it gets here.
     */

    /** A TEXT value as a JavaScript driver writes it: valid UTF-8, without NUL. */
    private static function text(?string $value): ?string
    {
        return $value === null ? null : Output::stripNul(Js::wellFormed($value));
    }

    /** JSON text as the SDK writes it, without NUL. */
    private static function jsonText(mixed $value): string
    {
        return Output::stripJsonNul(Js::stringify($value));
    }

    /** JSON text as the SDK wrote it. */
    private static function json(mixed $value): mixed
    {
        return is_string($value) ? Js::parse($value) : $value;
    }

    /** A number column: drivers may answer with text. */
    private static function num(mixed $value): int|float|null
    {
        if ($value === null || is_int($value) || is_float($value)) {
            return $value;
        }
        $text = (string) $value;
        return preg_match('/^-?[0-9]+$/D', $text) === 1 ? (int) $text : (float) $text;
    }

    /** @param array<string, mixed> $row */
    public static function rowToJob(array $row): StoredJob
    {
        return new StoredJob(
            (string) $row['name'],
            JobDefinition::fromJson(self::json($row['definition'])),
            self::num($row['created_at']) ?? 0,
            self::num($row['updated_at']) ?? 0,
        );
    }

    /** @param array<string, mixed> $row */
    public static function rowToRun(array $row): Run
    {
        $metrics = $row['metrics'] === null ? [] : Js::fields(self::json($row['metrics']));
        return new Run(
            id: (string) $row['id'],
            job: (string) $row['job'],
            status: (string) $row['status'],
            startedAt: self::num($row['started_at']) ?? 0,
            finishedAt: self::num($row['finished_at']),
            durationMs: self::num($row['duration_ms']),
            error: $row['error'],
            output: $row['output'],
            metrics: $metrics,
            trigger: (string) $row['trigger'],
        );
    }

    /** @param array<string, mixed> $row */
    public static function rowToState(array $row): JobState
    {
        return JobState::fromJson(self::json($row['state']));
    }
}
