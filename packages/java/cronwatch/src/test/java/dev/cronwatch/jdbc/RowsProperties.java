package dev.cronwatch.jdbc;

import static org.junit.jupiter.api.Assertions.assertEquals;

import dev.cronwatch.Alert;
import dev.cronwatch.Channel;
import dev.cronwatch.Cronwatch;
import dev.cronwatch.Gen;
import dev.cronwatch.JobState;
import dev.cronwatch.Metrics;
import dev.cronwatch.Run;
import dev.cronwatch.StoredJob;
import dev.cronwatch.internal.output.Output;
import dev.cronwatch.json.JsObject;
import dev.cronwatch.json.Json;
import dev.cronwatch.store.MemoryStore;
import dev.cronwatch.store.Store;
import java.nio.file.Path;
import java.sql.Connection;
import java.sql.PreparedStatement;
import java.sql.SQLException;
import java.sql.Statement;
import java.util.ArrayList;
import java.util.List;
import java.util.Objects;
import java.util.concurrent.CopyOnWriteArrayList;
import org.jspecify.annotations.Nullable;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;
import org.sqlite.SQLiteDataSource;

/**
 * Stored rows, a door untrusted input comes through: rows another writer left in the three tables
 * (valid JSON of any shape, and column values of any SQLite type) are read by the store, and by a
 * check and the dashboard's reads over them, without a throw; and what the store reads writes back,
 * to SQLite and to the memory store, as a row that reads the same.
 */
class RowsProperties {
  @TempDir Path dir;

  private static final List<String> STATUSES =
      List.of("running", "ok", "failed", "timeout", "", "RUNNING", "odd");

  private static final List<String> CONDITIONS =
      List.of("missed", "failed", "stuck", "slow", "overBudget", "", "odd");

  private static final List<String> DEFINITION_KEYS =
      List.of(
          "name",
          "schedule",
          "timezone",
          "grace",
          "timeout",
          "maxDuration",
          "expect",
          "budget",
          "tags",
          "description",
          "failuresBeforeAlert",
          "other");

  private static final List<Object> SCHEDULES =
      List.of(
          "0 2 * * *",
          "* * * * *",
          "every 5m",
          "every 0s",
          "0 0 30 2 *",
          "@daily",
          "junk",
          "1e400",
          "every 99999999999999999999d");

  private static final List<Object> DURATIONS =
      List.of("15m", "0s", "1h30m", "99999999999999999999d", "x", "-5m", "");

  /** Any JSON value, nested at most {@code depth} deep. */
  private static @Nullable Object value(Gen g, int depth) {
    int pick = (int) g.between(0, depth <= 0 ? 5 : 7);
    return switch (pick) {
      case 0 -> null;
      case 1 -> g.bool();
      case 2 -> finite(g.anyDouble());
      case 3 -> (double) g.anyLong();
      case 4 -> g.anyString(12);
      case 5 -> g.oneOf(List.of("", "running", "0 2 * * *", "15m", "UTC"));
      case 6 -> {
        List<@Nullable Object> list = new ArrayList<>();
        for (long i = g.between(0, 3); i > 0; i--) {
          list.add(value(g, depth - 1));
        }
        yield list;
      }
      default -> {
        JsObject o = new JsObject();
        for (long i = g.between(0, 3); i > 0; i--) {
          o.set(g.anyString(6), value(g, depth - 1));
        }
        yield o;
      }
    };
  }

  private static double finite(double d) {
    return Double.isFinite(d) ? d : 0;
  }

  /** A value for a definition's key: often one of its own kind, often anything. */
  private static @Nullable Object field(Gen g, String key) {
    if (g.bool()) {
      return value(g, 2);
    }
    return switch (key) {
      case "schedule" -> g.oneOf(SCHEDULES);
      case "timezone" -> g.oneOf(List.of("UTC", "Europe/London", "nowhere", "+05:30"));
      case "grace", "timeout", "maxDuration" ->
          g.bool() ? g.oneOf(DURATIONS) : (Object) finite(g.anyDouble());
      case "expect" ->
          g.oneOf(
              List.of(
                  "contains \"ok\"",
                  "matches /ok/i",
                  "matches /(/",
                  "custom function",
                  "odd",
                  "contains x"));
      case "budget" -> new JsObject().set(g.anyString(4), finite(g.anyDouble()));
      case "tags" -> List.of(g.anyString(5), "pg_cron");
      case "failuresBeforeAlert" -> (double) g.between(-3, 5);
      default -> value(g, 2);
    };
  }

  private static JsObject definition(Gen g, String name) {
    JsObject o = new JsObject();
    if (g.between(0, 4) > 0) {
      o.set("name", name);
    }
    for (String key : DEFINITION_KEYS) {
      if (!key.equals("name") && g.bool()) {
        o.set(key, field(g, key));
      }
    }
    return o;
  }

  private static JsObject alertish(Gen g, String job) {
    JsObject a = new JsObject();
    a.set("job", g.bool() ? job : value(g, 1));
    a.set("type", g.oneOf(List.of("failed", "missed", "recovered", "odd")));
    a.set("at", g.bool() ? (Object) (double) g.anyLong() : value(g, 1));
    a.set("title", g.bool() ? g.anyString(10) : value(g, 1));
    a.set("message", g.bool() ? g.anyString(10) : value(g, 1));
    if (g.bool()) {
      a.set("run", value(g, 2));
    }
    if (g.bool()) {
      a.set("definition", value(g, 2));
    }
    return a;
  }

  private static JsObject state(Gen g, String job) {
    JsObject o = new JsObject();
    if (g.between(0, 4) > 0) {
      o.set("job", g.bool() ? job : value(g, 1));
    }
    if (g.bool()) {
      if (g.bool()) {
        JsObject open = new JsObject();
        for (long i = g.between(0, 3); i > 0; i--) {
          open.set(g.oneOf(CONDITIONS), g.bool() ? (Object) (double) g.anyLong() : value(g, 1));
        }
        o.set("open", open);
      } else {
        o.set("open", value(g, 1));
      }
    }
    for (String key : List.of("consecutiveFailures", "silencedUntil", "lastAlertAt", "version")) {
      if (g.bool()) {
        o.set(
            key,
            switch ((int) g.between(0, 3)) {
              case 0 -> (double) g.anyLong();
              case 1 -> finite(g.anyDouble());
              default -> value(g, 1);
            });
      }
    }
    if (g.bool()) {
      List<@Nullable Object> pending = new ArrayList<>();
      for (long i = g.between(0, 2); i > 0; i--) {
        pending.add(g.bool() ? g.oneOf(CONDITIONS) : value(g, 1));
      }
      o.set("pendingRecovery", g.bool() ? pending : value(g, 1));
    }
    if (g.bool()) {
      List<@Nullable Object> queued = new ArrayList<>();
      for (long i = g.between(0, 2); i > 0; i--) {
        queued.add(g.bool() ? alertish(g, job) : value(g, 1));
      }
      o.set("undelivered", g.bool() ? queued : value(g, 1));
    }
    if (g.bool()) {
      o.set(g.anyString(5), value(g, 2));
    }
    return o;
  }

  /** A column value of any SQLite type: an integer, a real, text or (where allowed) NULL. */
  private static @Nullable Object column(Gen g, boolean nullable) {
    return switch ((int) g.between(0, 6)) {
      case 0 -> nullable ? null : g.anyLong();
      case 1 -> finite(g.anyDouble());
      case 2 -> g.oneOf(List.of("12", " 7 ", "1e3", "x", "", "9223372036854775808", "-0"));
      default -> g.bool() ? g.anyLong() : g.between(-1000, 1_800_000_000_000L);
    };
  }

  private static void bind(PreparedStatement ps, int at, @Nullable Object v) throws SQLException {
    ps.setObject(at, v);
  }

  private static void clear(Connection c, String p) throws SQLException {
    try (Statement s = c.createStatement()) {
      s.execute("DELETE FROM " + p + "jobs");
      s.execute("DELETE FROM " + p + "runs");
      s.execute("DELETE FROM " + p + "state");
    }
  }

  /** Writes a case's rows raw, as another writer would, and answers the job names written. */
  private static List<String> write(Gen g, Connection c, String p) throws SQLException {
    clear(c, p);
    List<String> names = new ArrayList<>();
    long jobs = g.between(1, 3);
    for (int i = 0; i < jobs; i++) {
      String name = g.bool() ? "job-" + i : g.anyString(8) + "~" + i;
      names.add(name);
      Object definition =
          g.between(0, 6) == 0 ? value(g, 2) : definition(g, g.bool() ? name : "other");
      try (PreparedStatement ps =
          c.prepareStatement(
              "INSERT INTO "
                  + p
                  + "jobs (name, definition, created_at, updated_at) VALUES (?, ?, ?, ?)")) {
        bind(ps, 1, name);
        bind(ps, 2, Json.stringify(definition));
        bind(ps, 3, column(g, false));
        bind(ps, 4, column(g, false));
        ps.execute();
      }
      if (g.bool()) {
        try (PreparedStatement ps =
            c.prepareStatement("INSERT INTO " + p + "state (job, state) VALUES (?, ?)")) {
          bind(ps, 1, name);
          bind(ps, 2, Json.stringify(state(g, name)));
          ps.execute();
        }
      }
      for (long r = g.between(0, 4); r > 0; r--) {
        try (PreparedStatement ps =
            c.prepareStatement(
                "INSERT INTO "
                    + p
                    + "runs (id, job, status, started_at, finished_at, duration_ms, error,"
                    + " output, metrics, trigger) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)")) {
          bind(ps, 1, name + "-" + r + "-" + g.anyString(4));
          bind(ps, 2, name);
          bind(ps, 3, g.oneOf(STATUSES));
          bind(ps, 4, column(g, false));
          bind(ps, 5, column(g, true));
          bind(ps, 6, column(g, true));
          bind(ps, 7, g.bool() ? null : g.anyString(20));
          bind(ps, 8, g.bool() ? null : g.anyString(20));
          bind(ps, 9, Json.stringify(g.bool() ? value(g, 2) : metrics(g)));
          bind(ps, 10, g.bool() ? "run" : g.anyString(6));
          ps.execute();
        }
      }
    }
    return names;
  }

  private static JsObject metrics(Gen g) {
    JsObject o = new JsObject();
    for (long i = g.between(0, 3); i > 0; i--) {
      o.set(g.anyString(5), g.bool() ? (Object) finite(g.anyDouble()) : value(g, 1));
    }
    return o;
  }

  private static SQLiteDataSource source(Path file) {
    SQLiteDataSource ds = new SQLiteDataSource();
    ds.setUrl("jdbc:sqlite:" + file);
    return ds;
  }

  /**
   * Whether a reported error is a slip of the port's rather than the SDK's own answer to a row of
   * another shape: a definition whose schedule is not text fails its job's check in the SDK too
   * ({@code schedule.trim is not a function}), and that is reported, as it should be; a null, a
   * cast, arithmetic or an index out of range is not.
   */
  private static boolean slip(@Nullable Throwable e) {
    for (Throwable t = e; t != null; t = t.getCause()) {
      if (t instanceof NullPointerException
          || t instanceof ClassCastException
          || t instanceof ArithmeticException
          || t instanceof IndexOutOfBoundsException
          || t instanceof NumberFormatException
          || t instanceof UnsupportedOperationException
          || t instanceof java.time.DateTimeException
          || t instanceof Error) {
        return true;
      }
    }
    return false;
  }

  /** What one read of the rows gave. */
  private record Read(List<StoredJob> jobs, List<Run> runs, List<JobState> states) {}

  /** Every read the store offers, over every name written. */
  private static Read read(Store store, List<String> names) throws Exception {
    List<StoredJob> jobs = new ArrayList<>(store.listJobs());
    List<Run> runs = new ArrayList<>();
    List<JobState> states = new ArrayList<>();
    for (String name : names) {
      store.getJob(name);
      for (Run r : store.listRuns(name, 100)) {
        runs.add(r);
        store.getRun(r.id());
      }
      JobState s = store.getState(name);
      // A state names its job inside it, which is where it is written back: one that names
      // another job (or none) is read, but not written back under the row it came from.
      if (s != null && s.job().equals(name)) {
        states.add(s);
      }
    }
    store.runningRuns();
    return new Read(jobs, runs, states);
  }

  private static void writeBack(Store store, Read read) throws Exception {
    for (StoredJob j : read.jobs()) {
      if (j.name().equals(j.definition().name())) {
        store.upsertJob(j.definition(), j.createdAt());
      }
    }
    for (Run r : read.runs()) {
      store.insertRun(r);
    }
    for (JobState s : read.states()) {
      store.setState(s);
    }
  }

  /**
   * Reads back what was written, but for NULs: every store writes a run's trigger, output, error
   * and metric names, and every key and string of a definition and a state, without them.
   */
  private static void readsBackTheSame(Store store, Read read) throws Exception {
    for (StoredJob j : read.jobs()) {
      if (j.name().equals(j.definition().name())) {
        StoredJob back = Objects.requireNonNull(store.getJob(j.name()), j.name());
        assertEquals(Output.stripJsonNul(j.definition().toJson()), back.definition().toJson());
      }
    }
    for (Run r : read.runs()) {
      Run written =
          new Run(
              r.id(),
              r.job(),
              r.status(),
              r.startedAt(),
              r.finishedAt(),
              r.durationMs(),
              Output.stripNulOrNull(r.error()),
              Output.stripNulOrNull(r.output()),
              Metrics.lenient(Json.parse(Output.stripJsonNul(r.metrics().toJson()))),
              Output.stripNul(r.trigger()));
      assertEquals(written.toJson(), Objects.requireNonNull(store.getRun(r.id()), r.id()).toJson());
    }
    for (JobState s : read.states()) {
      assertEquals(
          Output.stripJsonNul(s.toJson()),
          Objects.requireNonNull(store.getState(s.job()), s.job()).toJson());
    }
  }

  @Test
  void foreignRowsAreReadCheckedAndWrittenBackAsTheyRead() throws Exception {
    Path file = dir.resolve("rows.db");
    String p = "cronwatch_";
    SqlStore store = SqlStore.sqlite(source(file));
    store.init();
    try (Connection raw = source(file).getConnection()) {
      Gen.check(
          41,
          150,
          g -> {
            try {
              List<String> names = write(g, raw, p);
              Read first = read(store, names);

              // A check and the dashboard's reads over the rows as another writer left them.
              List<Throwable> errors = new CopyOnWriteArrayList<>();
              List<Alert> sent = new CopyOnWriteArrayList<>();
              try (Cronwatch cw =
                  Cronwatch.builder()
                      .store(store)
                      .alert(Channel.of("capture", (alert, ctx) -> sent.add(alert)))
                      .noCronSecret()
                      .clock(() -> 1_800_000_000_000L)
                      .onError((where, e) -> errors.add(new AssertionError(where, e)))
                      .noShutdownHook()
                      .build()) {
                cw.check();
                cw.jobs();
                cw.jobsWithRuns(20);
                for (String name : names) {
                  cw.jobSummary(name);
                  cw.runs(name, 20);
                }
              }
              for (Alert a : sent) {
                a.toJson();
              }
              for (Throwable e : errors) {
                if (slip(e.getCause())) {
                  throw new AssertionError("reported " + e.getMessage() + ": " + e.getCause(), e);
                }
              }

              // What was first read, written back to SQLite and to the memory store, reads the
              // same.
              clear(raw, p);
              writeBack(store, first);
              readsBackTheSame(store, first);
              MemoryStore memory = new MemoryStore();
              writeBack(memory, first);
              readsBackTheSame(memory, first);
            } catch (Exception e) {
              throw new AssertionError(e.toString(), e);
            }
          });
    } finally {
      // Windows will not delete the temporary directory while the file is open.
      store.close();
    }
  }
}
