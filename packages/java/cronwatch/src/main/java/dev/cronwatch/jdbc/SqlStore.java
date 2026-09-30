package dev.cronwatch.jdbc;

import dev.cronwatch.CronwatchException;
import dev.cronwatch.Definition;
import dev.cronwatch.JobState;
import dev.cronwatch.Metrics;
import dev.cronwatch.Run;
import dev.cronwatch.RunStatus;
import dev.cronwatch.StoredJob;
import dev.cronwatch.internal.js.Js;
import dev.cronwatch.internal.sql.Dialect;
import dev.cronwatch.internal.sql.Sql;
import dev.cronwatch.json.JsObject;
import dev.cronwatch.json.Json;
import dev.cronwatch.store.Store;
import java.nio.ByteBuffer;
import java.nio.charset.CharacterCodingException;
import java.nio.charset.CodingErrorAction;
import java.nio.charset.StandardCharsets;
import java.sql.Connection;
import java.sql.PreparedStatement;
import java.sql.ResultSet;
import java.sql.ResultSetMetaData;
import java.sql.SQLException;
import java.sql.Statement;
import java.sql.Types;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.Objects;
import java.util.concurrent.locks.ReentrantLock;
import javax.sql.DataSource;
import org.jspecify.annotations.Nullable;

/**
 * Keeps CronWatch's jobs, runs and state in the app's own database through JDBC: the SDK's tables
 * ({@code stores/sql.ts}), the same names, columns and statements, and the SDK's JSON in the JSON
 * columns byte for byte, so a Java process shares a database with a Node, Ruby, Python, PHP, Go,
 * Rust or Elixir one. The app brings its driver and its {@link DataSource} (its pool); no driver is
 * a dependency of this library. The tables are made when the client first calls {@link #init}.
 *
 * <p>On SQLite (xerial's {@code sqlite-jdbc}) the store takes one connection from the data source
 * once and keeps it for its statements, in turn, as the SDK's store holds one: an in-memory
 * database is one per connection, a pool's connections would each need the pragmas, and SQLite has
 * one writer at a time anyway. That connection is put in WAL mode (with the SDK's retry of a busy
 * database while switching), then {@code busy_timeout} 5000 and {@code synchronous} NORMAL. So a
 * pool of one connection leaves the app none: give it room for the store too.
 *
 * <p>On Postgres every statement runs on a connection the store takes from the data source for it,
 * in autocommit, so the store's writes never join a transaction the app has open and a failed run
 * does not vanish with the rollback it caused. Give it a plain data source, not one that hands out
 * the app's transactional connection (Spring's {@code TransactionAwareDataSourceProxy}). JSON is
 * bound untyped ({@code setObject(i, text, Types.OTHER)}), so Postgres infers {@code jsonb} as it
 * does for node-postgres and the statements need no cast. MySQL and MariaDB come in a later
 * release.
 */
public final class SqlStore implements Store {
  /** How long opening SQLite keeps retrying a busy database before it gives up (busy.ts). */
  private static final long BUSY_RETRY_MS = 2_000;

  private final DataSource dataSource;
  private final Dialect dialect;
  private final String prefix;
  private final Sql.Statements sql;

  /** SQLite's one connection, and the lock its statements take turns under. */
  private final ReentrantLock lock = new ReentrantLock();

  private @Nullable Connection connection;

  private SqlStore(DataSource dataSource, Dialect dialect, String prefix) {
    this.dataSource = Objects.requireNonNull(dataSource, "dataSource");
    this.dialect = dialect;
    this.prefix = prefix;
    this.sql = new Sql.Statements(dialect, prefix);
  }

  /**
   * A store over the app's SQLite data source, with the tables named {@code cronwatch_jobs}, {@code
   * cronwatch_runs} and {@code cronwatch_state}. Nothing is read or written until {@link #init}.
   */
  public static SqlStore sqlite(DataSource dataSource) {
    return new SqlStore(dataSource, Dialect.SQLITE, Sql.DEFAULT_PREFIX);
  }

  /**
   * A store over the app's Postgres data source, with the SDK's tables and statements ({@code
   * JSONB} for the JSON, {@code BIGINT} times, names sorted {@code COLLATE "C"}). Many processes
   * can start at once: {@link #init} makes the tables under an advisory lock per prefix. Nothing is
   * read or written until {@link #init}.
   */
  public static SqlStore postgres(DataSource dataSource) {
    return new SqlStore(dataSource, Dialect.POSTGRES, Sql.DEFAULT_PREFIX);
  }

  /**
   * A store for whatever database the data source reaches, as its driver names it ({@code
   * DatabaseMetaData.getDatabaseProductName()}): SQLite or Postgres. It takes a connection to ask.
   *
   * @throws CronwatchException of kind {@code STORE} when no connection can be had, and of kind
   *     {@code INVALID} for another database (MySQL and MariaDB come in a later release)
   */
  public static SqlStore of(DataSource dataSource) {
    String product;
    try (Connection c = dataSource.getConnection()) {
      product = c.getMetaData().getDatabaseProductName();
    } catch (SQLException e) {
      throw CronwatchException.store(e);
    }
    String name = product == null ? "" : product.toLowerCase(Locale.ROOT);
    if (name.contains("sqlite")) {
      return sqlite(dataSource);
    }
    if (name.contains("postgres")) {
      return postgres(dataSource);
    }
    if (name.contains("mysql") || name.contains("mariadb")) {
      throw CronwatchException.invalid(
          "SqlStore: MySQL and MariaDB are not supported by this release of the Java port; SQLite"
              + " and Postgres are");
    }
    throw CronwatchException.invalid(
        "SqlStore: " + product + " is not a database SqlStore knows (SQLite or Postgres)");
  }

  /**
   * A store like this one whose tables start with {@code prefix}: lowercase letters, digits and
   * underscores, not starting with a digit, at most 47 characters. Default {@code cronwatch_}. Call
   * it before the store is used; the new store holds no connection yet.
   *
   * @throws CronwatchException of kind {@code INVALID}, with the SDK's message, for anything else
   */
  public SqlStore prefix(String prefix) {
    try {
      return new SqlStore(dataSource, dialect, Sql.tablePrefix(prefix));
    } catch (IllegalArgumentException e) {
      throw CronwatchException.invalid(e.getMessage());
    }
  }

  /** The prefix of the store's tables. */
  public String tablePrefix() {
    return prefix;
  }

  /** The store's database: {@code sqlite} or {@code postgres}. */
  public String dialect() {
    return dialect.label();
  }

  /** Names the dialect and the prefix, never the data source, which may carry credentials. */
  @Override
  public String toString() {
    return "SqlStore(" + dialect.label() + ", prefix " + prefix + ")";
  }

  // ---- connections

  @FunctionalInterface
  private interface Work<T> {
    T apply(Connection c) throws SQLException;
  }

  /**
   * Runs {@code work} on SQLite's kept connection, under the store's lock, or on a connection of
   * its own from the data source, in autocommit, for Postgres.
   */
  private <T> T with(Work<T> work) throws SQLException {
    if (dialect == Dialect.SQLITE) {
      lock.lock();
      try {
        Connection c = open();
        try {
          return work.apply(c);
        } catch (SQLException e) {
          // A connection that failed as a connection is let go, and the next statement opens
          // another.
          if (c.isClosed()) {
            connection = null;
          }
          throw e;
        }
      } finally {
        lock.unlock();
      }
    }
    try (Connection c = dataSource.getConnection()) {
      if (!c.getAutoCommit()) {
        c.setAutoCommit(true);
      }
      return work.apply(c);
    }
  }

  /**
   * SQLite's connection, opened with its pragmas on first use. No busy handler until WAL is on:
   * switching journal mode can answer busy at once while another process is doing the same on a new
   * file, so that is retried here. The connection is kept only once every pragma has gone through;
   * a failed open is tried afresh next time.
   */
  private Connection open() throws SQLException {
    Connection c = connection;
    if (c != null && !c.isClosed()) {
      return c;
    }
    connection = null;
    Connection opened = dataSource.getConnection();
    try {
      opened.setAutoCommit(true);
      pragma(opened, "PRAGMA busy_timeout = 0");
      wal(opened);
      pragma(opened, "PRAGMA busy_timeout = 5000");
      pragma(opened, "PRAGMA synchronous = NORMAL");
    } catch (SQLException | RuntimeException e) {
      opened.close();
      throw e;
    }
    connection = opened;
    return opened;
  }

  private static void pragma(Connection c, String text) throws SQLException {
    try (Statement s = c.createStatement()) {
      s.execute(text);
    }
  }

  /**
   * Puts the connection in WAL mode, retrying while SQLite answers busy, with a short growing
   * pause, for up to two seconds in all (busy.ts {@code retryBusy}).
   */
  private static void wal(Connection c) throws SQLException {
    long waited = 0;
    for (int attempt = 0; ; attempt++) {
      try {
        pragma(c, "PRAGMA journal_mode = WAL");
        return;
      } catch (SQLException e) {
        if (!busy(e) || waited >= BUSY_RETRY_MS) {
          throw e;
        }
        long pause = Math.min(Math.min(10L << Math.min(attempt, 10), 200), BUSY_RETRY_MS - waited);
        try {
          Thread.sleep(pause);
        } catch (InterruptedException interrupted) {
          Thread.currentThread().interrupt();
          throw e;
        }
        waited += pause;
      }
    }
  }

  /** A pragma's value on SQLite's kept connection, for the tests. */
  String pragma(String name) throws SQLException {
    return with(
        c -> {
          try (Statement s = c.createStatement();
              ResultSet rs = s.executeQuery("PRAGMA " + name)) {
            return rs.next() ? String.valueOf(rs.getString(1)) : "";
          }
        });
  }

  /**
   * Whether SQLite answered SQLITE_BUSY or SQLITE_LOCKED (5 and 6, or an extended code of them).
   */
  static boolean busy(SQLException e) {
    int code = e.getErrorCode() & 0xff;
    String text = String.valueOf(e.getMessage());
    return code == 5
        || code == 6
        || text.contains("SQLITE_BUSY")
        || text.contains("SQLITE_LOCKED")
        || text.contains("database is locked")
        || text.contains("database table is locked");
  }

  // ---- parameters and rows

  /** A statement's parameter, in the types a JavaScript driver binds. */
  private sealed interface Param permits Text, Int, JsonText {}

  /** Text, or NULL. */
  private record Text(@Nullable String value) implements Param {}

  /** A whole number, or NULL. */
  private record Int(@Nullable Long value) implements Param {}

  /** JSON: text on SQLite, untyped on Postgres so it is inferred as {@code jsonb}. */
  private record JsonText(String value) implements Param {}

  private void bind(PreparedStatement ps, List<Param> params) throws SQLException {
    for (int i = 0; i < params.size(); i++) {
      int at = i + 1;
      switch (params.get(i)) {
        case Text t -> {
          if (t.value() == null) {
            ps.setNull(at, Types.VARCHAR);
          } else {
            // A lone surrogate is written as U+FFFD, as a JavaScript string is written as UTF-8.
            ps.setString(at, Js.wellFormed(t.value()));
          }
        }
        case Int n -> {
          if (n.value() == null) {
            ps.setNull(at, Types.BIGINT);
          } else {
            ps.setLong(at, n.value());
          }
        }
        case JsonText j -> {
          if (dialect == Dialect.POSTGRES) {
            ps.setObject(at, j.value(), Types.OTHER);
          } else {
            ps.setString(at, j.value());
          }
        }
      }
    }
  }

  /** Runs a statement, answering how many rows it changed. */
  private long run(String text, List<Param> params) throws SQLException {
    return with(c -> update(c, text, params));
  }

  private long update(Connection c, String text, List<Param> params) throws SQLException {
    try (PreparedStatement ps = c.prepareStatement(text)) {
      bind(ps, params);
      return ps.executeLargeUpdate();
    }
  }

  /** Runs a query, answering its rows: each a map of lowercase column names to values. */
  private List<Map<String, Object>> query(String text, List<Param> params) throws SQLException {
    return with(
        c -> {
          try (PreparedStatement ps = c.prepareStatement(text)) {
            bind(ps, params);
            try (ResultSet rs = ps.executeQuery()) {
              ResultSetMetaData meta = rs.getMetaData();
              int n = meta.getColumnCount();
              List<Map<String, Object>> rows = new ArrayList<>();
              while (rs.next()) {
                Map<String, Object> row = new HashMap<>();
                for (int i = 1; i <= n; i++) {
                  Object v = cell(rs, i);
                  if (v != null) {
                    row.put(meta.getColumnLabel(i).toLowerCase(Locale.ROOT), v);
                  }
                }
                rows.add(row);
              }
              return rows;
            }
          }
        });
  }

  /**
   * A column's value as the database gave it: a number, or text. SQLite's text is read as bytes and
   * decoded with U+FFFD for what is not UTF-8, as the SDK reads it, so one such value cannot fail
   * every read its row is part of. Anything else (Postgres's {@code jsonb}) is read as text.
   */
  private @Nullable Object cell(ResultSet rs, int i) throws SQLException {
    Object v = rs.getObject(i);
    if (v == null || v instanceof Number) {
      return v;
    }
    if (dialect == Dialect.SQLITE && v instanceof String) {
      byte[] bytes = rs.getBytes(i);
      return bytes == null ? v : utf8(bytes);
    }
    if (v instanceof String || v instanceof Boolean) {
      return v;
    }
    return rs.getString(i);
  }

  /** UTF-8 bytes as text, U+FFFD for each byte that is not part of a character. */
  private static String utf8(byte[] bytes) {
    try {
      return StandardCharsets.UTF_8
          .newDecoder()
          .onMalformedInput(CodingErrorAction.REPLACE)
          .onUnmappableCharacter(CodingErrorAction.REPLACE)
          .decode(ByteBuffer.wrap(bytes))
          .toString();
    } catch (CharacterCodingException e) {
      throw new IllegalStateException(e);
    }
  }

  /** A column as text, null for NULL. */
  private static @Nullable String text(Map<String, Object> row, String name) {
    return switch (row.get(name)) {
      case null -> null;
      case Double d -> Json.stringify(d);
      case Float f -> Json.stringify(f.doubleValue());
      case Number n -> Long.toString(n.longValue());
      case Object o -> o.toString();
    };
  }

  /**
   * A column as a whole number, null for NULL: text is read as a number, and a fraction is cut to
   * its whole part, held at the ends of the range.
   */
  private static @Nullable Long integer(Map<String, Object> row, String name) {
    return switch (row.get(name)) {
      case null -> null;
      case Double d -> Js.toLong(d);
      case Float f -> Js.toLong(f.doubleValue());
      case java.math.BigDecimal b -> Js.toLong(b.doubleValue());
      case Number n -> n.longValue();
      case Boolean b -> b ? 1L : 0L;
      case Object o -> {
        String t = o.toString().trim();
        try {
          yield Long.parseLong(t);
        } catch (NumberFormatException e) {
          try {
            yield Js.toLong(Double.parseDouble(t));
          } catch (NumberFormatException e2) {
            yield 0L;
          }
        }
      }
    };
  }

  private static long integer(Map<String, Object> row, String name, long fallback) {
    Long v = integer(row, name);
    return v == null ? fallback : v;
  }

  private static String textOr(Map<String, Object> row, String name) {
    String v = text(row, name);
    return v == null ? "" : v;
  }

  private static StoredJob job(Map<String, Object> row) {
    String name = textOr(row, "name");
    Object value;
    try {
      value = Json.parse(textOr(row, "definition"));
    } catch (Json.JsonException e) {
      throw new IllegalStateException("job " + name + ": " + e.getMessage(), e);
    }
    // JSON of another shape (another writer's, or a hand edit) is a definition with nothing in
    // it, as the SDK reads it: one such row must not fail every read of the jobs.
    Definition definition = Definition.of(value instanceof JsObject o ? o : new JsObject());
    return new StoredJob(
        name, definition, integer(row, "created_at", 0), integer(row, "updated_at", 0));
  }

  private static Run run(Map<String, Object> row) {
    String id = textOr(row, "id");
    Metrics metrics = Metrics.empty();
    String metricsText = text(row, "metrics");
    if (metricsText != null) {
      try {
        // Metrics another writer stored that are not all numbers keep the ones that are, so one
        // such row (a running one especially, which every check reads) cannot fail the reads it
        // is part of.
        metrics = Metrics.lenient(Json.parse(metricsText));
      } catch (Json.JsonException e) {
        throw new IllegalStateException("run " + id + ": " + e.getMessage(), e);
      }
    }
    return new Run(
        id,
        textOr(row, "job"),
        RunStatus.of(textOr(row, "status")),
        integer(row, "started_at", 0),
        integer(row, "finished_at"),
        integer(row, "duration_ms"),
        text(row, "error"),
        text(row, "output"),
        metrics,
        textOr(row, "trigger"));
  }

  private List<Run> runs(String text, List<Param> params) throws SQLException {
    List<Run> out = new ArrayList<>();
    for (Map<String, Object> row : query(text, params)) {
      out.add(run(row));
    }
    return out;
  }

  /** Runs statements, each with {@code params}, in one transaction of the store's own. */
  private void transaction(List<String> statements, List<Param> params, @Nullable String lockKey)
      throws SQLException {
    with(
        c -> {
          c.setAutoCommit(false);
          try {
            if (lockKey != null) {
              try (PreparedStatement ps =
                  c.prepareStatement("SELECT pg_advisory_xact_lock(hashtext(?))")) {
                ps.setString(1, lockKey);
                ps.execute();
              }
            }
            for (String statement : statements) {
              update(c, statement, params);
            }
            c.commit();
          } catch (SQLException | RuntimeException e) {
            try {
              c.rollback();
            } catch (SQLException rollback) {
              e.addSuppressed(rollback);
            }
            throw e;
          } finally {
            c.setAutoCommit(true);
          }
          return null;
        });
  }

  private static List<Param> insertRunParams(Run r) {
    return List.of(
        new Text(r.id()),
        new Text(r.job()),
        new Text(r.status().value()),
        new Int(r.startedAt()),
        new Int(r.finishedAt()),
        new Int(r.durationMs()),
        new Text(r.error()),
        new Text(r.output()),
        new JsonText(r.metrics().toJson()),
        new Text(r.trigger()));
  }

  private static List<Param> updateRunParams(Run r) {
    return List.of(
        new Text(r.status().value()),
        new Int(r.finishedAt()),
        new Int(r.durationMs()),
        new Text(r.error()),
        new Text(r.output()),
        new JsonText(r.metrics().toJson()),
        new Text(r.id()));
  }

  // ---- the store

  /**
   * Makes the tables. On Postgres many processes starting at once would race {@code CREATE TABLE IF
   * NOT EXISTS}, which Postgres can refuse with a unique violation on {@code pg_type}, so they take
   * turns under an advisory lock per prefix, in one transaction.
   */
  @Override
  public void init() throws SQLException {
    List<String> statements = Sql.schema(dialect, prefix);
    if (dialect == Dialect.POSTGRES) {
      transaction(statements, List.of(), "cronwatch:" + prefix);
      return;
    }
    with(
        c -> {
          for (String statement : statements) {
            try (Statement s = c.createStatement()) {
              s.execute(statement);
            }
          }
          return null;
        });
  }

  @Override
  public void upsertJob(Definition definition, long now) throws SQLException {
    run(
        sql.upsertJob,
        List.of(
            new Text(definition.name()),
            new JsonText(definition.toJson()),
            new Int(now),
            new Int(now)));
  }

  @Override
  public @Nullable StoredJob getJob(String name) throws SQLException {
    List<Map<String, Object>> rows = query(sql.getJob, List.of(new Text(name)));
    return rows.isEmpty() ? null : job(rows.get(0));
  }

  @Override
  public List<StoredJob> listJobs() throws SQLException {
    List<StoredJob> out = new ArrayList<>();
    for (Map<String, Object> row : query(sql.listJobs, List.of())) {
      out.add(job(row));
    }
    return out;
  }

  /** Removes the job, its runs and its state in one transaction. */
  @Override
  public void deleteJob(String name) throws SQLException {
    transaction(
        List.of(sql.deleteRuns, sql.deleteState, sql.deleteJob), List.of(new Text(name)), null);
  }

  @Override
  public void insertRun(Run run) throws SQLException {
    run(sql.insertRun, insertRunParams(run));
  }

  @Override
  public void updateRun(Run run) throws SQLException {
    run(sql.updateRun, updateRunParams(run));
  }

  @Override
  public boolean updateRunIf(Run run, List<RunStatus> from) throws SQLException {
    if (from.isEmpty()) {
      return false;
    }
    List<Param> params = new ArrayList<>(updateRunParams(run));
    for (RunStatus s : from) {
      params.add(new Text(s.value()));
    }
    return run(sql.updateRunIf(from.size()), params) > 0;
  }

  /** Deletes a run only while it is of {@code job} and in {@code status}, in one statement. */
  @Override
  public boolean deleteRunIf(String id, String job, RunStatus status) throws SQLException {
    return run(sql.deleteRunIf, List.of(new Text(id), new Text(job), new Text(status.value()))) > 0;
  }

  @Override
  public @Nullable Run getRun(String id) throws SQLException {
    List<Run> out = runs(sql.getRun, List.of(new Text(id)));
    return out.isEmpty() ? null : out.get(0);
  }

  @Override
  public List<Run> listRuns(String job, int limit) throws SQLException {
    return runs(sql.listRuns, List.of(new Text(job), new Int((long) limit)));
  }

  @Override
  public List<Run> runningRuns() throws SQLException {
    return runs(sql.runningRuns, List.of());
  }

  /**
   * The job's state. A state that is not JSON, or not an object, fails the read.
   *
   * @throws SQLException when the database fails
   */
  @Override
  public @Nullable JobState getState(String job) throws SQLException {
    List<Map<String, Object>> rows = query(sql.getState, List.of(new Text(job)));
    if (rows.isEmpty()) {
      return null;
    }
    return JobState.fromJson(textOr(rows.get(0), "state"));
  }

  @Override
  public void setState(JobState state) throws SQLException {
    run(sql.setState, List.of(new Text(state.job()), new JsonText(state.toJson())));
  }

  @Override
  public boolean compareAndSetState(JobState state, long expected) throws SQLException {
    String body = state.toJson();
    if (expected != 0) {
      return run(
              sql.casUpdate, List.of(new JsonText(body), new Text(state.job()), new Int(expected)))
          > 0;
    }
    return run(sql.casInsert, List.of(new Text(state.job()), new JsonText(body))) > 0;
  }

  @Override
  public long prune(long before) throws SQLException {
    return run(sql.prune, List.of(new Int(before)));
  }

  /**
   * Closes SQLite's connection, which the next use opens again. The data source is the app's, and
   * stays open.
   */
  @Override
  public void close() throws SQLException {
    lock.lock();
    try {
      Connection c = connection;
      connection = null;
      if (c != null) {
        c.close();
      }
    } finally {
      lock.unlock();
    }
  }
}
