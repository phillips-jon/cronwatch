package dev.cronwatch;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertNotNull;

import dev.cronwatch.json.JsObject;
import dev.cronwatch.json.Json;
import dev.cronwatch.store.MemoryStore;
import dev.cronwatch.store.Servers;
import dev.cronwatch.store.SqlStore;
import dev.cronwatch.store.Store;
import java.util.ArrayList;
import java.util.List;
import java.util.Map;
import java.util.Objects;
import java.util.TreeMap;
import java.util.concurrent.atomic.AtomicLong;
import org.jspecify.annotations.Nullable;
import org.junit.jupiter.api.Test;
import org.sqlite.SQLiteDataSource;

/**
 * {@code conformance/client.json}, the first fixture driven through the client rather than a pure
 * function: the run ids {@code start}, {@code resume} and {@code recordRun} take, and stored data a
 * newer release wrote surviving a check, a silence, an unsilence, a summary and a run, over the
 * memory store, SQLite, and Postgres when {@code CRONWATCH_TEST_PG} is set.
 */
class ClientConformanceTest {
  private static final long T0 = 1767605400000L;

  private static final JsObject FIXTURE = Fixtures.load("client");

  @Test
  void runIdsAreTheSdks() {
    Fixtures.Failures failures = new Fixtures.Failures();
    int i = 0;
    for (JsObject c : Fixtures.objects(FIXTURE, "runIds")) {
      String method = Objects.requireNonNull(Fixtures.string(c, "method"));
      String id = Objects.requireNonNull(Fixtures.string(c, "id"));
      String what = "runIds[" + i++ + "] " + method + " " + Json.stringify(clip(id));
      String error = null;
      try (Cronwatch cw =
          Cronwatch.builder()
              .store(new MemoryStore())
              .clock(() -> T0)
              .noCronSecret()
              .noShutdownHook()
              .alerts(List.of())
              .build()) {
        Job job = cw.job("j");
        switch (method) {
          case "start" -> job.start(StartOptions.id(id)).finish();
          case "resume" -> job.resume(id);
          case "recordRun" ->
              cw.recordRun(
                  new Run(
                      id,
                      "j",
                      RunStatus.OK,
                      T0 - 1000,
                      T0,
                      1000L,
                      null,
                      null,
                      Metrics.empty(),
                      "run"));
          default -> throw new IllegalStateException("unknown method " + method);
        }
      } catch (CronwatchException e) {
        error = e.getMessage();
      }
      // Every port but Ruby, Python and Elixir spells the method as the SDK does.
      failures.same(what, error, c.get("error"));
    }
    failures.check("client");
  }

  @Test
  void unknownFieldsSurviveTheMemoryStore() throws Exception {
    replay(new MemoryStore());
  }

  @Test
  void unknownFieldsSurviveSqlite() throws Exception {
    SQLiteDataSource ds = new SQLiteDataSource();
    ds.setUrl("jdbc:sqlite::memory:");
    replay(SqlStore.sqlite(ds));
  }

  @Test
  void unknownFieldsSurvivePostgres() throws Exception {
    Servers.assume(Servers.Kind.PG);
    String prefix = Servers.prefix();
    try {
      replay(Servers.store(Servers.Kind.PG, prefix));
    } finally {
      Servers.drop(Servers.Kind.PG, prefix);
    }
  }

  private static void replay(Store store) throws Exception {
    JsObject fixture = Fixtures.object(FIXTURE, "unknownFields");
    JsObject seed = Fixtures.object(fixture, "seed");
    store.init();
    store.upsertJob(
        Definition.of(Fixtures.object(seed, "definition")), Fixtures.integer(seed, "createdAt"));
    for (JsObject run : Fixtures.objects(seed, "runs")) {
      store.insertRun(Run.fromValue(run));
    }
    store.setState(JobState.fromValue(seed.get("state")));
    AtomicLong now = new AtomicLong();
    List<Object> sent = new ArrayList<>();
    List<String> errors = new ArrayList<>();
    try (Cronwatch cw =
        Cronwatch.builder()
            .store(store)
            .clock(now::get)
            .noCronSecret()
            .noShutdownHook()
            .alert(
                Channel.of(
                    "capture",
                    (alert, context) -> {
                      synchronized (sent) {
                        sent.add(alert.toValue());
                      }
                    }))
            .onError((where, error) -> errors.add(where + ": " + error.getMessage()))
            .build()) {
      for (JsObject step : Fixtures.objects(fixture, "steps")) {
        String op = Objects.requireNonNull(Fixtures.string(step, "op"));
        now.set(Fixtures.integer(step, "at"));
        switch (op) {
          case "check" -> cw.check();
          case "silence" ->
              cw.silence("keep", Objects.requireNonNull(Fixtures.string(step, "for")));
          case "unsilence" -> cw.unsilence("keep");
          case "summary" -> {
            JobSummary summary = cw.jobSummary("keep");
            assertNotNull(summary, "summary");
            assertEquals(
                canonical(sortedOpen(Fixtures.object(step, "summary"))),
                canonical(sortedOpen(summary.toValue())),
                "summary");
          }
          case "declareAndRun" -> {
            JsObject declared = Fixtures.object(step, "declared");
            JobOptions options = JobOptions.builder();
            for (Map.Entry<String, @Nullable Object> e : declared.entries()) {
              switch (e.getKey()) {
                case "timeout" -> options.timeout((String) Objects.requireNonNull(e.getValue()));
                case "tags" -> {
                  List<String> tags = new ArrayList<>();
                  for (Object t : (List<?>) Objects.requireNonNull(e.getValue())) {
                    tags.add((String) t);
                  }
                  options.tags(tags);
                }
                default -> options.field(e.getKey(), e.getValue());
              }
            }
            now.set(Fixtures.integer(step, "startedAt"));
            RunHandle handle =
                cw.job("keep", options)
                    .start(StartOptions.id(Objects.requireNonNull(Fixtures.string(step, "id"))));
            now.set(Fixtures.integer(step, "finishedAt"));
            handle.finish(Fixtures.string(step, "output"));
          }
          default -> throw new IllegalStateException("unknown step " + op);
        }
        StoredJob job = Objects.requireNonNull(store.getJob("keep"));
        List<Object> runs = new ArrayList<>();
        for (Run r : store.listRuns("keep", 10)) {
          runs.add(r.toValue());
        }
        List<Object> alerts;
        synchronized (sent) {
          alerts = new ArrayList<>(sent);
          sent.clear();
        }
        JsObject got =
            new JsObject()
                .set(
                    "job",
                    new JsObject()
                        .set("name", job.name())
                        .set("definition", job.definition().toObject())
                        .set("createdAt", job.createdAt())
                        .set("updatedAt", job.updatedAt()))
                .set("state", Objects.requireNonNull(store.getState("keep")).toValue())
                .set("runs", runs)
                .set("alerts", alerts)
                .set("errors", new ArrayList<Object>(errors));
        errors.clear();
        assertEquals(canonical(step.get("expect")), canonical(got), op);
      }
    }
  }

  /** A summary with its open conditions sorted: Postgres's JSONB does not keep their order. */
  private static JsObject sortedOpen(JsObject summary) {
    JsObject copy = summary.copy();
    List<String> open = new ArrayList<>();
    for (Object c : Fixtures.list(summary, "open")) {
      open.add((String) c);
    }
    open.sort(null);
    return copy.set("open", new ArrayList<Object>(open));
  }

  /** The JSON with every object's keys sorted, as values compare whatever order a store keeps. */
  private static String canonical(@Nullable Object v) {
    return Json.stringify(sortKeys(v));
  }

  private static @Nullable Object sortKeys(@Nullable Object v) {
    if (v instanceof JsObject o) {
      TreeMap<String, @Nullable Object> sorted = new TreeMap<>();
      for (Map.Entry<String, @Nullable Object> e : o.entries()) {
        sorted.put(e.getKey(), sortKeys(e.getValue()));
      }
      JsObject out = new JsObject();
      sorted.forEach(out::set);
      return out;
    }
    if (v instanceof List<?> list) {
      List<@Nullable Object> out = new ArrayList<>();
      for (Object x : list) {
        out.add(sortKeys(x));
      }
      return out;
    }
    return v;
  }

  private static String clip(String s) {
    return s.length() > 12 ? s.substring(0, 12) + "..." : s;
  }
}
