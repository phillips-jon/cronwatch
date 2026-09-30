package dev.cronwatch.bridge;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertNotNull;
import static org.junit.jupiter.api.Assertions.assertNull;
import static org.junit.jupiter.api.Assertions.assertSame;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;

import dev.cronwatch.Cronwatch;
import dev.cronwatch.CronwatchException;
import dev.cronwatch.Definition;
import dev.cronwatch.Job;
import dev.cronwatch.JobOptions;
import dev.cronwatch.Run;
import dev.cronwatch.StoredJob;
import dev.cronwatch.internal.cron.Zones;
import dev.cronwatch.internal.duration.Schedules;
import dev.cronwatch.internal.js.Js;
import dev.cronwatch.store.MemoryStore;
import dev.cronwatch.store.Store;
import java.time.Duration;
import java.time.Instant;
import java.time.ZoneId;
import java.util.ArrayList;
import java.util.List;
import java.util.Map;
import java.util.concurrent.CopyOnWriteArrayList;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;
import org.junit.jupiter.api.Test;

/** The Go and Rust ports' bridge tests, with their audits' regressions. */
class BridgeTest {
  @Test
  void theAppTagIsThePhpPorts() {
    // What the PHP port's Bridge\Unscheduled::appTag() gives for each name.
    String x39 = "x".repeat(39);
    Map<String, String> cases =
        Map.of(
            "Billing",
            "laravel-scheduler:billing",
            "  My App! v2 ",
            "laravel-scheduler:my-app-v2",
            "acme_web.prod-1",
            "laravel-scheduler:acme_web.prod-1",
            "!!!",
            "laravel-scheduler:6dd07555",
            "x".repeat(50),
            "laravel-scheduler:" + x39 + "-62f01267",
            "\u00dcn\u00efcode \u00c4pp",
            "laravel-scheduler:n-code-pp",
            "\u212a",
            "laravel-scheduler:f7781178");
    for (Map.Entry<String, String> c : cases.entrySet()) {
      assertEquals(c.getValue(), Bridge.appTag("laravel-scheduler", c.getKey()), c.getKey());
    }
    // The PHP port's own cases.
    assertEquals("fw:laravel", Bridge.appTag("fw", "Laravel"));
    assertEquals("fw:billing-api", Bridge.appTag("fw", "  Billing API! "));
    assertEquals("fw:app-1d4ce23f0a88", Bridge.appTag("fw", "app-1d4ce23f0a88"));
  }

  @Test
  void theAppNameComesFromTheFallbackOrTheMainClass() {
    if (System.getenv("CRONWATCH_APP_ID") != null) {
      return; // the variable wins, which this JVM cannot unset
    }
    assertEquals("billing", Bridge.appName(" billing "));
    assertFalse(Bridge.appName(null).isEmpty());
    assertFalse(Bridge.appName(null).contains("."), Bridge.appName(null));
  }

  @Test
  void everyTextIsExactToTheMillisecond() {
    assertEquals("every 1h30m", Bridge.everyText(Duration.ofMinutes(90)));
    assertEquals("every 1d12h1s500ms", Bridge.everyText(Duration.ofMillis(36 * 3_600_000L + 1500)));
    assertEquals("every 0ms", Bridge.everyText(Duration.ZERO));
    assertEquals("every 1ms", Bridge.everyText(Duration.ofNanos(600_000)));
  }

  @Test
  void validNamesAreTheClients() {
    assertTrue(Bridge.validName("NightlyReports.build"));
    assertFalse(Bridge.validName("Outer$Inner.run"));
    assertFalse(Bridge.validName("x".repeat(121)));
  }

  /** A scheduler that runs at hour:00 UTC every {@code step} days from the epoch. */
  private static FireTimes daily(long hour, long step) {
    return (start, end) -> {
      long day = Math.floorDiv(start, 86_400_000L);
      while (at(day, hour) > start || day % step != 0) {
        day--;
      }
      List<Long> out = new ArrayList<>(List.of(at(day, hour)));
      while (true) {
        day += step;
        out.add(at(day, hour));
        if ((end == null && out.size() > Bridge.SAMPLE_RUNS)
            || (end != null && at(day, hour) > end)) {
          return out;
        }
      }
    };
  }

  private static long at(long day, long hour) {
    return day * 86_400_000L + hour * 3_600_000L;
  }

  @Test
  void checkFiresComparesTheSchedulersOwnRuns() throws Exception {
    long now = Js.dateUtc(2026, 8, 1, 0, 0, 0, 0);
    Bridge.checkFires(daily(2, 1), "0 2 * * *", "UTC", "x", "a scheduler", true, now);
    ScheduleException e =
        assertThrows(
            ScheduleException.class,
            () ->
                Bridge.checkFires(
                    daily(2, 2), "0 2 * * *", "UTC", "cronwatch: x", "a scheduler", true, now));
    assertTrue(
        e.getMessage().contains("cronwatch: x is \"0 2 * * *\" in UTC, but after a run at"),
        e.getMessage());
    assertTrue(e.getMessage().contains("a scheduler runs it next at"), e.getMessage());
    assertThrows(
        ScheduleException.class,
        () -> Bridge.checkFires(daily(3, 1), "0 2 * * *", "UTC", "x", "a scheduler", true, now));
    FireTimes never =
        (start, end) -> {
          throw ScheduleException.neverFires("no fire time");
        };
    e =
        assertThrows(
            ScheduleException.class,
            () -> Bridge.checkFires(never, "0 2 * * *", "UTC", "x", "a scheduler", true, now));
    assertTrue(e.getMessage().endsWith("which never fires: no fire time"), e.getMessage());
    e =
        assertThrows(
            ScheduleException.class,
            () ->
                Bridge.checkFires(daily(2, 1), "not a cron", "UTC", "x", "a scheduler", true, now));
    assertTrue(e.getMessage().contains("which CronWatch cannot read"), e.getMessage());
  }

  @Test
  void checkFiresNamesATimeTheClockChangeSkips() throws Exception {
    // A scheduler that skips 02:30 in New York the night clocks go forward, where CronWatch
    // (croner) moves it past the jump.
    ZoneId ny = ZoneId.of("America/New_York");
    Schedules.ParsedSchedule cron = Schedules.parse("30 2 * * *", "America/New_York");
    FireTimes runs =
        (start, end) -> {
          List<Long> out = new ArrayList<>();
          long at = start - 3 * 86_400_000L;
          while (true) {
            Long fire = Schedules.nextFire(cron, at, null);
            if (fire == null) {
              return out;
            }
            at = fire;
            if (Instant.ofEpochMilli(fire).atZone(ny).getHour() != 2) {
              continue; // the moved fire: this scheduler skips the day
            }
            if (fire <= start) {
              out.clear();
            }
            out.add(fire);
            if ((end == null && out.size() > Bridge.SAMPLE_RUNS) || (end != null && fire > end)) {
              return out;
            }
          }
        };
    long now = Js.dateUtc(2026, 8, 1, 0, 0, 0, 0);
    ScheduleException e =
        assertThrows(
            ScheduleException.class,
            () ->
                Bridge.checkFires(
                    runs, "30 2 * * *", "America/New_York", "job", "a scheduler", true, now));
    assertTrue(
        e.getMessage()
            .contains(
                "due at a time that does not exist in America/New_York on 2026-03-08, when clocks"
                    + " go forward from 02:00 to 03:00"),
        e.getMessage());
    assertNotNull(Zones.find("america/new_york"), "zones match without regard to case");
  }

  /** A client on {@code store} with no channels, keeping its errors as {@code where: message}. */
  private static Cronwatch client(Store store, List<String> errors) {
    return Cronwatch.builder()
        .store(store)
        .alerts(List.of())
        .noShutdownHook()
        .onError((where, error) -> errors.add(where + ": " + error.getMessage()))
        .build();
  }

  private static Cronwatch client(Store store) {
    return client(store, new CopyOnWriteArrayList<>());
  }

  private static String stored(Store store, String name) throws Exception {
    StoredJob job = store.getJob(name);
    assertNotNull(job, name + " is not stored");
    return job.definition().toJson();
  }

  private static Entry entry(String name, String label, String schedule) {
    return Entry.of(name, label, schedule, "");
  }

  @Test
  void aWatchDeclaresEntriesAndUnschedulesTheGone() throws Exception {
    MemoryStore store = new MemoryStore();
    List<String> errors = new CopyOnWriteArrayList<>();
    try (Cronwatch cw = client(store, errors)) {
      Watch w = new Watch(cw, "gocron", "billing", "gocron");
      Entry nightly =
          new Entry(
              "nightly",
              "entry 1",
              "0 2 * * *",
              "UTC",
              null,
              JobOptions.builder().grace("5m"),
              JobOptions.builder().budget("cost", 2).tags("reports"));
      Entry odd =
          new Entry(
              "odd",
              "entry 4",
              "",
              "",
              "cronwatch: entry 4 cannot be read",
              JobOptions.builder(),
              JobOptions.builder());
      w.declare(
          List.of(
              nightly,
              entry("twice", "entry 2", "0 3 * * *"),
              entry("twice", "entry 3", "0 4 * * *"),
              odd));
      cw.check();
      assertEquals(
          "{\"grace\":\"5m\",\"schedule\":\"0 2 * * *\",\"timezone\":\"UTC\",\"budget\":{\"cost\":2},"
              + "\"tags\":[\"reports\",\"gocron\",\"gocron:billing\"],\"name\":\"nightly\"}",
          stored(store, "nightly"));
      assertEquals(
          "{\"tags\":[\"gocron\",\"gocron:billing\"],\"name\":\"twice\"}", stored(store, "twice"));
      assertEquals(
          "{\"tags\":[\"gocron\",\"gocron:billing\"],\"name\":\"odd\"}", stored(store, "odd"));
      assertEquals(
          "declaring entry 2: cronwatch: \"twice\" is run by 2 gocron entries on different"
              + " schedules (0 3 * * *; 0 4 * * *), so it is watched without a schedule; give each"
              + " a name of its own\n"
              + "declaring entry 4: cronwatch: entry 4 cannot be read",
          String.join("\n", errors));

      // Declaring again changes nothing and reports nothing again; an entry gone keeps its runs
      // and loses its schedule.
      Job first = w.job("nightly");
      w.declare(
          List.of(
              nightly,
              entry("twice", "entry 2", "0 3 * * *"),
              entry("twice", "entry 3", "0 4 * * *")));
      assertSame(first, w.job("nightly"), "the same job");
      assertEquals(2, errors.size(), "reported once");
      w.declare(List.of());
      assertTrue(w.settle(Duration.ofSeconds(10)));
      cw.check();
      assertEquals(
          "{\"description\":\"A scheduled task (no longer scheduled)\",\"tags\":[\"reports\","
              + "\"gocron\",\"gocron:billing\"],\"grace\":\"5m\",\"budget\":{\"cost\":2},"
              + "\"name\":\"nightly\"}",
          stored(store, "nightly"));
    }
  }

  @Test
  void unscheduleTakesOnlyThisAppsJobs() throws Exception {
    MemoryStore store = new MemoryStore();
    try (Cronwatch earlier = client(store)) {
      for (String[] job :
          new String[][] {
            {"invoices", "gocron:billing"},
            {"dunning", "gocron:billing"},
            {"reindex", "gocron:search"}
          }) {
        earlier.job(
            job[0],
            JobOptions.builder()
                .schedule("0 1 * * *")
                .tags("gocron", job[1])
                .timeout("2h")
                .description("Bills"));
      }
      earlier.check();
    }
    try (Cronwatch cw = client(store)) {
      Watch w = new Watch(cw, "gocron", "billing", "gocron");
      assertTrue(w.unschedule().isEmpty(), "a watch that saw no entry takes nothing");
      w.declare(List.of(entry("invoices", "x", "0 1 * * *")));
      assertEquals(List.of("dunning"), w.unschedule());
      // Written without a check (the Go audit: a process that never checks left the schedule in
      // the store).
      assertTrue(stored(store, "dunning").contains("no longer scheduled"));
      cw.check();
      assertEquals(
          "{\"description\":\"Bills (no longer scheduled)\",\"tags\":[\"gocron\",\"gocron:billing\"],"
              + "\"timeout\":\"2h\",\"name\":\"dunning\"}",
          stored(store, "dunning"));
      assertTrue(stored(store, "reindex").contains("\"schedule\":\"0 1 * * *\""), "search's");
      assertTrue(stored(store, "invoices").contains("\"schedule\":\"0 1 * * *\""), "kept");
    }
  }

  @Test
  void aFallbackKeepsTheStoredDefinition() throws Exception {
    MemoryStore store = new MemoryStore();
    String before;
    try (Cronwatch scheduler = client(store)) {
      scheduler.job(
          "report",
          JobOptions.builder()
              .grace("5m")
              .schedule("0 2 * * *")
              .timezone("UTC")
              .timeout(7_200_000)
              .maxDuration("30m")
              .budget("cost", 2)
              .budget("rows", 10)
              .failuresBeforeAlert(2)
              .description("Nightly")
              .tags("river", "river:billing")
              .expect("Report written"));
      scheduler.check();
      before = stored(store, "report");
    }
    try (Cronwatch worker = client(store)) {
      Watch w = new Watch(worker, "river", "billing", "River");
      Job job = w.fallback("report", JobOptions.builder());
      assertNotNull(job);
      assertEquals(before, job.definition().toJson());
      assertSame(job, w.fallback("report", JobOptions.builder()));
      job.run(ctx -> {});
      List<Run> runs = worker.runs("report", 1);
      assertEquals("Output did not contain \"Report written\"", runs.get(0).error());
      assertEquals(before, stored(store, "report"), "the stored definition is unchanged");
    }
    // A job of another app's is not taken for this one's.
    try (Cronwatch fresh = client(store)) {
      Watch other = new Watch(fresh, "river", "search", "River");
      Job made = other.fallback("report", JobOptions.builder().grace("1m"));
      assertNotNull(made);
      assertEquals(
          "{\"grace\":\"1m\",\"tags\":[\"river\",\"river:search\"],\"name\":\"report\"}",
          made.definition().toJson());
    }
  }

  // The Go audit: a process that only schedules neither runs nor checks, and kept its
  // declarations in memory, so the store never held its jobs.
  @Test
  void declaringWritesTheJobsToTheStore() throws Exception {
    MemoryStore store = new MemoryStore();
    List<String> errors = new CopyOnWriteArrayList<>();
    try (Cronwatch cw = client(store, errors)) {
      Watch w = new Watch(cw, "asynq", "billing", "Asynq");
      w.declare(List.of(entry("invoices", "x", "0 1 * * *")));
      assertTrue(w.settle(Duration.ofSeconds(10)));
      assertEquals(
          "{\"schedule\":\"0 1 * * *\",\"tags\":[\"asynq\",\"asynq:billing\"],\"name\":\"invoices\"}",
          stored(store, "invoices"));
      assertTrue(errors.isEmpty(), errors.toString());
    }
  }

  // The Go audit: a job another process of the app took the schedule out of (an older release
  // still up during a deploy) stayed unscheduled until this process restarted.
  @Test
  void aJobAnotherProcessUnscheduledIsPutBack() throws Exception {
    MemoryStore store = new MemoryStore();
    try (Cronwatch newer = client(store);
        Cronwatch older = client(store)) {
      Watch wn = new Watch(newer, "gocron", "billing", "gocron");
      wn.declare(List.of(entry("old", "a", "0 1 * * *"), entry("added", "b", "0 2 * * *")));
      assertTrue(wn.settle(Duration.ofSeconds(10)));
      newer.check();

      Watch wo = new Watch(older, "gocron", "billing", "gocron");
      wo.declare(List.of(entry("old", "a", "0 1 * * *")));
      wo.unschedule();
      older.check();
      assertFalse(stored(store, "added").contains("\"schedule\""), "the older release took it out");

      wn.unschedule();
      assertEquals(
          "{\"schedule\":\"0 2 * * *\",\"tags\":[\"gocron\",\"gocron:billing\"],\"name\":\"added\"}",
          stored(store, "added"));
    }
  }

  @Test
  void aFallbackDoesNotDeclareOverAStoreItCouldNotRead() throws Exception {
    OddStore store = new OddStore();
    String before;
    try (Cronwatch scheduler = client(store)) {
      scheduler.job(
          "report", JobOptions.builder().schedule("0 2 * * *").tags("river", "river:billing"));
      scheduler.check();
      before = stored(store, "report");
    }
    List<String> errors = new CopyOnWriteArrayList<>();
    try (Cronwatch worker = client(store, errors)) {
      Watch w = new Watch(worker, "river", "billing", "River");
      store.failing.set(true);
      assertNull(w.fallback("report", JobOptions.builder()), "declared without reading the store");
      assertEquals(1, errors.size(), errors.toString());
      store.failing.set(false);
      Job job = w.fallback("report", JobOptions.builder());
      assertNotNull(job, "a job once the store answers");
      job.run(ctx -> {});
      assertEquals(before, stored(store, "report"), "the schedule is kept");
    }
  }

  // The Rust audit: a store that panicked while a declaration was written left the writer marked
  // busy, so nothing was written again and settle waited for good.
  @Test
  void aDeclarationWhoseStoreThrowsDoesNotStopTheNext() throws Exception {
    OddStore store = new OddStore();
    List<String> errors = new CopyOnWriteArrayList<>();
    try (Cronwatch cw = client(store, errors)) {
      Watch w = new Watch(cw, "river", "billing", "River");
      store.throwsOnce.set(true);
      w.declare(List.of(entry("first", "x", "0 1 * * *")));
      assertTrue(w.settle(Duration.ofSeconds(10)), "settled");
      assertEquals(1, errors.size(), errors.toString());
      assertTrue(errors.get(0).startsWith("declaring first: "), errors.toString());
      assertTrue(errors.get(0).contains("the store fell over"), errors.toString());
      w.declare(List.of(entry("first", "x", "0 1 * * *"), entry("second", "y", "0 2 * * *")));
      assertTrue(w.settle(Duration.ofSeconds(10)), "settled");
      assertTrue(stored(store, "second").contains("0 2 * * *"));
    }
  }

  // The Rust audit: a declaration's write whose store hung held the writer for good.
  @Test
  void aDeclarationWhoseStoreHangsIsGivenUp() throws Exception {
    OddStore store = new OddStore();
    List<String> errors = new CopyOnWriteArrayList<>();
    CountDownLatch hang = new CountDownLatch(1);
    try (Cronwatch cw = client(store, errors)) {
      store.init();
      Watch w = new Watch(cw, "river", "billing", "River");
      w.saveTimeoutMs = 200;
      store.hang = hang;
      w.declare(List.of(entry("first", "x", "0 1 * * *")));
      assertTrue(w.settle(Duration.ofSeconds(10)), "the writer gave up and settled");
      assertEquals(
          List.of(
              "declaring first: writing the declaration of \"first\" took longer than 0 seconds;"
                  + " gave up"),
          errors);
      store.hang = null;
    } finally {
      hang.countDown();
    }
  }

  // The Go audit: an entry declared while unschedule read the store was taken for gone, and its
  // job lost its schedule for the life of the process.
  @Test
  void unscheduleKeepsAnEntryDeclaredMeanwhile() throws Exception {
    OddStore store = new OddStore();
    try (Cronwatch earlier = client(store)) {
      earlier.job(
          "added", JobOptions.builder().schedule("0 2 * * *").tags("gocron", "gocron:billing"));
      earlier.check();
    }
    try (Cronwatch cw = client(store)) {
      Watch w = new Watch(cw, "gocron", "billing", "gocron");
      List<Entry> entries = List.of(entry("first", "x", "0 1 * * *"));
      w.declare(entries);
      assertTrue(w.settle(Duration.ofSeconds(10)));
      store.meanwhile.set(
          () -> {
            List<Entry> more = new ArrayList<>(entries);
            more.add(entry("added", "y", "0 2 * * *"));
            w.declare(more);
          });
      assertTrue(w.unschedule().isEmpty());
      assertEquals("0 2 * * *", cw.definedJobs().get(1).schedule(), "kept");
      assertTrue(w.settle(Duration.ofSeconds(10)));
      assertTrue(stored(store, "added").contains("\"schedule\":\"0 2 * * *\""));
    }
  }

  @Test
  void unscheduleReportsAStoreItCouldNotRead() throws Exception {
    OddStore store = new OddStore();
    try (Cronwatch cw = client(store)) {
      Watch w = new Watch(cw, "gocron", "billing", "gocron");
      w.declare(List.of(entry("first", "x", "0 1 * * *")));
      assertTrue(w.settle(Duration.ofSeconds(10)));
      store.meanwhile.set(
          () -> {
            throw new IllegalStateException("the store is down");
          });
      CronwatchException e = assertThrows(CronwatchException.class, w::unschedule);
      assertTrue(e.getMessage().contains("the store is down"), e.getMessage());
    }
  }

  @Test
  void optionsOfRebuildsAnExpectPatternAndACustomFunction() {
    try (Cronwatch cw = client(new MemoryStore())) {
      Definition def =
          Bridge.definition(cw, "x", JobOptions.builder().expectMatch("done \\d+", "i"));
      JobOptions rebuilt = Bridge.optionsOf(def);
      assertEquals(def.toJson(), Bridge.definition(cw, "x", rebuilt).toJson());
      Job job = cw.job("x", Bridge.optionsOf(def));
      job.run(ctx -> ctx.log("Done 12"));
      job.run(ctx -> ctx.log("nothing"));
      List<Run> runs = cw.runs("x", 2);
      assertEquals("Output did not match /done \\d+/i", runs.get(0).error());
      assertNull(runs.get(1).error(), "run by the JavaScript engine, /i and all");

      Definition custom =
          Bridge.definition(cw, "y", JobOptions.builder().expectThat(output -> false));
      assertEquals(
          "{\"name\":\"y\",\"expect\":\"custom function\"}",
          Bridge.definition(cw, "y", Bridge.optionsOf(custom)).toJson());

      // A pattern the engine does not read is kept as stored, and passes every output.
      Definition unread = Definition.fromJson("{\"name\":\"z\",\"expect\":\"matches /(?<=a)b/\"}");
      assertEquals(unread.toJson(), Bridge.definition(cw, "z", Bridge.optionsOf(unread)).toJson());
    }
  }

  @Test
  void aStoredPatternThatBacktracksWithoutEndFailsQuickly() {
    // The fuzzer: stars back to back, or a dot star, over a long output they do not match
    // backtrack polynomially; the step budget stops them and the run fails with the ordinary
    // message.
    String[][] cases = {
      {"/\\n*\\n*\\n*\\n*\\n*x/", "\n".repeat(32_000), "\n\nx"},
      {"/.*x/", "a".repeat(32_000), "aax"},
      {"/(?:ab)*done/", "ab".repeat(16_000) + "done", "abdone"},
    };
    try (Cronwatch cw = client(new MemoryStore())) {
      for (String[] c : cases) {
        Definition def =
            Definition.fromJson(
                "{\"name\":\"x\",\"expect\":\"matches " + c[0].replace("\\", "\\\\") + "\"}");
        Job job = cw.job("x", Bridge.optionsOf(def));
        long started = System.nanoTime();
        job.run(ctx -> ctx.log(c[1]));
        long took = TimeUnit.NANOSECONDS.toSeconds(System.nanoTime() - started);
        Run run = cw.runs("x", 1).get(0);
        if (c[0].startsWith("/(?:ab)")) {
          // Deep but not slow: it matches, or gives up and fails; it never aborts the run.
          assertNotNull(run.status());
        } else {
          assertEquals("Output did not match " + c[0], run.error(), c[0]);
        }
        // Steps bound it, not time; this is a bound for a real regression, not a measurement.
        assertTrue(took < 60, c[0] + " took " + took + "s");
        job.run(ctx -> ctx.log(c[2]));
        assertNull(cw.runs("x", 1).get(0).error(), c[0] + " still matches");
      }
    }
  }

  @Test
  void syncWithinGivesUpOnAHungSync() {
    List<String> errors = new CopyOnWriteArrayList<>();
    CountDownLatch hang = new CountDownLatch(1);
    try (Cronwatch cw = client(new MemoryStore(), errors)) {
      assertFalse(
          Bridge.syncWithin(
              cw,
              Duration.ofMillis(100),
              "quartz",
              () -> {
                try {
                  hang.await();
                } catch (InterruptedException e) {
                  Thread.currentThread().interrupt();
                }
              }));
      assertEquals(List.of("quartz: the sync took longer than 0 seconds; gave up"), errors);
      assertTrue(Bridge.syncWithin(cw, Duration.ofSeconds(10), "quartz", () -> {}));
      assertFalse(
          Bridge.syncWithin(
              cw,
              Duration.ofSeconds(10),
              "quartz",
              () -> {
                throw new IllegalStateException("no");
              }));
      assertEquals("quartz: no", errors.get(1));
    } finally {
      hang.countDown();
    }
  }
}
