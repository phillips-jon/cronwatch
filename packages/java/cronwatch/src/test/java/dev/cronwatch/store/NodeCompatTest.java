package dev.cronwatch.store;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertTrue;
import static org.junit.jupiter.api.Assumptions.assumeTrue;

import dev.cronwatch.CheckResult;
import dev.cronwatch.Cronwatch;
import dev.cronwatch.Definition;
import dev.cronwatch.Fixtures;
import dev.cronwatch.Job;
import dev.cronwatch.JobOptions;
import dev.cronwatch.JobState;
import dev.cronwatch.Run;
import dev.cronwatch.StoredJob;
import dev.cronwatch.json.JsObject;
import dev.cronwatch.json.Json;
import java.io.IOException;
import java.io.InputStream;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.sql.Connection;
import java.sql.PreparedStatement;
import java.sql.ResultSet;
import java.sql.SQLException;
import java.util.ArrayList;
import java.util.List;
import java.util.Objects;
import java.util.concurrent.CopyOnWriteArrayList;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicLong;
import org.jspecify.annotations.Nullable;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;

/**
 * A Node process and a Java process sharing one SQLite file: the SDK's store (from the built
 * packages/sdk/dist) and {@link SqlStore} replay the same store calls (shared_store.json, the Ruby,
 * Python, Go, and Rust ports' fixture), and each must read what the other wrote exactly as it reads
 * its own, down to the bytes and SQLite type of every column; the tables are the same whoever makes
 * them; and the two take turns on one job's state version.
 *
 * <p>Needs node on the PATH, the SDK built, and its SQLite driver installed ({@code npm ci && npm
 * run build} at the repository root); skipped, with the reason, without them.
 */
class NodeCompatTest {
  @TempDir Path dir;

  private Path script;
  private Path fixturePath;
  private JsObject fixture;

  private static Path dist() {
    return Fixtures.repo().resolve("packages/sdk/dist");
  }

  /** Why the test cannot run here, or null when it can. */
  private static @Nullable String missing() {
    try {
      Process p = new ProcessBuilder("node", "--version").redirectErrorStream(true).start();
      p.getInputStream().readAllBytes();
      if (!p.waitFor(60, TimeUnit.SECONDS) || p.exitValue() != 0) {
        return "node does not run";
      }
    } catch (IOException e) {
      return "node is not on the PATH";
    } catch (InterruptedException e) {
      Thread.currentThread().interrupt();
      return "interrupted";
    }
    if (!Files.exists(dist().resolve("sqlite.js"))) {
      return "packages/sdk/dist is not built: run `npm ci && npm run build` at the repository root";
    }
    return null;
  }

  @BeforeEach
  void setUp() throws IOException {
    String why = missing();
    assumeTrue(why == null, () -> "Node compatibility skipped: " + why);
    script = dir.resolve("node_store.mjs");
    fixturePath = dir.resolve("shared_store.json");
    copy("node_store.mjs", script);
    copy("shared_store.json", fixturePath);
    fixture = Json.parseObject(Files.readString(fixturePath, StandardCharsets.UTF_8));
  }

  private static void copy(String resource, Path to) throws IOException {
    try (InputStream in =
        Objects.requireNonNull(NodeCompatTest.class.getResourceAsStream(resource), resource)) {
      Files.write(to, in.readAllBytes());
    }
  }

  /** Runs node_store.mjs and answers what it printed. */
  private String node(String action, Path file, String prefix, String... args)
      throws IOException, InterruptedException {
    List<String> command = new ArrayList<>();
    command.add("node");
    command.add(script.toString());
    command.add(dist().toString());
    command.add(action);
    command.add(file.toString());
    command.add(prefix);
    command.addAll(List.of(args));
    Path err = dir.resolve("node.err");
    Process p =
        new ProcessBuilder(command).redirectError(err.toFile()).directory(dir.toFile()).start();
    byte[] out = p.getInputStream().readAllBytes();
    assertTrue(p.waitFor(120, TimeUnit.SECONDS), "node " + action + " finished");
    assertEquals(0, p.exitValue(), () -> "node " + action + ": " + read(err));
    return new String(out, StandardCharsets.UTF_8);
  }

  private static String read(Path file) {
    try {
      return Files.readString(file, StandardCharsets.UTF_8);
    } catch (IOException e) {
      return e.toString();
    }
  }

  private static SqlStore store(Path file, String prefix) {
    return SqliteStoreTest.store(file, prefix);
  }

  private static List<String> strings(@Nullable Object v) {
    List<String> out = new ArrayList<>();
    if (v instanceof List<?> list) {
      for (Object s : list) {
        out.add(String.valueOf(s));
      }
    }
    return out;
  }

  private List<String> readList(String key) {
    return strings(Fixtures.object(fixture, "read").get(key));
  }

  /** Replays the fixture's store calls, as node_store.mjs {@code write} does. */
  private String javaWrite(SqlStore store) throws Exception {
    store.init();
    List<Object> pruned = new ArrayList<>();
    for (JsObject step : Fixtures.objects(fixture, "ops")) {
      switch (String.valueOf(step.get("op"))) {
        case "upsertJob" ->
            store.upsertJob(
                Definition.of(Fixtures.object(step, "definition")), Fixtures.integer(step, "now"));
        case "insertRun" -> store.insertRun(Run.fromValue(step.get("run")));
        case "updateRun" -> store.updateRun(Run.fromValue(step.get("run")));
        case "setState" -> store.setState(JobState.fromValue(step.get("state")));
        case "deleteJob" -> store.deleteJob(String.valueOf(step.get("name")));
        case "prune" -> pruned.add(store.prune(Fixtures.integer(step, "before")));
        default -> throw new AssertionError("unknown op " + step.get("op"));
      }
    }
    return new JsObject().set("pruned", pruned).toJson();
  }

  private static @Nullable JsObject stored(@Nullable StoredJob j) {
    if (j == null) {
      return null;
    }
    return new JsObject()
        .set("name", j.name())
        .set("definition", j.definition().toObject())
        .set("createdAt", j.createdAt())
        .set("updatedAt", j.updatedAt());
  }

  private static List<Object> runs(List<Run> runs) {
    List<Object> out = new ArrayList<>();
    for (Run r : runs) {
      out.add(r.toValue());
    }
    return out;
  }

  /** What node_store.mjs {@code read} prints, from the Java store, in the same key order. */
  private String javaRead(SqlStore s) throws Exception {
    List<Object> jobs = new ArrayList<>();
    for (StoredJob j : s.listJobs()) {
      jobs.add(stored(j));
    }
    JsObject job = new JsObject();
    JsObject runs = new JsObject();
    JsObject limited = new JsObject();
    JsObject last = new JsObject();
    JsObject state = new JsObject();
    for (String name : readList("jobs")) {
      job.set(name, stored(s.getJob(name)));
      runs.set(name, runs(s.listRuns(name, 100)));
      limited.set(name, runs(s.listRuns(name, 1)));
      Run l = s.lastRun(name);
      last.set(name, l == null ? null : l.toValue());
      JobState st = s.getState(name);
      state.set(name, st == null ? null : st.toValue());
    }
    JsObject byId = new JsObject();
    for (String id : readList("runs")) {
      Run r = s.getRun(id);
      byId.set(id, r == null ? null : r.toValue());
    }
    return new JsObject()
        .set("jobs", jobs)
        .set("job", job)
        .set("runs", runs)
        .set("limited", limited)
        .set("last", last)
        .set("state", state)
        .set("running", runs(s.runningRuns()))
        .set("run", byId)
        .toJson();
  }

  private static List<String> query(Path file, String sql, @Nullable String param)
      throws SQLException {
    List<String> out = new ArrayList<>();
    try (Connection c = SqliteStoreTest.source(file.toString()).getConnection();
        PreparedStatement ps = c.prepareStatement(sql)) {
      if (param != null) {
        ps.setString(1, param);
      }
      try (ResultSet rs = ps.executeQuery()) {
        int n = rs.getMetaData().getColumnCount();
        while (rs.next()) {
          List<String> values = new ArrayList<>();
          for (int i = 1; i <= n; i++) {
            values.add(rs.getString(i));
          }
          out.add(String.join(" | ", values));
        }
      }
    }
    return out;
  }

  private static String typed(String... columns) {
    List<String> out = new ArrayList<>();
    for (String c : columns) {
      out.add("quote(" + c + "), typeof(" + c + ")");
    }
    return String.join(", ", out);
  }

  /** Every row of the three tables with each value's SQLite type, the JSON as the text held. */
  private static List<String> rawRows(Path file, String p) throws SQLException {
    List<String> out = new ArrayList<>();
    out.addAll(
        query(
            file,
            "SELECT "
                + typed("name", "definition", "created_at", "updated_at")
                + " FROM "
                + p
                + "jobs ORDER BY created_at, name",
            null));
    out.addAll(
        query(
            file,
            "SELECT "
                + typed(
                    "rowid",
                    "id",
                    "job",
                    "status",
                    "started_at",
                    "finished_at",
                    "duration_ms",
                    "error",
                    "output",
                    "metrics",
                    "trigger")
                + " FROM "
                + p
                + "runs ORDER BY rowid",
            null));
    out.addAll(
        query(file, "SELECT " + typed("job", "state") + " FROM " + p + "state ORDER BY job", null));
    return out;
  }

  private static List<String> schemaOf(Path file, String p) throws SQLException {
    List<String> out = new ArrayList<>();
    for (String row :
        query(
            file,
            "SELECT type || '|' || name || '|' || tbl_name || '|' || coalesce(sql, '') FROM"
                + " sqlite_master WHERE name LIKE ? ORDER BY name",
            p + "%")) {
      out.add(row.replace(p, "PREFIX_"));
    }
    return out;
  }

  @Test
  void javaReadsWhatNodeWrote() throws Exception {
    Path file = dir.resolve("shared.db");
    assertEquals("{\"pruned\":[1]}", node("write", file, "cw_", fixturePath.toString()));
    try (SqlStore s = store(file, "cw_")) {
      s.init();
      String nodeView = node("read", file, "cw_", fixturePath.toString());
      assertFalse(nodeView.contains("never stored"), "an update of a run that is not there");
      assertEquals(nodeView, javaRead(s), "Java reads Node's rows differently");
    }
  }

  @Test
  void nodeReadsWhatJavaWroteAndTheRowsAreTheSame() throws Exception {
    Path nodeFile = dir.resolve("node.db");
    Path javaFile = dir.resolve("java.db");
    String written = node("write", nodeFile, "cw_", fixturePath.toString());
    try (SqlStore s = store(javaFile, "cw_")) {
      assertEquals(written, javaWrite(s), "pruned");
    }
    assertEquals(
        node("read", nodeFile, "cw_", fixturePath.toString()),
        node("read", javaFile, "cw_", fixturePath.toString()),
        "Node reads Java's rows differently from its own");
    List<String> javaRows = rawRows(javaFile, "cw_");
    List<String> nodeRows = rawRows(nodeFile, "cw_");
    assertFalse(javaRows.isEmpty());
    assertEquals(nodeRows, javaRows, "every column's bytes and type");
  }

  @Test
  void theTablesAreTheSameWhoeverCreatesThem() throws Exception {
    Path file = dir.resolve("both.db");
    node("write", file, "node_", fixturePath.toString());
    try (SqlStore s = store(file, "java_")) {
      s.init();
    }
    List<String> java = schemaOf(file, "java_");
    assertEquals(5, java.size(), java.toString());
    assertEquals(schemaOf(file, "node_"), java, "schema");
  }

  private static JobState v(long version, long failures, String job) {
    return JobState.fromJson(
        "{\"job\":\""
            + job
            + "\",\"open\":{},\"consecutiveFailures\":"
            + failures
            + ",\"silencedUntil\":null,\"lastAlertAt\":null,\"version\":"
            + version
            + "}");
  }

  private record Cas(boolean written, String state) {}

  private Cas nodeCas(Path file, JobState state, long expected) throws Exception {
    JsObject o =
        Json.parseObject(node("cas", file, "cw_", state.toJson(), Long.toString(expected)));
    return new Cas(Boolean.TRUE.equals(o.get("written")), Json.stringify(o.get("state")));
  }

  @Test
  void nodeAndJavaTakeTurnsOnOneJobsStateVersion() throws Exception {
    Path file = dir.resolve("versions.db");
    try (SqlStore s = store(file, "cw_")) {
      s.init();
      assertTrue(s.compareAndSetState(v(1, 1, "v"), 0), "Java writes the first version");
      assertFalse(nodeCas(file, v(1, 9, "v"), 0).written(), "Node's write from before is refused");
      Cas fresh = nodeCas(file, v(2, 2, "v"), 1);
      assertTrue(
          fresh.written() && fresh.state().contains("\"version\":2"),
          "Node's fresh write " + fresh);
      assertFalse(s.compareAndSetState(v(2, 7, "v"), 1), "Java's stale write is refused");
      assertTrue(s.compareAndSetState(v(3, 3, "v"), 2), "Java writes the next version");
      Cas stale = nodeCas(file, v(3, 0, "v"), 2);
      JobState stored = s.getState("v");
      assertFalse(stale.written(), "Node's stale write is refused");
      assertEquals(Objects.requireNonNull(stored).toJson(), stale.state(), "Node reads Java's");
      // State written before versions existed counts as 0 for both.
      s.setState(
          JobState.fromJson(
              "{\"job\":\"old\",\"open\":{},\"consecutiveFailures\":4,\"silencedUntil\":null,"
                  + "\"lastAlertAt\":null}"));
      assertTrue(nodeCas(file, v(1, 5, "old"), 0).written(), "Node writes over it");
      JobState old = s.getState("old");
      assertEquals(1L, old == null ? null : old.version());
    }
  }

  /**
   * A Java client finishes a run of a job Node wrote and checks every job; then a Node client takes
   * a turn on the same file; each reads the other's run and state, and the Java client checks again
   * with nothing to report.
   */
  @Test
  void nodeCarriesOnFromJavaAndJavaFromNode() throws Exception {
    Path file = dir.resolve("turns.db");
    node("write", file, "cw_", fixturePath.toString());
    AtomicLong clock = new AtomicLong(1_767_606_100_000L);
    List<String> errors = new CopyOnWriteArrayList<>();
    SqlStore s = store(file, "cw_");
    try (Cronwatch cw =
        Cronwatch.builder()
            .store(s)
            .alerts(List.of())
            .noCronSecret()
            .clock(clock::get)
            .onError((where, e) -> errors.add(where + ": " + e.getMessage()))
            .noShutdownHook()
            .build()) {
      Job job =
          cw.job(
              "every-5",
              JobOptions.builder().schedule("every 5m").timeout("2m").maxDuration("90s"));
      job.run(ctx -> ctx.log("from java"));
      clock.addAndGet(10 * 60_000);
      CheckResult result = cw.check();
      assertTrue(
          result.jobs().stream().anyMatch(j -> j.name().equals("nightly-report")),
          "checked " + result.jobs().size());
      assertEquals("from java", Objects.requireNonNull(s.lastRun("every-5")).output());
      String raw = node("read", file, "cw_", fixturePath.toString());
      JsObject view = Json.parseObject(raw);
      Object last = ((JsObject) Objects.requireNonNull(view.get("last"))).get("every-5");
      assertEquals("from java", ((JsObject) Objects.requireNonNull(last)).get("output"));
      assertEquals(raw, javaRead(s), "after Java's turn, Java and Node read the file differently");

      clock.addAndGet(10 * 60_000);
      String nodeRun = node("run", file, "cw_", Long.toString(clock.get()));
      assertTrue(nodeRun.contains("\"every-5\""), "node run " + nodeRun);
      assertEquals("from node", Objects.requireNonNull(s.lastRun("every-5")).output());
      assertEquals(
          node("read", file, "cw_", fixturePath.toString()), javaRead(s), "after Node's turn");
      assertFalse(cw.check().jobs().isEmpty(), "no jobs checked");
      assertTrue(errors.isEmpty(), "errors: " + errors);
    }
  }
}
