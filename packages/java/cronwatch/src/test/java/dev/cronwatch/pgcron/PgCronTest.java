package dev.cronwatch.pgcron;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertNotNull;
import static org.junit.jupiter.api.Assertions.assertNull;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;

import dev.cronwatch.Alert;
import dev.cronwatch.Channel;
import dev.cronwatch.CheckResult;
import dev.cronwatch.Condition;
import dev.cronwatch.Cronwatch;
import dev.cronwatch.CronwatchException;
import dev.cronwatch.JobHealth;
import dev.cronwatch.JobOptions;
import dev.cronwatch.JobSummary;
import dev.cronwatch.Run;
import dev.cronwatch.RunStatus;
import dev.cronwatch.Source;
import dev.cronwatch.internal.js.Js;
import dev.cronwatch.store.MemoryStore;
import dev.cronwatch.store.Store;
import java.util.ArrayList;
import java.util.List;
import java.util.concurrent.CopyOnWriteArrayList;
import java.util.concurrent.atomic.AtomicLong;
import java.util.function.LongSupplier;
import java.util.function.Supplier;
import org.jspecify.annotations.Nullable;
import org.junit.jupiter.api.Test;

/**
 * The SDK's {@code pgcron.test.ts}, ported over an in-memory {@code cron} schema ({@link
 * FakeCron}), with the Go and Elixir ports' own: the source's queries and the options' refusals.
 */
class PgCronTest {
  static final long T0 = Js.dateUtc(2026, 0, 5, 9, 30, 0, 0);
  static final long MIN = 60_000;
  static final long HOUR = 3_600_000;
  static final long DAY = 24 * HOUR;

  /** A client over a store, on a clock the test moves, with what it sent and reported. */
  static final class Kit implements AutoCloseable {
    final Cronwatch cw;
    final List<Alert> alerts;
    final List<String> errors;

    Kit(Cronwatch cw, List<Alert> alerts, List<String> errors) {
      this.cw = cw;
      this.alerts = alerts;
      this.errors = errors;
    }

    List<String> types() {
      List<String> out = new ArrayList<>();
      for (Alert a : alerts) {
        out.add(a.type().value());
      }
      return out;
    }

    /** The errors reported, but for the settings and row level security notes. */
    List<String> others() {
      List<String> out = new ArrayList<>();
      for (String e : errors) {
        if (!e.contains("cron.") && !e.contains("row level")) {
          out.add(e);
        }
      }
      return out;
    }

    @Override
    public void close() {
      cw.close();
    }
  }

  static Kit kit(Store store, @Nullable AtomicLong clock, Source source) {
    return kit(store, clock, source, new CopyOnWriteArrayList<>());
  }

  static Kit kit(Store store, @Nullable AtomicLong clock, Source source, List<Alert> alerts) {
    return kit(store, clock == null ? null : clock::get, source, alerts);
  }

  static Kit kit(Store store, @Nullable LongSupplier clock, Source source, List<Alert> alerts) {
    List<String> errors = new CopyOnWriteArrayList<>();
    Cronwatch.Builder b =
        Cronwatch.builder()
            .store(store)
            .alert(Channel.of("capture", (alert, ctx) -> alerts.add(alert)))
            .noCronSecret()
            .onError((where, e) -> errors.add(String.valueOf(e.getMessage())))
            .noShutdownHook()
            .source(source);
    if (clock != null) {
      b.clock(clock);
    }
    return new Kit(b.build(), alerts, errors);
  }

  static List<String> names(CheckResult r) {
    List<String> out = new ArrayList<>();
    for (JobSummary j : r.jobs()) {
      out.add(j.name());
    }
    return out;
  }

  static JobSummary find(List<JobSummary> jobs, String name) {
    return jobs.stream().filter(j -> j.name().equals(name)).findFirst().orElseThrow();
  }

  static List<String> ids(List<Run> runs) {
    List<String> out = new ArrayList<>();
    for (Run r : runs) {
      out.add(r.id());
    }
    return out;
  }

  static List<String> typeAndJob(List<Alert> alerts) {
    List<String> out = new ArrayList<>();
    for (Alert a : alerts) {
      out.add(a.type().value() + " " + a.job());
    }
    out.sort(null);
    return out;
  }

  @Test
  void pgCronSchedulesBecomeCronwatchSchedules() {
    assertEquals("every 30s", PgCron.schedule("30 seconds"));
    assertEquals("every 1s", PgCron.schedule("1 second"));
    assertEquals("0 0 L * *", PgCron.schedule("0 0 $ * *"));
    assertEquals("*/5 * * * *", PgCron.schedule(" */5  * * * * "));
    assertNull(PgCron.schedule("@reboot"));
    assertEquals(
        "nightly-vacuum", PgCron.jobName(new PgCronJob(7, "nightly vacuum", "", "", "", true)));
    assertEquals("pg_cron:7", PgCron.jobName(new PgCronJob(7, null, "", "", "", true)));
    assertEquals("pg_cron:7", PgCron.jobName(new PgCronJob(7, "  ", "", "", "", true)));
  }

  @Test
  void pgCronIgnoresFieldsPastTheFifthAndSoDoesTheReader() {
    assertEquals("0 5 * * *", PgCron.schedule("0 5 * * * *"));
    assertEquals("* * * * *", PgCron.schedule("* * * * * *"));
    assertEquals("0 0 L * *", PgCron.schedule("0 0 $ * * extra"));
    assertEquals("@hourly", PgCron.schedule("@hourly"));
  }

  @Test
  void jobsAreDeclaredHistoryIsCopiedQuietlyAndImportsAreIdempotent() throws Exception {
    AtomicLong c = new AtomicLong(T0);
    FakeCron cron = new FakeCron();
    cron.job(1, "nightly vacuum", "0 3 * * *");
    cron.job(2, null, "10 seconds");
    cron.job(3, "paused", "0 * * * *", false);
    cron.job(4, "other", "0 * * * *");
    long three = Js.dateUtc(2026, 0, 5, 3, 0, 0, 0);
    for (int i = 24; i >= 1; i--) {
      cron.add(1, "succeeded", three - i * DAY, three - i * DAY + 5000, "VACUUM");
    }
    cron.add(1, "failed", three, three + 2000L, "ERROR:  deadlock detected\n");
    MemoryStore store = new MemoryStore();
    List<Alert> alerts = new CopyOnWriteArrayList<>();
    Supplier<Source> source =
        () ->
            PgCron.source(
                cron, PgCronOptions.builder().pick(j -> j.jobId() != 4).prefix("db:").build());
    Kit k = kit(store, c, source.get(), alerts);

    CheckResult first = k.cw.check();
    assertEquals(List.of("db:nightly-vacuum", "db:paused", "db:pg_cron:2"), names(first));
    JobSummary vacuum = find(first.jobs(), "db:nightly-vacuum");
    assertEquals("0 3 * * *", vacuum.definition().schedule());
    assertEquals("UTC", vacuum.definition().timezone());
    assertEquals(List.of("pg_cron"), vacuum.definition().tags());
    assertEquals("every 10s", find(first.jobs(), "db:pg_cron:2").definition().schedule());
    assertNull(
        find(first.jobs(), "db:paused").definition().schedule(),
        "a paused job is not expected to run");
    List<Run> runs = k.cw.runs("db:nightly-vacuum", 100);
    assertEquals(20, runs.size(), "twenty newest runs copied on first sight");
    assertEquals("pgcron:db:25", runs.get(0).id());
    assertEquals(RunStatus.FAILED, runs.get(0).status());
    assertEquals("ERROR:  deadlock detected", runs.get(0).error());
    assertEquals(2000L, runs.get(0).durationMs());
    assertEquals("pg_cron", runs.get(0).trigger());
    assertEquals("VACUUM", runs.get(1).output());
    assertEquals(
        List.of("failed"),
        k.types(),
        "only the newest finished run is judged; history does not alert");

    k.cw.check();
    k.close();
    k = kit(store, c, source.get(), alerts);
    k.cw.check();
    assertEquals(
        20,
        k.cw.runs("db:nightly-vacuum", 100).size(),
        "a re-import, even after a restart, adds nothing");
    assertEquals(List.of("failed"), k.types());

    // A run not yet started holds the cursor; the run after it is copied now and it is copied
    // once it starts.
    FakeCron.Detail starting = cron.add(2, "starting", null, null);
    cron.add(2, "succeeded", T0 - 5000, T0 - 4000, "1 row");
    c.addAndGet(1000);
    k.cw.check();
    assertEquals(List.of("pgcron:db:27"), ids(k.cw.runs("db:pg_cron:2", 20)));
    starting.status = "running";
    starting.start = T0 - 3000;
    k.cw.check();
    assertEquals(RunStatus.RUNNING, getRun(k, "pgcron:db:26").status());
    starting.status = "failed";
    starting.end = T0 - 1000;
    starting.message = "ERROR:  boom";
    c.addAndGet(1000);
    k.cw.check();
    Run finished = getRun(k, "pgcron:db:26");
    assertEquals(RunStatus.FAILED, finished.status());
    assertEquals(2000L, finished.durationMs());
    assertEquals(
        List.of("failed", "failed"),
        k.types(),
        "a run that was running and then failed is judged when it finishes");

    // The nightly job stops running: missed, from its schedule, with no run details at all.
    c.set(Js.dateUtc(2026, 0, 6, 3, 11, 0, 0));
    cron.add(2, "succeeded", c.get() - 2000, c.get() - 1000, "1 row");
    CheckResult later = k.cw.check();
    assertEquals(
        List.of("missed db:nightly-vacuum", "recovered db:pg_cron:2"), typeAndJob(later.alerts()));
    assertTrue(k.cw.check().alerts().isEmpty(), "each condition alerts once");

    // Unscheduled: its name keeps its history but loses its schedule, so it is never missed
    // again, and the missed alert it had open closes with a recovery that says so.
    cron.jobs.remove(0);
    c.set(Js.dateUtc(2026, 0, 8, 3, 11, 0, 0));
    CheckResult gone = k.cw.check();
    JobSummary vacuumNow = find(gone.jobs(), "db:nightly-vacuum");
    assertNull(vacuumNow.definition().schedule());
    assertTrue(
        String.valueOf(vacuumNow.definition().description()).contains("no longer watched"),
        vacuumNow.definition().description());
    assertEquals(
        List.of(Condition.FAILED),
        vacuumNow.open(),
        "its failure stays open until a successful run");
    List<Alert> closed =
        gone.alerts().stream().filter(a -> a.job().equals("db:nightly-vacuum")).toList();
    assertEquals(1, closed.size());
    assertEquals("recovered", closed.get(0).type().value());
    assertEquals("db:nightly-vacuum is no longer scheduled", closed.get(0).title());
    assertEquals(
        "{\"after\":[\"missed\"],\"reason\":\"unscheduled\",\"since\":"
            + Js.dateUtc(2026, 0, 6, 3, 11, 0, 0)
            + "}",
        closed.get(0).details().toValue().toJson());
    assertFalse(
        k.cw.check().alerts().stream().anyMatch(a -> a.job().equals("db:nightly-vacuum")), "once");
    assertEquals(20, k.cw.runs("db:nightly-vacuum", 100).size(), "its history is kept");
    k.close();
  }

  static Run getRun(Kit k, String id) {
    Run r = k.cw.getRun(id);
    assertNotNull(r, id);
    return r;
  }

  @Test
  void aJobsOptionsApplyAndAScheduleItCannotReadIsReported() {
    FakeCron cron = new FakeCron();
    cron.job(1, "odd", "not a schedule");
    try (Kit k =
        kit(
            new MemoryStore(),
            null,
            PgCron.source(
                cron,
                PgCronOptions.builder()
                    .options(JobOptions.builder().grace("1m").expectMatch("rows?"))
                    .build()))) {
      long now = System.currentTimeMillis();
      cron.add(1, "succeeded", now - 1000, now, "nothing");
      CheckResult result = k.cw.check();
      assertNull(result.jobs().get(0).definition().schedule());
      assertEquals("1m", result.jobs().get(0).definition().get("grace"));
      assertTrue(
          String.join("\n", k.errors).contains("watching it without a schedule"),
          k.errors.toString());
      Run run = k.cw.runs("odd", 20).get(0);
      assertEquals(RunStatus.FAILED, run.status(), "expect applies to imported output");
      assertTrue(String.valueOf(run.error()).contains("did not match"), run.error());
    }
  }

  @Test
  void aRunCutOffByARestartIsRecordedAndOneHeldRunNeverStopsTheOthers() {
    AtomicLong c = new AtomicLong(T0);
    FakeCron cron = new FakeCron();
    cron.job(1, "fast", "30 seconds");
    cron.job(2, "other", "0 * * * *");
    try (Kit k = kit(new MemoryStore(), c, PgCron.source(cron, PgCronOptions.defaults()))) {
      cron.add(1, "succeeded", T0 - 60_000, T0 - 59_000, "1 row");
      k.cw.check();
      // pg_cron restarts while a run is queued: it marks it failed, "server restarted", with no
      // times at all.
      FakeCron.Detail restarted = cron.add(1, "failed", null, null, "server restarted");
      // The fast job then runs far more than a page's worth, and the other job fails after all
      // of them.
      for (int i = 0; i < 520; i++) {
        cron.add(1, "succeeded", T0 - 50_000 + i, T0 - 50_000 + i + 1, "1 row");
      }
      FakeCron.Detail failure = cron.add(2, "failed", T0 - 1000, T0 - 500, "ERROR:  disk full");
      FakeCron.Detail queued = cron.add(1, "starting", null, null);
      c.addAndGet(1000);
      k.cw.check();
      k.cw.check();
      Run cut = getRun(k, "pgcron:" + restarted.runId);
      assertEquals(RunStatus.FAILED, cut.status());
      assertEquals("server restarted", cut.error());
      assertEquals(T0 - 60_000, cut.startedAt(), "placed at the job's newest run before it");
      assertEquals(
          RunStatus.FAILED,
          getRun(k, "pgcron:" + failure.runId).status(),
          "the other job's failure is not starved");
      assertTrue(
          k.alerts.stream()
              .anyMatch(a -> a.type().value().equals("failed") && a.job().equals("other")));
      assertNull(k.cw.getRun("pgcron:" + queued.runId), "a queued run is held");

      // Held only so long: then it is copied as running from when it was first seen, and a late
      // start updates nothing but its end.
      c.addAndGet(11 * MIN);
      k.cw.check();
      Run waiting = getRun(k, "pgcron:" + queued.runId);
      assertEquals(RunStatus.RUNNING, waiting.status());
      assertEquals(T0 + 1000, waiting.startedAt());
      queued.status = "succeeded";
      queued.start = c.get() - 2000;
      queued.end = c.get() - 1000;
      c.addAndGet(1000);
      k.cw.check();
      assertEquals(RunStatus.OK, getRun(k, "pgcron:" + queued.runId).status());
      assertEquals(List.of(), k.others());
    }
  }

  @Test
  void firstSightNeverJudgesHistoryEvenWithAHeldOrCutOffRunAmongTheNewest() {
    AtomicLong c = new AtomicLong(T0);
    FakeCron cron = new FakeCron();
    cron.job(1, "nightly", "0 3 * * *");
    for (int i = 0; i < 30; i++) {
      cron.add(1, "failed", T0 - (40 - i) * HOUR, T0 - (40 - i) * HOUR + 1000, "ERROR:  old");
    }
    cron.add(1, "failed", null, null, "server restarted");
    for (int i = 0; i < 19; i++) {
      long at = T0 - (long) ((10 - i / 2.0) * HOUR);
      cron.add(1, "succeeded", at, at + 1000, "ok");
    }
    try (Kit k = kit(new MemoryStore(), c, PgCron.source(cron, PgCronOptions.defaults()))) {
      k.cw.check();
      k.cw.check();
      assertEquals(20, k.cw.runs("nightly", 500).size(), "only the newest twenty are copied");
      assertEquals(List.of(), k.types(), "no alert from history");
    }
  }

  @Test
  void aRenamedJobLeavesNoScheduledGhostInThisProcessOrTheNext() {
    AtomicLong c = new AtomicLong(T0);
    FakeCron cron = new FakeCron();
    FakeCron.Job rollup = cron.job(1, "rollup", "*/5 * * * *");
    cron.add(1, "succeeded", T0 - 60_000, T0 - 59_000, "1 row");
    MemoryStore store = new MemoryStore();
    List<Alert> alerts = new CopyOnWriteArrayList<>();
    Kit k = kit(store, c, PgCron.source(cron, PgCronOptions.defaults()), alerts);
    k.cw.check();
    rollup.jobName = "rollup-v2";
    FakeCron.Detail running = cron.add(1, "running", T0 - 1000, null);
    k.cw.check();
    List<JobSummary> summary = k.cw.jobs();
    JobSummary old = find(summary, "rollup");
    assertNull(old.definition().schedule(), "the old name has no schedule");
    assertTrue(String.valueOf(old.definition().description()).contains("renamed to rollup-v2"));
    assertEquals("*/5 * * * *", find(summary, "rollup-v2").definition().schedule());
    assertEquals("rollup-v2", getRun(k, "pgcron:" + running.runId).job());
    running.status = "succeeded";
    running.end = T0;
    c.addAndGet(HOUR);
    cron.add(1, "succeeded", c.get() - 2000, c.get() - 1000, "1 row");
    k.cw.check();
    assertEquals(RunStatus.OK, getRun(k, "pgcron:" + running.runId).status());
    assertFalse(alerts.stream().anyMatch(a -> a.job().equals("rollup")), "never missed");
    List<String> errors = new ArrayList<>(k.others());
    k.close();

    // Renamed again while no process watched: the next process retires the name the store still
    // schedules.
    rollup.jobName = "rollup-v3";
    k = kit(store, c, PgCron.source(cron, PgCronOptions.defaults()), alerts);
    c.addAndGet(MIN);
    k.cw.check();
    summary = k.cw.jobs();
    assertNull(find(summary, "rollup-v2").definition().schedule());
    assertTrue(
        String.valueOf(find(summary, "rollup-v2").definition().description())
            .contains("renamed to rollup-v3"));
    assertEquals("*/5 * * * *", find(summary, "rollup-v3").definition().schedule());
    assertEquals(
        0,
        k.cw.runs("rollup-v3", 20).size(),
        "runs already copied under an old name are not copied again");
    c.addAndGet(HOUR);
    k.cw.check();
    assertEquals(
        List.of(),
        typeAndJob(alerts.stream().filter(a -> !a.job().equals("rollup-v3")).toList()),
        "only the job's current name can be missed");
    errors.addAll(k.others());
    assertEquals(List.of(), errors);
    k.close();
  }

  @Test
  void aJobPausedOrRenamedWhileMissedClosesMissedWithARecovery() {
    AtomicLong c = new AtomicLong(T0);
    FakeCron cron = new FakeCron();
    FakeCron.Job hourly = cron.job(1, "hourly", "0 * * * *");
    FakeCron.Job rollup = cron.job(2, "rollup", "0 * * * *");
    cron.add(1, "succeeded", T0 - 3 * HOUR, T0 - 3 * HOUR + 1000);
    cron.add(2, "succeeded", T0 - 3 * HOUR, T0 - 3 * HOUR + 1000);
    try (Kit k = kit(new MemoryStore(), c, PgCron.source(cron, PgCronOptions.defaults()))) {
      k.cw.check();
      assertEquals(List.of("missed hourly", "missed rollup"), typeAndJob(k.alerts));
      hourly.active = false;
      rollup.jobName = "rollup-v2";
      c.addAndGet(MIN);
      CheckResult r = k.cw.check();
      List<String> got = new ArrayList<>();
      for (Alert a : r.alerts()) {
        got.add(a.type().value() + " " + a.job() + " " + a.title());
      }
      got.sort(null);
      assertEquals(
          List.of(
              "recovered hourly hourly is no longer scheduled",
              "recovered rollup rollup is no longer scheduled"),
          got);
      c.addAndGet(MIN);
      assertEquals(List.of(), k.cw.check().alerts());
    }
  }

  @Test
  void aRunMarkedTimeoutByACheckIsStillReadAndItsLateFinishRecorded() {
    AtomicLong c = new AtomicLong(T0);
    FakeCron cron = new FakeCron();
    cron.job(1, "vacuum", "0 3 * * *");
    try (Kit k =
        kit(
            new MemoryStore(),
            c,
            PgCron.source(
                cron,
                PgCronOptions.builder().options(JobOptions.builder().timeout("30m")).build()))) {
      FakeCron.Detail running = cron.add(1, "running", T0, null);
      k.cw.check();
      assertEquals(RunStatus.RUNNING, getRun(k, "pgcron:" + running.runId).status());
      c.addAndGet(45 * MIN);
      k.cw.check();
      assertEquals(RunStatus.TIMEOUT, getRun(k, "pgcron:" + running.runId).status());
      assertEquals(List.of("stuck"), k.types());
      c.addAndGet(10 * MIN);
      running.status = "succeeded";
      running.end = c.get() - 60_000;
      running.message = "VACUUM";
      k.cw.check();
      Run done = getRun(k, "pgcron:" + running.runId);
      assertEquals(RunStatus.OK, done.status());
      assertEquals("VACUUM", done.output());
      assertEquals(List.of("stuck", "recovered"), k.types());
      JobSummary vacuum = k.cw.jobSummary("vacuum");
      assertNotNull(vacuum);
      assertEquals(JobHealth.HEALTHY, vacuum.health());
    }
  }

  @Test
  void settingsARoleMayNotReadAreAssumedAndReportedOnce() {
    FakeCron cron = new FakeCron();
    cron.settings.put("cron.timezone", null);
    cron.settings.put("cron.log_run", null);
    cron.job(1, "nightly", "0 3 * * *");
    try (Kit k = kit(new MemoryStore(), null, PgCron.source(cron, PgCronOptions.defaults()))) {
      CheckResult first = k.cw.check();
      k.cw.check();
      assertEquals("UTC", first.jobs().get(0).definition().timezone());
      assertEquals(1, k.errors.stream().filter(e -> e.contains("cron.timezone")).count());
      assertFalse(
          k.errors.stream().anyMatch(e -> e.contains("log_run")),
          "log_run unreadable is taken as on");
    }
  }

  @Test
  void theSourcesQueriesAndJobsPickedByNameOrId() {
    AtomicLong c = new AtomicLong(T0);
    FakeCron cron = new FakeCron();
    cron.settings.put("cron.log_run", "off");
    cron.job(1, "nightly", "0 3 * * *");
    cron.add(1, "succeeded", T0 - 1000, T0);
    try (Kit k =
        kit(
            new MemoryStore(),
            c,
            PgCron.source(
                cron, PgCronOptions.builder().timezone("America/New_York").jobIds(1).build()))) {
      CheckResult r = k.cw.check();
      assertNull(
          r.jobs().get(0).definition().schedule(), "no schedule when pg_cron records no runs");
      assertEquals(0, k.cw.runs("nightly", 20).size(), "no runs read");
      assertTrue(String.join("\n", k.errors).contains("cron.log_run is off"), k.errors.toString());
    }
    for (String q : cron.queries) {
      assertFalse(
          q.contains("current_setting") || q.contains("COMMIT") || q.contains("ROLLBACK"),
          "a query that could end the caller's transaction: " + q);
    }

    FakeCron two = new FakeCron();
    two.job(1, "a", "0 3 * * *");
    two.job(2, "b", "0 3 * * *");
    two.job(3, "c", "0 3 * * *");
    try (Kit k =
        kit(
            new MemoryStore(),
            c,
            PgCron.source(two, PgCronOptions.builder().jobs("b").jobIds(3).build()))) {
      assertEquals(List.of("b", "c"), names(k.cw.check()));
    }
  }

  @Test
  void theOptionsAreCheckedWithoutQuotingTheirValues() {
    CronwatchException both =
        assertThrows(
            CronwatchException.class,
            () -> PgCronOptions.builder().jobs("x").pick(j -> true).build());
    assertEquals("PgCronOptions: give pick, or jobs and jobIds, not both", both.getMessage());
    CronwatchException schedule =
        assertThrows(
            CronwatchException.class,
            () ->
                PgCronOptions.builder()
                    .options(JobOptions.builder().schedule("secret-looking 0 3 * * *"))
                    .build());
    assertFalse(schedule.getMessage().contains("secret-looking"), schedule.getMessage());

    // Options a function gives that set a schedule are reported, and that job is not declared.
    FakeCron cron = new FakeCron();
    cron.job(1, "a", "0 3 * * *");
    cron.job(2, "b", "0 3 * * *");
    try (Kit k =
        kit(
            new MemoryStore(),
            new AtomicLong(T0),
            PgCron.source(
                cron,
                PgCronOptions.builder()
                    .options(
                        j ->
                            j.jobId() == 1
                                ? JobOptions.builder().timezone("Europe/Paris")
                                : JobOptions.builder())
                    .build()))) {
      assertEquals(List.of("b"), names(k.cw.check()));
      assertTrue(
          String.join("\n", k.errors).contains("may not set a schedule or timezone"),
          k.errors.toString());
    }

    PgCronOptions o = PgCronOptions.builder().prefix("db:").timezone("UTC").build();
    assertEquals("PgCronOptions[prefix, timezone]", o.toString());
    assertEquals(
        "PgCron.source(PgCronOptions[prefix, timezone])",
        PgCron.source(new FakeCron(), o).toString());
    assertEquals("pg_cron", PgCron.source(new FakeCron(), o).name());
  }
}
