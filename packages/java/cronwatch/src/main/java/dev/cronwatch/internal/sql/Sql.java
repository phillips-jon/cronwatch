package dev.cronwatch.internal.sql;

import dev.cronwatch.json.Json;
import java.util.ArrayList;
import java.util.List;

/**
 * The schema and statements of the SDK's {@code stores/sql.ts}, text for text, so a Java process
 * shares a database with a Node, Ruby, Python, PHP, Go, Rust or Elixir one and {@code
 * sqlite_master} reads the same whoever made the tables. {@code sql.ts} writes its statements with
 * {@code ?} and numbers them {@code $1}, {@code $2} for Postgres; JDBC takes {@code ?} on every
 * database, so these are its text before the numbering.
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
              + Json.quote(prefix)
              + ". Use lowercase letters, digits and underscores, not starting with a digit, at most "
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
   * The version inside a state's JSON, as {@code stateVersion()} reads it: a whole number from 0 to
   * 2^53 - 1, else 0 (none, or a foreign row's 1.5 or "x", which must neither fail the statement
   * nor refuse every write for good). Each CASE tests the JSON type before any cast.
   */
  static String version(Dialect dialect, String column) {
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
    String v = "json_extract(" + column + ", '$.version')";
    return "CASE WHEN json_type("
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

    /** Compare-and-set expecting version 0, which also matches a missing row, so it inserts. */
    public final String casInsert;

    /** Compare-and-set expecting any other version, which must find its row. */
    public final String casUpdate;

    /** Deletes old finished runs, keeping each job's newest. */
    public final String prune;

    /** Takes back a run only while it is of one job and in one status. */
    public final String deleteRunIf;

    private final String prefix;

    /** The statements over tables of prefix {@code p}. */
    public Statements(Dialect dialect, String p) {
      boolean pg = dialect == Dialect.POSTGRES;
      // Insertion order, to break ties between runs that started in the same millisecond, and
      // byte order for names on both, whatever the database's collation.
      String seq = pg ? "seq" : "rowid";
      String byName = pg ? "name COLLATE \"C\"" : "name";
      prefix = p;
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
