package dev.cronwatch.internal.sql;

import dev.cronwatch.json.Json;
import java.util.ArrayList;
import java.util.List;

/**
 * The schema and statements of the SDK's {@code stores/sql.ts}, text for text, so a Java process
 * shares a database with a Node, Ruby, Python, PHP, Go, Rust, or Elixir one and {@code
 * sqlite_master} reads the same whoever made the tables. {@code sql.ts} writes its statements with
 * {@code ?} and numbers them {@code $1}, {@code $2} for Postgres; JDBC takes {@code ?} on every
 * database, so these are its text before the numbering. MySQL (and MariaDB) has a dialect of its
 * own, the PHP, Go, Rust, and Elixir ports' ({@code packages/go/sqlstore/sql.go}), since it has no
 * {@code ON CONFLICT}, no partial index, and no {@code TEXT} primary key: the same tables, columns,
 * and values, with the JSON columns as {@code LONGTEXT} holding the SDK's JSON byte for byte, never
 * MySQL's {@code JSON} type, which would rewrite it.
 */
public final class Sql {
  private Sql() {}

  /** Starts every table name unless the store is given another prefix. */
  public static final String DEFAULT_PREFIX = "cronwatch_";

  /**
   * Postgres truncates identifiers past 63 bytes; the longest name built is the prefix plus {@code
   * runs_job_started}. The SDK holds every dialect to it.
   */
  static final int MAX_PREFIX = 63 - "runs_job_started".length();

  /**
   * Checks a prefix. Table names are built from it, so it must be a plain lowercase identifier.
   * Uppercase is refused rather than folded: Postgres lowercases unquoted names, so {@code
   * Monitoring_} would quietly become {@code monitoring_}.
   *
   * @throws IllegalArgumentException with the SDK's message, word for word
   */
  public static String tablePrefix(String prefix) {
    boolean ok = !prefix.isEmpty() && prefix.length() <= MAX_PREFIX;
    for (int i = 0; ok && i < prefix.length(); i++) {
      char c = prefix.charAt(i);
      ok = (c >= 'a' && c <= 'z') || c == '_' || (i > 0 && c >= '0' && c <= '9');
    }
    if (!ok) {
      throw new IllegalArgumentException(
          "cronwatch: invalid table prefix "
              + Json.stringify(prefix)
              + ". Use lowercase letters, digits, and underscores, not starting with a digit, at most "
              + MAX_PREFIX
              + " characters.");
    }
    return prefix;
  }

  /**
   * The tables and indexes, one statement each, run in turn: {@code sql.ts}'s template cut at its
   * semicolons.
   */
  public static List<String> schema(Dialect dialect, String p) {
    if (dialect == Dialect.MYSQL) {
      return mysqlSchema(p);
    }
    boolean pg = dialect == Dialect.POSTGRES;
    String integer = pg ? "BIGINT" : "INTEGER";
    String json = pg ? "JSONB" : "TEXT";
    String text =
        "\n    CREATE TABLE IF NOT EXISTS "
            + p
            + "jobs (\n      name TEXT PRIMARY KEY,\n      definition "
            + json
            + " NOT NULL,\n      created_at "
            + integer
            + " NOT NULL,\n      updated_at "
            + integer
            + " NOT NULL\n    );\n    CREATE TABLE IF NOT EXISTS "
            + p
            + "runs ("
            + (pg ? "\n      seq BIGSERIAL," : "")
            + "\n      id TEXT PRIMARY KEY,\n      job TEXT NOT NULL,\n      status TEXT NOT NULL,\n"
            + "      started_at "
            + integer
            + " NOT NULL,\n      finished_at "
            + integer
            + ",\n      duration_ms "
            + integer
            + ",\n      error TEXT,\n      output TEXT,\n      metrics "
            + json
            + " NOT NULL DEFAULT '{}',\n      trigger TEXT NOT NULL DEFAULT 'run'\n    );\n"
            + "    CREATE INDEX IF NOT EXISTS "
            + p
            + "runs_job_started ON "
            + p
            + "runs (job, started_at DESC);\n    CREATE INDEX IF NOT EXISTS "
            + p
            + "runs_running ON "
            + p
            + "runs (status) WHERE status = 'running';\n    CREATE TABLE IF NOT EXISTS "
            + p
            + "state (\n      job TEXT PRIMARY KEY,\n      state "
            + json
            + " NOT NULL\n    );\n  ";
    List<String> out = new ArrayList<>();
    for (String s : text.split(";", -1)) {
      if (!s.isBlank()) {
        out.add(s);
      }
    }
    return out;
  }

  /**
   * MySQL's tables (the PHP, Go, Rust, and Elixir ports'): {@code VARCHAR(255)} keys, {@code
   * BIGINT} times, {@code LONGTEXT} JSON, {@code utf8mb4_bin} so names compare and sort by byte,
   * {@code seq} for insertion order, and a plain index where the others have a partial one.
   */
  private static List<String> mysqlSchema(String p) {
    String table = "ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_bin";
    return List.of(
        "CREATE TABLE IF NOT EXISTS "
            + p
            + "jobs (\n      name VARCHAR(255) NOT NULL,\n      definition LONGTEXT NOT NULL,\n"
            + "      created_at BIGINT NOT NULL,\n      updated_at BIGINT NOT NULL,\n"
            + "      PRIMARY KEY (name)\n    ) "
            + table,
        "CREATE TABLE IF NOT EXISTS "
            + p
            + "runs (\n      seq BIGINT NOT NULL AUTO_INCREMENT,\n      id VARCHAR(255) NOT NULL,\n"
            + "      job VARCHAR(255) NOT NULL,\n      status VARCHAR(255) NOT NULL,\n"
            + "      started_at BIGINT NOT NULL,\n      finished_at BIGINT,\n      duration_ms BIGINT,\n"
            + "      error MEDIUMTEXT,\n      output MEDIUMTEXT,\n"
            + "      metrics LONGTEXT NOT NULL DEFAULT ('{}'),\n"
            + "      `trigger` VARCHAR(255) NOT NULL DEFAULT 'run',\n      PRIMARY KEY (id),\n"
            + "      UNIQUE KEY "
            + p
            + "runs_seq (seq),\n      KEY "
            + p
            + "runs_job_started (job, started_at DESC),\n      KEY "
            + p
            + "runs_running (status)\n    ) "
            + table,
        "CREATE TABLE IF NOT EXISTS "
            + p
            + "state (\n      job VARCHAR(255) NOT NULL,\n      state LONGTEXT NOT NULL,\n"
            + "      PRIMARY KEY (job)\n    ) "
            + table);
  }

  /**
   * The version inside a state's JSON, as {@code stateVersion()} reads it: a whole number from 0 to
   * 2^53 - 1, else 0 (none, or a foreign row's 1.5 or "x", which must neither fail the statement
   * nor refuse every write for good). Each CASE tests the JSON type before any cast.
   */
  static String version(Dialect dialect, String column) {
    if (dialect == Dialect.MYSQL) {
      // MySQL's JSON_EXTRACT answers JSON and MariaDB's text; plus 0, both are a number, and the
      // CASE tests the JSON type before any arithmetic. The column is text, which may hold text
      // that is not JSON at all (a damaged row's): that counts as 0, tested before JSON_EXTRACT,
      // which fails on it.
      String v = "JSON_EXTRACT(" + column + ", '$.version')";
      return "CASE WHEN NOT JSON_VALID("
          + column
          + ") THEN 0 WHEN JSON_TYPE("
          + v
          + ") NOT IN ('INTEGER', 'UNSIGNED INTEGER', 'DOUBLE', 'DECIMAL') THEN 0 WHEN "
          + v
          + " + 0 = FLOOR("
          + v
          + " + 0) AND "
          + v
          + " + 0 BETWEEN 0 AND 9007199254740991 THEN CAST("
          + v
          + " + 0 AS SIGNED) ELSE 0 END";
    }
    if (dialect == Dialect.POSTGRES) {
      String v = "(" + column + "->>'version')::numeric";
      return "CASE WHEN jsonb_typeof("
          + column
          + "->'version') <> 'number' THEN 0 WHEN "
          + v
          + " % 1 = 0 AND "
          + v
          + " BETWEEN 0 AND 9007199254740991 THEN "
          + v
          + "::bigint ELSE 0 END";
    }
    // Text that is not JSON at all (SQLite holds any) counts as 0 too, before json_type could fail
    // on it.
    String v = "json_extract(" + column + ", '$.version')";
    return "CASE WHEN NOT json_valid("
        + column
        + ") THEN 0 WHEN json_type("
        + column
        + ", '$.version') NOT IN ('integer', 'real') THEN 0 WHEN "
        + v
        + " = CAST("
        + v
        + " AS INTEGER) AND "
        + v
        + " BETWEEN 0 AND 9007199254740991 THEN CAST("
        + v
        + " AS INTEGER) ELSE 0 END";
  }

  /** The statements by name, for one dialect and prefix. */
  public static final class Statements {
    /** Writes a job's definition, keeping its {@code created_at}. */
    public final String upsertJob;

    /** Reads one job. */
    public final String getJob;

    /** Reads every job, names in byte order. */
    public final String listJobs;

    /** Deletes a job's runs. */
    public final String deleteRuns;

    /** Deletes a job's state. */
    public final String deleteState;

    /** Deletes a job. */
    public final String deleteJob;

    /** Inserts a run. */
    public final String insertRun;

    /** Writes a run's finish. */
    public final String updateRun;

    /** Reads one run. */
    public final String getRun;

    /** Reads a job's runs, newest first. */
    public final String listRuns;

    /** Reads every running run, oldest first. */
    public final String runningRuns;

    /** Reads a job's state. */
    public final String getState;

    /** Writes a job's state unconditionally. */
    public final String setState;

    /**
     * Compare-and-set expecting version 0, which also matches a missing row, so it inserts. On
     * MySQL a plain insert, which a row already there refuses: the second of its two steps.
     */
    public final String casInsert;

    /**
     * MySQL's first step of a compare-and-set from version 0: a row at version 0 (or without one)
     * is updated. Neither step leans on how the connection counts affected rows. The other dialects
     * do not use it.
     */
    public final String casFromZero;

    /** Compare-and-set expecting any other version, which must find its row. */
    public final String casUpdate;

    /** Deletes old finished runs, keeping each job's newest. */
    public final String prune;

    /** Takes back a run only while it is of one job and in one status. */
    public final String deleteRunIf;

    private final String prefix;

    /** The statements over tables of prefix {@code p}. */
    public Statements(Dialect dialect, String p) {
      prefix = p;
      if (dialect == Dialect.MYSQL) {
        String v = version(dialect, "state");
        upsertJob =
            "INSERT INTO "
                + p
                + "jobs (name, definition, created_at, updated_at) VALUES (?, ?, ?, ?)\n"
                + "      ON DUPLICATE KEY UPDATE definition = VALUES(definition), updated_at ="
                + " VALUES(updated_at)";
        getJob = "SELECT * FROM " + p + "jobs WHERE name = ?";
        listJobs = "SELECT * FROM " + p + "jobs ORDER BY name";
        deleteRuns = "DELETE FROM " + p + "runs WHERE job = ?";
        deleteState = "DELETE FROM " + p + "state WHERE job = ?";
        deleteJob = "DELETE FROM " + p + "jobs WHERE name = ?";
        insertRun =
            "INSERT INTO "
                + p
                + "runs (id, job, status, started_at, finished_at, duration_ms, error, output,"
                + " metrics, `trigger`)\n      VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)";
        updateRun =
            "UPDATE "
                + p
                + "runs SET status = ?, finished_at = ?, duration_ms = ?, error = ?, output = ?,"
                + " metrics = ? WHERE id = ?";
        getRun = "SELECT * FROM " + p + "runs WHERE id = ?";
        listRuns =
            "SELECT * FROM " + p + "runs WHERE job = ? ORDER BY started_at DESC, seq DESC LIMIT ?";
        runningRuns =
            "SELECT * FROM " + p + "runs WHERE status = 'running' ORDER BY started_at, seq";
        getState = "SELECT state FROM " + p + "state WHERE job = ?";
        setState =
            "INSERT INTO "
                + p
                + "state (job, state) VALUES (?, ?) ON DUPLICATE KEY UPDATE state = VALUES(state)";
        casFromZero = "UPDATE " + p + "state SET state = ? WHERE job = ? AND " + v + " = 0";
        casInsert = "INSERT INTO " + p + "state (job, state) VALUES (?, ?)";
        casUpdate = "UPDATE " + p + "state SET state = ? WHERE job = ? AND " + v + " = ?";
        // MySQL refuses a subquery on the table a DELETE deletes from, so the newest start per
        // job is a derived table joined in (grouped, so it is materialized rather than merged).
        prune =
            "DELETE r FROM "
                + p
                + "runs r\n      JOIN (SELECT job, MAX(started_at) AS newest FROM "
                + p
                + "runs GROUP BY job) n ON n.job = r.job\n"
                + "      WHERE r.status <> 'running' AND r.started_at < ? AND r.started_at <"
                + " n.newest";
        deleteRunIf = "DELETE FROM " + p + "runs WHERE id = ? AND job = ? AND status = ?";
        return;
      }
      boolean pg = dialect == Dialect.POSTGRES;
      // Insertion order, to break ties between runs that started in the same millisecond, and
      // byte order for names on both, whatever the database's collation.
      String seq = pg ? "seq" : "rowid";
      String byName = pg ? "name COLLATE \"C\"" : "name";
      upsertJob =
          "INSERT INTO "
              + p
              + "jobs (name, definition, created_at, updated_at) VALUES (?, ?, ?, ?)\n"
              + "      ON CONFLICT (name) DO UPDATE SET definition = excluded.definition,"
              + " updated_at = excluded.updated_at";
      getJob = "SELECT * FROM " + p + "jobs WHERE name = ?";
      listJobs = "SELECT * FROM " + p + "jobs ORDER BY " + byName;
      deleteRuns = "DELETE FROM " + p + "runs WHERE job = ?";
      deleteState = "DELETE FROM " + p + "state WHERE job = ?";
      deleteJob = "DELETE FROM " + p + "jobs WHERE name = ?";
      insertRun =
          "INSERT INTO "
              + p
              + "runs (id, job, status, started_at, finished_at, duration_ms, error, output,"
              + " metrics, trigger)\n      VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)";
      updateRun =
          "UPDATE "
              + p
              + "runs SET status = ?, finished_at = ?, duration_ms = ?, error = ?, output = ?,"
              + " metrics = ? WHERE id = ?";
      getRun = "SELECT * FROM " + p + "runs WHERE id = ?";
      listRuns =
          "SELECT * FROM "
              + p
              + "runs WHERE job = ? ORDER BY started_at DESC, "
              + seq
              + " DESC LIMIT ?";
      runningRuns =
          "SELECT * FROM " + p + "runs WHERE status = 'running' ORDER BY started_at, " + seq;
      getState = "SELECT state FROM " + p + "state WHERE job = ?";
      setState =
          "INSERT INTO "
              + p
              + "state (job, state) VALUES (?, ?) ON CONFLICT (job) DO UPDATE SET state ="
              + " excluded.state";
      casInsert =
          "INSERT INTO "
              + p
              + "state (job, state) VALUES (?, ?)\n"
              + "      ON CONFLICT (job) DO UPDATE SET state = excluded.state WHERE "
              + version(dialect, p + "state.state")
              + " = 0";
      casUpdate =
          "UPDATE "
              + p
              + "state SET state = ? WHERE job = ? AND "
              + version(dialect, "state")
              + " = ?";
      casFromZero = casUpdate;
      prune =
          "DELETE FROM "
              + p
              + "runs WHERE status <> 'running' AND started_at < ?\n"
              + "      AND started_at < (SELECT MAX(r.started_at) FROM "
              + p
              + "runs r WHERE r.job = "
              + p
              + "runs.job)";
      deleteRunIf = "DELETE FROM " + p + "runs WHERE id = ? AND job = ? AND status = ?";
    }

    /**
     * The update of a run, only while the stored status is one of {@code count} statuses. Built per
     * count, since the list is bound value by value.
     */
    public String updateRunIf(int count) {
      return "UPDATE "
          + prefix
          + "runs SET status = ?, finished_at = ?, duration_ms = ?, error = ?, output = ?, metrics"
          + " = ? WHERE id = ? AND status IN ("
          + String.join(", ", java.util.Collections.nCopies(count, "?"))
          + ")";
    }
  }
}
