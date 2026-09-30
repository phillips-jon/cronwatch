package dev.cronwatch.storetest;

import static dev.cronwatch.storetest.Checks.eq;
import static dev.cronwatch.storetest.Checks.get;
import static dev.cronwatch.storetest.Checks.ids;
import static dev.cronwatch.storetest.Checks.json;
import static dev.cronwatch.storetest.Checks.must;
import static dev.cronwatch.storetest.Checks.sameJson;

import dev.cronwatch.Definition;
import dev.cronwatch.JobState;
import dev.cronwatch.Metrics;
import dev.cronwatch.Run;
import dev.cronwatch.RunStatus;
import dev.cronwatch.StoredJob;
import dev.cronwatch.internal.js.Js;
import dev.cronwatch.json.JsObject;
import dev.cronwatch.json.Json;
import dev.cronwatch.store.Store;
import java.util.ArrayList;
import java.util.List;
import java.util.Map;
import java.util.function.Supplier;
import org.jspecify.annotations.Nullable;

/**
 * Replays the store cases of the repository's {@code conformance/store.json}, which the SDK's
 * memory store answered, against a store: prune scripts, {@code compareAndSetState} steps, {@code
 * updateRunIf} steps and text written without NUL ({@link #run}), and states another process wrote
 * with a version that is not a whole number ({@link #foreignVersions}). The caller reads the
 * fixture and passes its text, since a published jar cannot reach the repository:
 *
 * <pre>{@code
 * String fixture = Files.readString(Path.of("conformance/store.json"));
 * int cases = StoreReplay.run(fixture, () -> new MyStore(emptyDatabase()));
 * }</pre>
 *
 * <p>Each method throws an {@link AssertionError} at the first case the store answers differently.
 */
public final class StoreReplay {
  private StoreReplay() {}

  /** Writes a state's JSON text into the store's state table as it is, for job {@code v}. */
  @FunctionalInterface
  public interface RawStateWriter {
    /**
     * Writes {@code stateJson} as job {@code v}'s stored state, byte for byte (in SQL: {@code
     * INSERT INTO <prefix>state (job, state) VALUES ('v', ?)}).
     *
     * @throws Exception when the write fails
     */
    void write(String stateJson) throws Exception;
  }

  private static JsObject root(String fixture) {
    return Json.parseObject(fixture);
  }

  private static List<JsObject> objects(@Nullable Object v) {
    List<JsObject> out = new ArrayList<>();
    if (v instanceof List<?> list) {
      for (Object x : list) {
        if (x instanceof JsObject o) {
          out.add(o);
        }
      }
    }
    return out;
  }

  private static JsObject field(JsObject o, String key) {
    if (!(o.get(key) instanceof JsObject x)) {
      throw new AssertionError("the fixture has no object " + key);
    }
    return x;
  }

  private static long number(JsObject o, String key) {
    return o.get(key) instanceof Number n ? Js.toLong(n.doubleValue()) : -1;
  }

  /**
   * Replays the prune, {@code compareAndSetState} and {@code updateRunIf} cases against stores from
   * {@code fresh}, each of which must be empty; each is closed when its cases are done.
   *
   * @return how many cases were replayed
   * @throws AssertionError at the first case the store answers differently from the SDK's
   */
  public static int run(String fixture, Supplier<? extends Store> fresh) {
    JsObject fix = root(fixture);
    int cases = 0;
    for (JsObject script : objects(fix.get("prune"))) {
      String name = String.valueOf(script.get("name"));
      Store store = fresh.get();
      must("init", store::init);
      for (JsObject event : objects(script.get("events"))) {
        if (event.get("insert") instanceof List<?> inserts) {
          for (Object r : inserts) {
            Run run = Run.fromValue(r);
            must(name + ": insertRun", () -> store.insertRun(run));
          }
          continue;
        }
        long before = number(event, "prune");
        eq(
            name + ": pruned",
            get(name + ": prune", () -> store.prune(before)),
            number(event, "pruned"));
        for (Map.Entry<String, @Nullable Object> e : field(event, "remaining").entries()) {
          List<String> want = new ArrayList<>();
          if (e.getValue() instanceof List<?> list) {
            for (Object id : list) {
              want.add(String.valueOf(id));
            }
          }
          String job = e.getKey();
          eq(
              name + ": " + job + " kept",
              ids(get("listRuns", () -> store.listRuns(job, 100))),
              want);
        }
        cases++;
      }
      must("close", store::close);
    }

    Store store = fresh.get();
    must("init", store::init);
    int i = 0;
    for (JsObject step : objects(fix.get("compareAndSetState"))) {
      String what = "compareAndSetState step " + i;
      if (step.has("cas")) {
        JobState st = JobState.fromValue(step.get("cas"));
        long expected = number(step, "expected");
        eq(
            what + ": wrote",
            get(what, () -> store.compareAndSetState(st, expected)),
            step.get("written"));
      } else if (step.has("set")) {
        JobState st = JobState.fromValue(step.get("set"));
        must(what, () -> store.setState(st));
      } else {
        String job = String.valueOf(step.get("forget"));
        must(what, () -> store.deleteJob(job));
      }
      for (Map.Entry<String, @Nullable Object> e : field(step, "states").entries()) {
        String job = e.getKey();
        sameJson(
            what + ", state of " + job,
            json(get(what, () -> store.getState(job))),
            Json.stringify(e.getValue()));
      }
      cases++;
      i++;
    }
    must("close", store::close);

    Store runs = fresh.get();
    must("init", runs::init);
    must(
        "insertRun u1",
        () ->
            runs.insertRun(
                new Run(
                    "u1",
                    "a",
                    RunStatus.RUNNING,
                    1000,
                    null,
                    null,
                    null,
                    null,
                    Metrics.empty(),
                    "run")));
    i = 0;
    for (JsObject step : objects(fix.get("updateRunIf"))) {
      String what = "updateRunIf step " + i;
      if (step.has("set")) {
        Run r = Run.fromValue(step.get("set"));
        must(what, () -> runs.updateRun(r));
      } else if (step.has("insert")) {
        Run r = Run.fromValue(step.get("insert"));
        String outcome;
        try {
          runs.insertRun(r);
          outcome = "inserted";
        } catch (Exception e) {
          outcome = "refused";
        }
        eq(what, outcome, step.get("outcome"));
      } else {
        List<RunStatus> from = new ArrayList<>();
        if (step.get("from") instanceof List<?> list) {
          for (Object s : list) {
            from.add(RunStatus.of(String.valueOf(s)));
          }
        }
        Run r = Run.fromValue(step.get("run"));
        eq(what + ": wrote", get(what, () -> runs.updateRunIf(r, from)), step.get("outcome"));
      }
      sameJson(what, json(get(what, () -> runs.getRun("u1"))), Json.stringify(step.get("stored")));
      cases++;
      i++;
    }
    must("close", runs::close);
    cases += nul(fix, fresh);
    if (cases == 0) {
      throw new AssertionError("no cases replayed");
    }
    return cases;
  }

  /**
   * The {@code nul} steps: text is written without U+0000, which Postgres refuses (a run's trigger,
   * output, error and metric names, and every key and string of a definition and a state).
   */
  private static int nul(JsObject fix, Supplier<? extends Store> fresh) {
    Store store = fresh.get();
    must("init", store::init);
    int cases = 0;
    for (JsObject step : objects(fix.get("nul"))) {
      String what = "nul step " + cases;
      String want = Json.stringify(step.get("stored"));
      if (step.has("upsertJob")) {
        Definition d = Definition.of(field(step, "upsertJob"));
        long now = number(step, "now");
        must(what, () -> store.upsertJob(d, now));
        StoredJob j = get(what, () -> store.getJob("nul"));
        String got =
            j == null
                ? "null"
                : new JsObject()
                    .set("name", j.name())
                    .set("definition", Json.parse(j.definition().toJson()))
                    .set("createdAt", j.createdAt())
                    .set("updatedAt", j.updatedAt())
                    .toJson();
        sameJson(what, got, want);
      } else if (step.has("setState") || step.has("compareAndSetState")) {
        if (step.has("setState")) {
          JobState st = JobState.fromValue(step.get("setState"));
          must(what, () -> store.setState(st));
        } else {
          JobState st = JobState.fromValue(step.get("compareAndSetState"));
          long expected = number(step, "expected");
          eq(
              what + ": wrote",
              get(what, () -> store.compareAndSetState(st, expected)),
              step.get("written"));
        }
        sameJson(what, json(get(what, () -> store.getState("nul"))), want);
      } else {
        if (step.has("insertRun")) {
          Run r = Run.fromValue(step.get("insertRun"));
          must(what, () -> store.insertRun(r));
        } else if (step.has("updateRun")) {
          Run r = Run.fromValue(step.get("updateRun"));
          must(what, () -> store.updateRun(r));
        } else {
          Run r = Run.fromValue(step.get("updateRunIf"));
          List<RunStatus> from = new ArrayList<>();
          if (step.get("from") instanceof List<?> list) {
            for (Object s : list) {
              from.add(RunStatus.of(String.valueOf(s)));
            }
          }
          eq(what + ": wrote", get(what, () -> store.updateRunIf(r, from)), step.get("written"));
        }
        sameJson(what, json(get(what, () -> store.getRun("n1"))), want);
      }
      cases++;
    }
    must("close", store::close);
    if (cases == 0) {
      throw new AssertionError("no nul cases");
    }
    return cases;
  }

  /**
   * Replays the {@code foreignVersion} cases against {@code store}, which holds its states as JSON
   * text: for each, job {@code v} is deleted, {@code writeRaw} puts the case's state text in the
   * state table as it is (a state another process wrote, its version {@code 1.5}, {@code "x"} or
   * {@code 2.0}), and each compare-and-set step must be refused or written as the SDK's was: the
   * version counts as {@link JobState#countedVersion} reads it. The store is not closed.
   *
   * @return how many cases were replayed
   * @throws AssertionError at the first step the store answers differently from the SDK's
   */
  public static int foreignVersions(String fixture, Store store, RawStateWriter writeRaw) {
    JsObject fix = root(fixture);
    must("init", store::init);
    int cases = 0;
    for (JsObject c : objects(fix.get("foreignVersion"))) {
      String stored = String.valueOf(c.get("stored"));
      must("deleteJob v", () -> store.deleteJob("v"));
      must("writing " + stored, () -> writeRaw.write(stored));
      for (JsObject step : objects(c.get("steps"))) {
        JobState st = JobState.fromValue(step.get("cas"));
        long expected = number(step, "expected");
        String what = stored + " expecting " + expected;
        eq(
            what + ": wrote",
            get(what, () -> store.compareAndSetState(st, expected)),
            step.get("written"));
        if (step.has("state")) {
          sameJson(
              what, json(get(what, () -> store.getState("v"))), Json.stringify(step.get("state")));
        }
      }
      cases++;
    }
    if (cases == 0) {
      throw new AssertionError("no foreignVersion cases");
    }
    return cases;
  }
}
