using System;
using System.Collections.Generic;
using System.Globalization;
using System.Text;

namespace Cronwatch.Internal;

/// <summary>The databases <c>SqlStore</c> speaks.</summary>
internal enum SqlDialect
{
    /// <summary>SQLite, as the SDK's <c>sqlite()</c> store writes it.</summary>
    Sqlite,

    /// <summary>Postgres, as the SDK's <c>postgres()</c> store writes it.</summary>
    Postgres,

    /// <summary>MySQL 8.0.13 or newer and MariaDB 10.6 or newer, the PHP, Go, Rust, Elixir and Java ports' dialect.</summary>
    MySql,
}

/// <summary>
/// The schema and statements of the SDK's <c>stores/sql.ts</c>, text for text, so a .NET process
/// shares a database with a Node, Ruby, Python, PHP, Go, Rust, Elixir or Java one and
/// <c>sqlite_master</c> reads the same whoever made the tables. <c>sql.ts</c> writes its
/// statements with <c>?</c> and numbers them <c>$1</c>, <c>$2</c> for Postgres. Microsoft.Data.Sqlite
/// binds by name only, so on SQLite they are numbered in SQLite's own form, <c>?1</c>, <c>?2</c>;
/// Npgsql types a string parameter as <c>text</c>, which a <c>jsonb</c> column refuses, so on
/// Postgres each JSON parameter is written <c>$n::jsonb</c>. The schema is untouched.
/// </summary>
internal static class SqlText
{
    /// <summary>Starts every table name unless the store is given another prefix.</summary>
    public const string DefaultPrefix = "cronwatch_";

    /// <summary>
    /// Postgres truncates identifiers past 63 bytes; the longest name built is the prefix plus
    /// <c>runs_job_started</c>. The SDK holds every dialect to it.
    /// </summary>
    public const int MaxPrefix = 63 - 16;

    /// <summary>Checks a prefix: a plain lowercase identifier (the SDK's message, word for word).</summary>
    /// <exception cref="ArgumentException">For anything else.</exception>
    public static string TablePrefix(string prefix)
    {
        bool ok = prefix.Length > 0 && prefix.Length <= MaxPrefix;
        for (int i = 0; ok && i < prefix.Length; i++)
        {
            char c = prefix[i];
            ok = (c >= 'a' && c <= 'z') || c == '_' || (i > 0 && c >= '0' && c <= '9');
        }
        if (!ok)
        {
            throw new ArgumentException(
                "cronwatch: invalid table prefix " + JsonText.Quote(prefix)
                + ". Use lowercase letters, digits and underscores, not starting with a digit, at most "
                + MaxPrefix.ToString(CultureInfo.InvariantCulture) + " characters.");
        }
        return prefix;
    }

    /// <summary><c>sql.ts</c>'s schema template, whole.</summary>
    public static string SchemaText(SqlDialect dialect, string p)
    {
        bool pg = dialect == SqlDialect.Postgres;
        string integer = pg ? "BIGINT" : "INTEGER";
        string json = pg ? "JSONB" : "TEXT";
        return "\n    CREATE TABLE IF NOT EXISTS " + p + "jobs (\n      name TEXT PRIMARY KEY,\n      definition " + json
            + " NOT NULL,\n      created_at " + integer + " NOT NULL,\n      updated_at " + integer
            + " NOT NULL\n    );\n    CREATE TABLE IF NOT EXISTS " + p + "runs (" + (pg ? "\n      seq BIGSERIAL," : "")
            + "\n      id TEXT PRIMARY KEY,\n      job TEXT NOT NULL,\n      status TEXT NOT NULL,\n      started_at " + integer
            + " NOT NULL,\n      finished_at " + integer + ",\n      duration_ms " + integer
            + ",\n      error TEXT,\n      output TEXT,\n      metrics " + json
            + " NOT NULL DEFAULT '{}',\n      trigger TEXT NOT NULL DEFAULT 'run'\n    );\n    CREATE INDEX IF NOT EXISTS " + p
            + "runs_job_started ON " + p + "runs (job, started_at DESC);\n    CREATE INDEX IF NOT EXISTS " + p
            + "runs_running ON " + p + "runs (status) WHERE status = 'running';\n    CREATE TABLE IF NOT EXISTS " + p
            + "state (\n      job TEXT PRIMARY KEY,\n      state " + json + " NOT NULL\n    );\n  ";
    }

    /// <summary>
    /// MySQL's tables (the PHP, Go, Rust, Elixir and Java ports'): <c>VARCHAR(255)</c> keys,
    /// <c>BIGINT</c> times, <c>LONGTEXT</c> JSON holding the SDK's bytes (never MySQL's <c>JSON</c>
    /// type, which would rewrite them), <c>utf8mb4_bin</c> so names compare and sort by byte,
    /// <c>seq</c> for insertion order, and a plain index where the others have a partial one.
    /// </summary>
    private static List<string> MySqlSchema(string p)
    {
        const string table = "ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_bin";
        return
        [
            "CREATE TABLE IF NOT EXISTS " + p + "jobs (\n      name VARCHAR(255) NOT NULL,\n      definition LONGTEXT NOT NULL,\n"
                + "      created_at BIGINT NOT NULL,\n      updated_at BIGINT NOT NULL,\n      PRIMARY KEY (name)\n    ) " + table,
            "CREATE TABLE IF NOT EXISTS " + p + "runs (\n      seq BIGINT NOT NULL AUTO_INCREMENT,\n      id VARCHAR(255) NOT NULL,\n"
                + "      job VARCHAR(255) NOT NULL,\n      status VARCHAR(255) NOT NULL,\n"
                + "      started_at BIGINT NOT NULL,\n      finished_at BIGINT,\n      duration_ms BIGINT,\n"
                + "      error MEDIUMTEXT,\n      output MEDIUMTEXT,\n"
                + "      metrics LONGTEXT NOT NULL DEFAULT ('{}'),\n"
                + "      `trigger` VARCHAR(255) NOT NULL DEFAULT 'run',\n      PRIMARY KEY (id),\n"
                + "      UNIQUE KEY " + p + "runs_seq (seq),\n      KEY " + p + "runs_job_started (job, started_at DESC),\n      KEY "
                + p + "runs_running (status)\n    ) " + table,
            "CREATE TABLE IF NOT EXISTS " + p + "state (\n      job VARCHAR(255) NOT NULL,\n      state LONGTEXT NOT NULL,\n"
                + "      PRIMARY KEY (job)\n    ) " + table,
        ];
    }

    /// <summary>The tables and indexes, one statement each: the template cut at its semicolons.</summary>
    public static IReadOnlyList<string> Schema(SqlDialect dialect, string p)
    {
        if (dialect == SqlDialect.MySql)
        {
            return MySqlSchema(p);
        }
        var output = new List<string>();
        foreach (string s in SchemaText(dialect, p).Split(';'))
        {
            if (!string.IsNullOrWhiteSpace(s))
            {
                output.Add(s);
            }
        }
        return output;
    }

    /// <summary>
    /// The version inside a state's JSON, as <c>stateVersion()</c> reads it: a whole number from 0
    /// to 2^53 - 1, else 0. Each CASE tests the JSON type before any cast, and on SQLite and MySQL,
    /// whose columns hold any text, that the text is JSON at all: a state row that is not counts as
    /// 0, so the next write replaces it rather than fail on it.
    /// </summary>
    public static string Version(SqlDialect dialect, string column)
    {
        if (dialect == SqlDialect.MySql)
        {
            // MySQL's JSON_EXTRACT answers JSON and MariaDB's text; plus 0, both are a number, and
            // the CASE tests the JSON type before any arithmetic.
            string mv = "JSON_EXTRACT(" + column + ", '$.version')";
            return "CASE WHEN NOT JSON_VALID(" + column + ") THEN 0 WHEN JSON_TYPE(" + mv + ") NOT IN ('INTEGER', 'UNSIGNED INTEGER', 'DOUBLE', 'DECIMAL') THEN 0 WHEN " + mv
                + " + 0 = FLOOR(" + mv + " + 0) AND " + mv + " + 0 BETWEEN 0 AND 9007199254740991 THEN CAST(" + mv
                + " + 0 AS SIGNED) ELSE 0 END";
        }
        if (dialect == SqlDialect.Postgres)
        {
            string pv = "(" + column + "->>'version')::numeric";
            return "CASE WHEN jsonb_typeof(" + column + "->'version') <> 'number' THEN 0 WHEN " + pv + " % 1 = 0 AND " + pv
                + " BETWEEN 0 AND 9007199254740991 THEN " + pv + "::bigint ELSE 0 END";
        }
        string v = "json_extract(" + column + ", '$.version')";
        return "CASE WHEN NOT json_valid(" + column + ") THEN 0 WHEN json_type(" + column + ", '$.version') NOT IN ('integer', 'real') THEN 0 WHEN " + v + " = CAST(" + v
            + " AS INTEGER) AND " + v + " BETWEEN 0 AND 9007199254740991 THEN CAST(" + v + " AS INTEGER) ELSE 0 END";
    }

    /// <summary>
    /// Numbers a statement's <c>?</c> placeholders: <c>?1</c> on SQLite, <c>$1</c> on Postgres with
    /// the JSON ones (1-based positions in <paramref name="json"/>) cast <c>::jsonb</c>.
    /// </summary>
    public static string Number(SqlDialect dialect, string text, params int[] json)
    {
        if (dialect == SqlDialect.MySql)
        {
            // MySqlConnector binds unnamed parameters to ? in order, as sql.ts writes them.
            return text;
        }
        var b = new StringBuilder(text.Length + 16);
        int n = 0;
        foreach (char c in text)
        {
            if (c != '?')
            {
                b.Append(c);
                continue;
            }
            n++;
            if (dialect == SqlDialect.Sqlite)
            {
                b.Append('?').Append(n.ToString(CultureInfo.InvariantCulture));
            }
            else
            {
                b.Append('$').Append(n.ToString(CultureInfo.InvariantCulture));
                if (Array.IndexOf(json, n) >= 0)
                {
                    b.Append("::jsonb");
                }
            }
        }
        return b.ToString();
    }

    /// <summary>The statements by name, for one dialect and prefix, numbered.</summary>
    internal sealed class Statements
    {
        private readonly SqlDialect _dialect;
        private readonly string _prefix;

        public Statements(SqlDialect dialect, string p)
        {
            _dialect = dialect;
            _prefix = p;
            if (dialect == SqlDialect.MySql)
            {
                string v = Version(dialect, "state");
                UpsertJob = "INSERT INTO " + p + "jobs (name, definition, created_at, updated_at) VALUES (?, ?, ?, ?)\n"
                    + "      ON DUPLICATE KEY UPDATE definition = VALUES(definition), updated_at = VALUES(updated_at)";
                GetJob = "SELECT * FROM " + p + "jobs WHERE name = ?";
                ListJobs = "SELECT * FROM " + p + "jobs ORDER BY name";
                DeleteRuns = "DELETE FROM " + p + "runs WHERE job = ?";
                DeleteState = "DELETE FROM " + p + "state WHERE job = ?";
                DeleteJob = "DELETE FROM " + p + "jobs WHERE name = ?";
                InsertRun = "INSERT INTO " + p + "runs (id, job, status, started_at, finished_at, duration_ms, error, output, metrics, `trigger`)\n"
                    + "      VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)";
                UpdateRun = "UPDATE " + p + "runs SET status = ?, finished_at = ?, duration_ms = ?, error = ?, output = ?, metrics = ? WHERE id = ?";
                GetRun = "SELECT * FROM " + p + "runs WHERE id = ?";
                ListRuns = "SELECT * FROM " + p + "runs WHERE job = ? ORDER BY started_at DESC, seq DESC LIMIT ?";
                RunningRuns = "SELECT * FROM " + p + "runs WHERE status = 'running' ORDER BY started_at, seq";
                GetState = "SELECT state FROM " + p + "state WHERE job = ?";
                SetState = "INSERT INTO " + p + "state (job, state) VALUES (?, ?) ON DUPLICATE KEY UPDATE state = VALUES(state)";
                // A compare-and-set from version 0 is two steps on MySQL, each deciding alone: a row
                // at version 0 (or without one) is updated, and failing that the row is inserted,
                // which a row already there refuses.
                CasFromZero = "UPDATE " + p + "state SET state = ? WHERE job = ? AND " + v + " = 0";
                CasInsert = "INSERT INTO " + p + "state (job, state) VALUES (?, ?)";
                CasUpdate = "UPDATE " + p + "state SET state = ? WHERE job = ? AND " + v + " = ?";
                // MySQL refuses a subquery on the table a DELETE deletes from, so the newest start
                // per job is a derived table joined in (grouped, so it is materialized rather than
                // merged).
                Prune = "DELETE r FROM " + p + "runs r\n      JOIN (SELECT job, MAX(started_at) AS newest FROM " + p
                    + "runs GROUP BY job) n ON n.job = r.job\n      WHERE r.status <> 'running' AND r.started_at < ? AND r.started_at < n.newest";
                DeleteRunIf = "DELETE FROM " + p + "runs WHERE id = ? AND job = ? AND status = ?";
                return;
            }
            bool pg = dialect == SqlDialect.Postgres;
            // Insertion order, to break ties between runs that started in the same millisecond, and
            // byte order for names on both, whatever the database's collation.
            string seq = pg ? "seq" : "rowid";
            string byName = pg ? "name COLLATE \"C\"" : "name";
            UpsertJob = Number(dialect, "INSERT INTO " + p + "jobs (name, definition, created_at, updated_at) VALUES (?, ?, ?, ?)\n"
                + "      ON CONFLICT (name) DO UPDATE SET definition = excluded.definition, updated_at = excluded.updated_at", 2);
            GetJob = Number(dialect, "SELECT * FROM " + p + "jobs WHERE name = ?");
            ListJobs = "SELECT * FROM " + p + "jobs ORDER BY " + byName;
            DeleteRuns = Number(dialect, "DELETE FROM " + p + "runs WHERE job = ?");
            DeleteState = Number(dialect, "DELETE FROM " + p + "state WHERE job = ?");
            DeleteJob = Number(dialect, "DELETE FROM " + p + "jobs WHERE name = ?");
            InsertRun = Number(dialect, "INSERT INTO " + p + "runs (id, job, status, started_at, finished_at, duration_ms, error, output, metrics, trigger)\n"
                + "      VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)", 9);
            UpdateRun = Number(dialect, "UPDATE " + p + "runs SET status = ?, finished_at = ?, duration_ms = ?, error = ?, output = ?, metrics = ? WHERE id = ?", 6);
            GetRun = Number(dialect, "SELECT * FROM " + p + "runs WHERE id = ?");
            ListRuns = Number(dialect, "SELECT * FROM " + p + "runs WHERE job = ? ORDER BY started_at DESC, " + seq + " DESC LIMIT ?");
            RunningRuns = "SELECT * FROM " + p + "runs WHERE status = 'running' ORDER BY started_at, " + seq;
            GetState = Number(dialect, "SELECT state FROM " + p + "state WHERE job = ?");
            SetState = Number(dialect, "INSERT INTO " + p + "state (job, state) VALUES (?, ?) ON CONFLICT (job) DO UPDATE SET state = excluded.state", 2);
            // Expecting version 0 also matches a missing row, so that case inserts; any other
            // version must find its row.
            CasInsert = Number(dialect, "INSERT INTO " + p + "state (job, state) VALUES (?, ?)\n"
                + "      ON CONFLICT (job) DO UPDATE SET state = excluded.state WHERE " + Version(dialect, p + "state.state") + " = 0", 2);
            CasUpdate = Number(dialect, "UPDATE " + p + "state SET state = ? WHERE job = ? AND " + Version(dialect, "state") + " = ?", 1);
            CasFromZero = CasUpdate;
            // Each job's newest run is kept whatever its age: without it, a job that runs less
            // often than the retention looks like it never ran.
            Prune = Number(dialect, "DELETE FROM " + p + "runs WHERE status <> 'running' AND started_at < ?\n"
                + "      AND started_at < (SELECT MAX(r.started_at) FROM " + p + "runs r WHERE r.job = " + p + "runs.job)");
            DeleteRunIf = Number(dialect, "DELETE FROM " + p + "runs WHERE id = ? AND job = ? AND status = ?");
        }

        public string UpsertJob { get; }

        public string GetJob { get; }

        public string ListJobs { get; }

        public string DeleteRuns { get; }

        public string DeleteState { get; }

        public string DeleteJob { get; }

        public string InsertRun { get; }

        public string UpdateRun { get; }

        public string GetRun { get; }

        public string ListRuns { get; }

        public string RunningRuns { get; }

        public string GetState { get; }

        public string SetState { get; }

        public string CasInsert { get; }

        public string CasUpdate { get; }

        /// <summary>MySQL's first step of a compare-and-set from version 0; the other dialects do not use it.</summary>
        public string CasFromZero { get; }

        public string Prune { get; }

        public string DeleteRunIf { get; }

        /// <summary>
        /// The update of a run, only while the stored status is one of <paramref name="count"/>
        /// statuses. Built per count, since the list is bound value by value.
        /// </summary>
        public string UpdateRunIf(int count)
        {
            var marks = new string[count];
            Array.Fill(marks, "?");
            return Number(_dialect, "UPDATE " + _prefix + "runs SET status = ?, finished_at = ?, duration_ms = ?, error = ?, output = ?, metrics = ? WHERE id = ? AND status IN ("
                + string.Join(", ", marks) + ")", 6);
        }
    }
}
