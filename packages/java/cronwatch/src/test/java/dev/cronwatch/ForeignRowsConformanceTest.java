package dev.cronwatch;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertNotNull;

import dev.cronwatch.internal.evaluate.Evaluate;
import dev.cronwatch.json.JsObject;
import dev.cronwatch.json.Json;
import dev.cronwatch.store.SqlStore;
import dev.cronwatch.web.Request;
import dev.cronwatch.web.Routes;
import dev.cronwatch.web.RoutesOptions;
import java.nio.file.Path;
import java.sql.Connection;
import java.sql.PreparedStatement;
import java.sql.ResultSet;
import java.sql.Types;
import java.util.ArrayList;
import java.util.List;
import java.util.Map;
import java.util.Objects;
import java.util.TreeSet;
import java.util.concurrent.CopyOnWriteArrayList;
import org.jspecify.annotations.Nullable;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;
import org.sqlite.SQLiteDataSource;

/**
 * {@code conformance/store.json}'s {@code foreignRows}: rows a foreign, hand-edited or damaged
 * writer could leave in SQLite, each read leniently, and a check, a silence and every page over all
 * of them at once, where one affects only its own job.
 */
class ForeignRowsConformanceTest {
  @TempDir Path dir;

  private static final JsObject FIXTURE = Fixtures.object(Fixtures.load("store"), "foreignRows");

  private static SQLiteDataSource source(Path file) {
    SQLiteDataSource ds = new SQLiteDataSource();
    ds.setUrl("jdbc:sqlite:" + file);
    return ds;
  }

  /** Inserts one row with each value as SQLite holds it: text, an integer, a real or NULL. */
  private static void insert(Path file, String table, JsObject row) throws Exception {
    List<String> keys = row.keys();
    String sql =
        "INSERT INTO cronwatch_"
            + table
            + " ("
            + String.join(", ", keys)
            + ") VALUES ("
            + String.join(", ", keys.stream().map(k -> "?").toList())
            + ")";
    try (Connection c = source(file).getConnection();
        PreparedStatement ps = c.prepareStatement(sql)) {
      for (int i = 0; i < keys.size(); i++) {
        Object v = row.get(keys.get(i));
        switch (v) {
          case null -> ps.setNull(i + 1, Types.NULL);
          case String s -> ps.setString(i + 1, s);
          case Number n when n.doubleValue() == Math.rint(n.doubleValue()) ->
              ps.setLong(i + 1, n.longValue());
          case Number n -> ps.setDouble(i + 1, n.doubleValue());
          default -> throw new AssertionError("a value SQLite cannot hold as given: " + v);
        }
      }
      ps.executeUpdate();
    }
  }

  /** The state column as stored, parsed (5, [] and a foreign object read back as they are). */
  private static @Nullable Object rawState(Path file, String job) throws Exception {
    try (Connection c = source(file).getConnection();
        PreparedStatement ps =
            c.prepareStatement("SELECT state FROM cronwatch_state WHERE job = ?")) {
      ps.setString(1, job);
      try (ResultSet rs = ps.executeQuery()) {
        return rs.next() ? Json.parse(rs.getString(1)) : null;
      }
    }
  }

  private static JsObject jobValue(StoredJob job) {
    return new JsObject()
        .set("name", job.name())
        .set("definition", job.definition().toObject())
        .set("createdAt", job.createdAt())
        .set("updatedAt", job.updatedAt());
  }

  private static SqlStore store(Path file) throws Exception {
    SqlStore store = SqlStore.sqlite(source(file));
    store.init();
    return store;
  }

  @Test
  void eachForeignRowReadsLeniently() throws Exception {
    Fixtures.Failures fails = new Fixtures.Failures();
    int n = 0;
    for (JsObject c : Fixtures.objects(FIXTURE, "rows")) {
      Path file = dir.resolve("row-" + n++ + ".db");
      String table = Fixtures.string(c, "table");
      JsObject row = Fixtures.object(c, "row");
      String label = table + " " + row.toJson();
      try (SqlStore store = store(file)) {
        insert(file, table, row);
        switch (Objects.requireNonNullElse(table, "")) {
          case "jobs" -> {
            String name = Fixtures.string(row, "name");
            StoredJob got = Checks.readJob(assertNotNullAndGet(store.getJob(name), label));
            fails.same(label, jobValue(got), c.get("read"));
            fails.same(label + " readable", got.definition().readable(), c.get("readable"));
            List<Object> listed = new ArrayList<>();
            for (StoredJob j : store.listJobs()) {
              listed.add(jobValue(Checks.readJob(j)));
            }
            fails.same(label + " listed", listed, List.of(c.get("read")));
          }
          case "runs" -> {
            Run got = assertNotNullAndGet(store.getRun(Fixtures.string(row, "id")), label);
            fails.same(label, got.toValue(), c.get("read"));
            List<Object> listed = new ArrayList<>();
            for (Run r : store.listRuns(Fixtures.string(row, "job"), 10)) {
              listed.add(r.toValue());
            }
            fails.same(label + " listed", listed, List.of(c.get("read")));
          }
          default -> {
            String job = Fixtures.string(row, "job");
            fails.same(
                label, Evaluate.normalizeState(store.getState(job), job).toValue(), c.get("read"));
          }
        }
      }
    }
    assertEquals(28, n);
    fails.check("store");
  }

  @Test
  void aCheckASilenceAndEveryPageOverForeignRows() throws Exception {
    JsObject c = Fixtures.object(FIXTURE, "check");
    Path file = dir.resolve("check.db");
    List<String> names = new ArrayList<>();
    try (SqlStore store = store(file)) {
      List<JsObject> rows = Fixtures.objects(FIXTURE, "rows");
      List<JsObject> jobs = new ArrayList<>();
      List<JsObject> runs = new ArrayList<>();
      List<JsObject> states = new ArrayList<>();
      for (JsObject r : rows) {
        JsObject row = Fixtures.object(r, "row");
        switch (Objects.requireNonNullElse(Fixtures.string(r, "table"), "")) {
          case "jobs" -> jobs.add(row);
          case "runs" -> runs.add(row);
          default -> states.add(row);
        }
      }
      jobs.addAll(Fixtures.objects(c, "extraJobs"));
      runs.addAll(Fixtures.objects(c, "extraRuns"));
      for (JsObject row : jobs) {
        insert(file, "jobs", row);
        names.add(Fixtures.string(row, "name"));
      }
      for (JsObject row : runs) {
        insert(file, "runs", row);
      }
      for (JsObject row : states) {
        insert(file, "state", row);
      }
      List<String> errors = new CopyOnWriteArrayList<>();
      List<Alert> sent = new CopyOnWriteArrayList<>();
      long now = Fixtures.integer(c, "now");
      try (Cronwatch cw =
          Cronwatch.builder()
              .store(store)
              .alert(Channel.of("capture", (alert, ctx) -> sent.add(alert)))
              .noCronSecret()
              .clock(() -> now)
              .onError((where, e) -> errors.add(where))
              .noShutdownHook()
              .build()) {
        CheckResult result = cw.check();
        assertEquals(c.get("reported"), reported(errors, names), "reported by the check");
        List<Object> alerts = new ArrayList<>();
        for (Alert a : sent) {
          alerts.add(
              new JsObject().set("type", a.type().value()).set("job", a.job()).set("at", a.at()));
        }
        assertEquals(Json.stringify(c.get("alerts")), Json.stringify(alerts), "alerts");
        JsObject health = new JsObject();
        result.jobs().stream()
            .sorted((a, b) -> a.name().compareTo(b.name()))
            .forEach(j -> health.set(j.name(), j.health().value()));
        assertEquals(Json.stringify(c.get("health")), Json.stringify(health), "health");

        JsObject silence = Fixtures.object(c, "silence");
        String silenced = Fixtures.string(silence, "job");
        cw.silence(silenced, Fixtures.string(silence, "for"));
        assertEquals(silence.get("reported"), reported(errors, names), "reported by the silence");
        assertEquals(
            Json.stringify(silence.get("state")),
            Json.stringify(rawState(file, silenced)),
            "the silenced state");
        for (Map.Entry<String, @Nullable Object> e : Fixtures.object(c, "states").entries()) {
          assertEquals(
              Json.stringify(e.getValue()), Json.stringify(rawState(file, e.getKey())), e.getKey());
        }

        JsObject read = Fixtures.object(c, "read");
        Routes routes = cw.routes(RoutesOptions.builder().token("tok").build());
        for (JsObject page : Fixtures.objects(read, "pages")) {
          String path = Fixtures.string(page, "path");
          int status =
              routes
                  .handle(
                      Request.builder("GET", path).header("authorization", "Bearer tok").build())
                  .status();
          assertEquals(Fixtures.integer(page, "status"), status, path);
        }
        assertEquals(read.get("reported"), reported(errors, names), "reported by the reads");
      }
    }
  }

  /** The jobs reported to the error handler since the last call, each where matched by its end. */
  private static List<Object> reported(List<String> errors, List<String> names) {
    TreeSet<String> out = new TreeSet<>();
    for (String where : errors) {
      String job = where;
      for (String name : names) {
        if (where.endsWith(" " + name)) {
          job = name;
        }
      }
      out.add(job);
    }
    errors.clear();
    return new ArrayList<>(out);
  }

  private static <T> T assertNotNullAndGet(@Nullable T value, String what) {
    assertNotNull(value, what);
    return value;
  }
}
