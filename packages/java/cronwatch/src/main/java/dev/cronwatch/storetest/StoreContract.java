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
import dev.cronwatch.store.Store;
import java.util.ArrayList;
import java.util.List;
import java.util.Map;
import org.jspecify.annotations.Nullable;

/**
 * The test every CronWatch store passes: the SDK's {@code store-conformance.ts}, step for step. The
 * memory store and {@code SqlStore} pass it; run it against a store of the app's own from any test
 * framework:
 *
 * <pre>{@code
 * @Test
 * void myStorePassesTheContract() {
 *   StoreContract.run(new MyStore(emptyDatabase()));
 * }
 * }</pre>
 *
 * <p>It throws an {@link AssertionError}, as a test's assertion does, at the first thing the store
 * gets wrong, and depends on no test framework. See {@link StoreReplay} for the SDK's recorded
 * cases.
 */
public final class StoreContract {
  private StoreContract() {}

  /**
   * A run as the contract writes them: finished ten milliseconds after it started unless it is
   * running, with one metric, {@code n}, of 1.
   */
  public static Run newRun(String id, String job, RunStatus status, long startedAt) {
    boolean finished = !status.equals(RunStatus.RUNNING);
    return new Run(
        id,
        job,
        status,
        startedAt,
        finished ? startedAt + 10 : null,
        finished ? 10L : null,
        null,
        null,
        Metrics.of(Map.of("n", 1)),
        "run");
  }

  private static Definition definition(String text) {
    return Definition.fromJson(text);
  }

  private static JobState state(String text) {
    return JobState.fromJson(text);
  }

  private static Run with(
      Run r, @Nullable String error, @Nullable String output, @Nullable Metrics metrics) {
    return r.finished(
        r.status(),
        r.finishedAt(),
        r.durationMs(),
        error,
        output,
        metrics == null ? r.metrics() : metrics);
  }

  /**
   * Runs the contract against {@code store}, which must be empty, and closes it at the end.
   *
   * @throws AssertionError at the first thing the store gets wrong
   */
  public static void run(Store store) {
    must("init", store::init);
    eq("no job yet", get("getJob", () -> store.getJob("a")), null);
    must(
        "upsertJob",
        () -> store.upsertJob(definition("{\"name\":\"a\",\"schedule\":\"every 5m\"}"), 100));
    must(
        "upsertJob again",
        () ->
            store.upsertJob(
                definition("{\"name\":\"a\",\"schedule\":\"every 10m\",\"tags\":[\"x\"]}"), 200));
    for (String name : List.of("b", "B", "_c")) {
      must(
          "upsertJob " + name,
          () -> store.upsertJob(definition("{\"name\":\"" + name + "\"}"), 300));
    }
    StoredJob a = get("getJob", () -> store.getJob("a"));
    if (a == null) {
      throw new AssertionError("job a was not stored");
    }
    eq("createdAt survives upsert", a.createdAt(), 100L);
    eq("updatedAt", a.updatedAt(), 200L);
    sameJson(
        "definition",
        a.definition().toJson(),
        "{\"name\":\"a\",\"schedule\":\"every 10m\",\"tags\":[\"x\"]}");
    List<String> names = new ArrayList<>();
    for (StoredJob j : get("listJobs", store::listJobs)) {
      names.add(j.name());
    }
    eq("byte order, not locale", names, List.of("B", "_c", "a", "b"));

    for (Run r :
        List.of(
            newRun("r1", "a", RunStatus.OK, 1000),
            newRun("r2", "a", RunStatus.FAILED, 2000),
            newRun("r3", "a", RunStatus.RUNNING, 3000),
            newRun("r4", "b", RunStatus.OK, 1500),
            newRun("rb", "B", RunStatus.RUNNING, 2000),
            newRun("rc", "_c", RunStatus.RUNNING, 2000))) {
      must("insertRun " + r.id(), () -> store.insertRun(r));
    }
    eq(
        "newest first",
        ids(get("listRuns", () -> store.listRuns("a", 10))),
        List.of("r3", "r2", "r1"));
    eq("limit", ids(get("listRuns", () -> store.listRuns("a", 2))), List.of("r3", "r2"));
    Run last = get("lastRun", () -> store.lastRun("a"));
    eq("last run", last == null ? null : last.id(), "r3");
    eq("no last run", get("lastRun", () -> store.lastRun("none")), null);
    eq(
        "oldest first, then insertion order",
        ids(get("runningRuns", store::runningRuns)),
        List.of("rb", "rc", "r3"));
    Run r1 = get("getRun", () -> store.getRun("r1"));
    if (r1 == null) {
      throw new AssertionError("run r1 was not stored");
    }
    sameJson("metrics", r1.metrics().toJson(), "{\"n\":1}");
    eq("durationMs", r1.durationMs(), 10L);

    Run updated =
        with(
            newRun("r3", "a", RunStatus.OK, 3000),
            null,
            "line1\nline2",
            Metrics.of(Map.of("cost", 0.25)));
    must("updateRun", () -> store.updateRun(updated));
    Run r3 = get("getRun", () -> store.getRun("r3"));
    if (r3 == null) {
      throw new AssertionError("run r3 was lost");
    }
    eq("status", r3.status(), RunStatus.OK);
    eq("output", r3.output(), "line1\nline2");
    sameJson("updated metrics", r3.metrics().toJson(), "{\"cost\":0.25}");
    eq("running after update", ids(get("runningRuns", store::runningRuns)), List.of("rb", "rc"));

    // updateRunIf writes only over a row whose status is one of those given, and says whether it
    // did.
    boolean refused = false;
    try {
      store.insertRun(newRun("r3", "a", RunStatus.RUNNING, 3000));
    } catch (Exception e) {
      refused = true;
    }
    eq("an id already recorded is refused", refused, true);
    must("upsertJob q", () -> store.upsertJob(definition("{\"name\":\"q\"}"), 300));
    must("insertRun rx", () -> store.insertRun(newRun("rx", "q", RunStatus.RUNNING, 2500)));
    List<RunStatus> running = List.of(RunStatus.RUNNING);
    List<RunStatus> both = List.of(RunStatus.RUNNING, RunStatus.TIMEOUT);
    Run first = with(newRun("rx", "q", RunStatus.FAILED, 2500), "first", null, null);
    eq("first finish", get("updateRunIf", () -> store.updateRunIf(first, running)), true);
    Run second = with(newRun("rx", "q", RunStatus.OK, 2500), null, "second", null);
    eq(
        "a second finish over the first is refused",
        get("updateRunIf", () -> store.updateRunIf(second, running)),
        false);
    Run kept = get("getRun", () -> store.getRun("rx"));
    eq("first error kept", kept == null ? null : kept.error(), "first");
    Run late = with(newRun("rx", "q", RunStatus.OK, 2500), null, "late", null);
    eq("not over failed", get("updateRunIf", () -> store.updateRunIf(late, both)), false);
    must(
        "updateRun",
        () ->
            store.updateRun(with(newRun("rx", "q", RunStatus.TIMEOUT, 2500), "stuck", null, null)));
    Run lateAgain =
        with(newRun("rx", "q", RunStatus.OK, 2500), null, "late", Metrics.of(Map.of("m", 2)));
    eq(
        "any of the statuses given",
        get("updateRunIf", () -> store.updateRunIf(lateAgain, both)),
        true);
    sameJson(
        "late finish",
        json(get("getRun", () -> store.getRun("rx"))),
        "{\"id\":\"rx\",\"job\":\"q\",\"status\":\"ok\",\"startedAt\":2500,\"finishedAt\":2510,"
            + "\"durationMs\":10,\"error\":null,\"output\":\"late\",\"metrics\":{\"m\":2},"
            + "\"trigger\":\"run\"}");
    Run missing = newRun("missing", "q", RunStatus.OK, 1);
    eq(
        "a run that is not there is not written",
        get("updateRunIf", () -> store.updateRunIf(missing, running)),
        false);
    eq("still missing", get("getRun", () -> store.getRun("missing")), null);
    Run failed = newRun("rx", "q", RunStatus.FAILED, 2500);
    eq(
        "no statuses, no write",
        get("updateRunIf", () -> store.updateRunIf(failed, List.of())),
        false);
    Run stillOk = get("getRun", () -> store.getRun("rx"));
    eq("still ok", stillOk == null ? null : stillOk.status(), RunStatus.OK);

    // deleteRunIf, for a store that has it, takes back only a run still of the job and in the
    // status given.
    must("insertRun rd", () -> store.insertRun(newRun("rd", "q", RunStatus.RUNNING, 2600)));
    boolean supported = true;
    boolean otherJob = false;
    try {
      otherJob = store.deleteRunIf("rd", "a", RunStatus.RUNNING);
    } catch (UnsupportedOperationException e) {
      supported = false;
    } catch (Exception e) {
      throw new AssertionError("deleteRunIf: the store threw " + e, e);
    }
    if (supported) {
      eq("not another job's", otherJob, false);
      eq(
          "not in another status",
          get("deleteRunIf", () -> store.deleteRunIf("rd", "q", RunStatus.OK)),
          false);
      eq(
          "not a finished run",
          get("deleteRunIf", () -> store.deleteRunIf("rx", "q", RunStatus.RUNNING)),
          false);
      eq(
          "taken back",
          get("deleteRunIf", () -> store.deleteRunIf("rd", "q", RunStatus.RUNNING)),
          true);
      eq("gone", get("getRun", () -> store.getRun("rd")), null);
      eq(
          "only once",
          get("deleteRunIf", () -> store.deleteRunIf("rd", "q", RunStatus.RUNNING)),
          false);
      eq("the finished run kept", get("getRun", () -> store.getRun("rx")) != null, true);
    }
    must("deleteJob q", () -> store.deleteJob("q"));

    // Forgetting a job while one of its runs is in flight: the run finishing later changes
    // nothing.
    must("deleteJob B", () -> store.deleteJob("B"));
    must(
        "updateRun",
        () -> store.updateRun(with(newRun("rb", "B", RunStatus.OK, 2000), null, "late", null)));
    eq("forgotten run stays gone", get("getRun", () -> store.getRun("rb")), null);
    eq(
        "no runs of a forgotten job",
        ids(get("listRuns", () -> store.listRuns("B", 10))),
        List.of());
    eq("running after forgetting", ids(get("runningRuns", store::runningRuns)), List.of("rc"));
    must("deleteJob _c", () -> store.deleteJob("_c"));

    eq("no state yet", get("getState", () -> store.getState("a")), null);
    must(
        "setState",
        () ->
            store.setState(
                state(
                    "{\"job\":\"a\",\"open\":{\"failed\":5},\"consecutiveFailures\":2,"
                        + "\"silencedUntil\":null,\"lastAlertAt\":6}")));
    String plain =
        "{\"job\":\"a\",\"open\":{},\"consecutiveFailures\":0,\"silencedUntil\":99,\"lastAlertAt\":6}";
    must("setState", () -> store.setState(state(plain)));
    sameJson("state", json(get("getState", () -> store.getState("a"))), plain);
    String full =
        "{\"job\":\"a\",\"open\":{\"stuck\":7},\"consecutiveFailures\":1,\"silencedUntil\":null,"
            + "\"lastAlertAt\":6,\"pendingRecovery\":[\"missed\"],\"undelivered\":[{\"type\":\"failed\","
            + "\"run\":null,\"details\":{\"consecutiveFailures\":1,\"threshold\":1},\"job\":\"a\","
            + "\"definition\":{\"name\":\"a\"},\"title\":\"a failed\",\"message\":\"boom\",\"at\":7,"
            + "\"triage\":null}],\"sending\":[{\"until\":8,\"alert\":{\"type\":\"failed\","
            + "\"run\":null,\"details\":{\"consecutiveFailures\":1,\"threshold\":1},\"job\":\"a\","
            + "\"definition\":{\"name\":\"a\"},\"title\":\"a failed\",\"message\":\"boom\",\"at\":7}}]}";
    must("setState", () -> store.setState(state(full)));
    sameJson(
        "pendingRecovery, undelivered and sending round-trip",
        json(get("getState", () -> store.getState("a"))),
        full);
    must("setState", () -> store.setState(state(plain)));

    // compareAndSetState writes only over the version it was told to expect.
    casIs(store, "no row matches only version 0", v(2, 0), 1, false);
    eq("nothing written", get("getState", () -> store.getState("v")), null);
    casIs(store, "no row counts as version 0", v(1, 0), 0, true);
    casIs(store, "a write from a stale read is refused", v(1, 9), 0, false);
    casIs(store, "the version read", v(2, 1), 1, true);
    casIs(store, "an older version", v(3, 0), 1, false);
    sameJson(
        "state after writes", json(get("getState", () -> store.getState("v"))), v(2, 1).toJson());
    must(
        "setState",
        () ->
            store.setState(
                state(
                    "{\"job\":\"w\",\"open\":{},\"consecutiveFailures\":3,\"silencedUntil\":null,"
                        + "\"lastAlertAt\":null}")));
    JobState w1 =
        state(
            "{\"job\":\"w\",\"open\":{},\"consecutiveFailures\":0,\"silencedUntil\":null,"
                + "\"lastAlertAt\":null,\"version\":1}");
    casIs(store, "state written before versions counts as 0", w1, 1, false);
    casIs(store, "from 0", w1, 0, true);
    JobState w = get("getState", () -> store.getState("w"));
    eq("version", w == null ? null : w.version(), 1L);
    must("deleteJob v", () -> store.deleteJob("v"));
    casIs(store, "a forgotten job's state is not written back", v(3, 0), 2, false);
    eq("gone", get("getState", () -> store.getState("v")), null);
    must("deleteJob w", () -> store.deleteJob("w"));

    must("insertRun r5", () -> store.insertRun(newRun("r5", "a", RunStatus.RUNNING, 500)));
    eq(
        "r1 and r2 pruned; running r5 kept, and b's r4 kept as b's newest run",
        get("prune", () -> store.prune(2500)),
        2L);
    eq("a after prune", ids(get("listRuns", () -> store.listRuns("a", 10))), List.of("r3", "r5"));
    eq("b after prune", ids(get("listRuns", () -> store.listRuns("b", 10))), List.of("r4"));
    eq(
        "however old, each job keeps its newest run, and running runs stay",
        get("prune", () -> store.prune(1_000_000)),
        0L);

    must("deleteJob a", () -> store.deleteJob("a"));
    eq("job deleted", get("getJob", () -> store.getJob("a")), null);
    eq("runs deleted", ids(get("listRuns", () -> store.listRuns("a", 10))), List.of());
    eq("state deleted", get("getState", () -> store.getState("a")), null);
    StoredJob b = get("getJob", () -> store.getJob("b"));
    eq("b kept", b == null ? null : b.name(), "b");
    must("close", store::close);
  }

  private static JobState v(long version, long failures) {
    return state(
        "{\"job\":\"v\",\"open\":{},\"consecutiveFailures\":"
            + failures
            + ",\"silencedUntil\":null,\"lastAlertAt\":null,\"version\":"
            + version
            + "}");
  }

  private static void casIs(Store store, String what, JobState st, long expected, boolean want) {
    eq(what, get(what, () -> store.compareAndSetState(st, expected)), want);
  }
}
