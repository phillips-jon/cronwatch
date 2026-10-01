package dev.cronwatch.spring;

import static dev.cronwatch.spring.Apps.await;
import static dev.cronwatch.spring.Apps.finished;
import static dev.cronwatch.spring.Apps.stored;
import static dev.cronwatch.spring.Apps.storedOrEmpty;
import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertNotNull;
import static org.junit.jupiter.api.Assertions.assertNull;
import static org.junit.jupiter.api.Assertions.assertSame;
import static org.junit.jupiter.api.Assertions.assertTrue;

import dev.cronwatch.Cronwatch;
import dev.cronwatch.JobContext;
import dev.cronwatch.Run;
import dev.cronwatch.RunStatus;
import dev.cronwatch.store.MemoryStore;
import io.micrometer.observation.Observation;
import io.micrometer.observation.ObservationHandler;
import io.micrometer.observation.ObservationRegistry;
import java.io.IOException;
import java.time.Duration;
import java.util.List;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicInteger;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.support.DefaultListableBeanFactory;
import org.springframework.boot.SpringBootConfiguration;
import org.springframework.boot.autoconfigure.EnableAutoConfiguration;
import org.springframework.context.ConfigurableApplicationContext;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Import;
import org.springframework.scheduling.annotation.EnableScheduling;
import org.springframework.scheduling.annotation.Scheduled;
import org.springframework.scheduling.concurrent.ThreadPoolTaskScheduler;
import org.springframework.scheduling.support.ScheduledTaskObservationContext;
import reactor.core.publisher.Mono;

/**
 * A real Spring Boot application context with {@code @Scheduled} methods that fire each second, on
 * the JVM's clock: each invocation a run, the jobs declared from the annotations as Spring reads
 * them, a bean destroyed, the app's own observation registry, and a reactive method.
 */
class ScheduledTest {
  static final AtomicInteger ERRORS_HANDLED = new AtomicInteger();

  /** Logs through the current run each second. */
  public static class Ticks {
    @Scheduled(fixedRate = 1000)
    public void tick() {
      JobContext run = Cronwatch.current();
      if (run != null) {
        run.log("tick");
      }
    }
  }

  /** Throws each second, unchecked and checked. */
  public static class Broken {
    @Scheduled(fixedDelay = 1000)
    public void boom() {
      throw new IllegalStateException("boom");
    }

    @Scheduled(fixedDelay = 1000)
    public void disk() throws IOException {
      throw new IOException("disk full");
    }
  }

  /** Schedules that never fire during a test, for their declarations. */
  public static class Declared {
    @Scheduled(cron = "0 0 2 * * *", zone = "Europe/London")
    public void london() {}

    @Scheduled(cron = "${reports.cron}")
    public void placeholder() {}

    // Spring runs it on the 1st that is a Monday; croner on the 1st and on every Monday.
    @Scheduled(cron = "0 0 9 1 * MON", zone = "UTC")
    public void firstMonday() {}

    @Scheduled(fixedRateString = "PT2H", initialDelay = 3_600_000)
    public void rate() {}

    @Scheduled(fixedDelay = 90, timeUnit = TimeUnit.MINUTES, initialDelay = 3_600_000)
    public void delay() {}

    @Scheduled(cron = "-")
    public void disabled() {}

    // Spring reads ? as *; croner reads it as a day field named, every day.
    @Scheduled(cron = "0 0 2 1 * ?", zone = "UTC")
    public void monthly() {}

    @Scheduled(cron = "0 0 3 * * *", zone = "UTC")
    @CronwatchJob(
        name = "nightly-report",
        grace = "15m",
        expect = "Report written",
        tags = "reports")
    public void named() {}

    @Scheduled(cron = "0 0 4 * * *", zone = "UTC")
    @Scheduled(cron = "0 0 5 * * *", zone = "UTC")
    public void twice() {}
  }

  /** A bean the test destroys while the app runs. */
  public static class Gone {
    @Scheduled(cron = "0 0 6 * * *", zone = "UTC")
    public void work() {}
  }

  /** A reactive method, which Spring observes around its subscription. */
  public static class Reactive {
    @Scheduled(fixedRate = 1000)
    public Mono<Void> refresh() {
      return Mono.empty();
    }
  }

  /** The app with each kind of method. */
  @SpringBootConfiguration
  @EnableAutoConfiguration
  @EnableScheduling
  @Import({Ticks.class, Broken.class, Declared.class, Gone.class, Reactive.class})
  public static class App {
    /** A scheduler whose error handler counts, so the test sees Spring's still called. */
    @Bean
    public ThreadPoolTaskScheduler taskScheduler() {
      ThreadPoolTaskScheduler s = new ThreadPoolTaskScheduler();
      s.setPoolSize(4);
      s.setErrorHandler(t -> ERRORS_HANDLED.incrementAndGet());
      return s;
    }
  }

  private static ConfigurableApplicationContext app(MemoryStore store, Apps.Errors errors) {
    return Apps.run(
        App.class,
        store,
        errors,
        "spring.application.name=Billing",
        "reports.cron=0 30 1 * * *",
        "cronwatch.jobs[Declared.london].grace=5m");
  }

  @Test
  void eachInvocationIsARunWithItsOutput() throws Exception {
    MemoryStore store = new MemoryStore();
    Apps.Errors errors = new Apps.Errors();
    try (ConfigurableApplicationContext ctx = app(store, errors)) {
      Cronwatch cw = ctx.getBean(Cronwatch.class);
      await("a recorded run", () -> !finished(cw, "Ticks.tick").isEmpty());
      Run run = finished(cw, "Ticks.tick").get(0);
      assertEquals(RunStatus.OK, run.status());
      assertEquals("tick", run.output());
      assertEquals("spring-scheduled", run.trigger());
      assertTrue(run.id().startsWith("scheduled:billing:"), run.id());
      assertEquals(
          "{\"schedule\":\"every 1s\",\"tags\":[\"spring-scheduled\",\"spring-scheduled:billing\"],"
              + "\"name\":\"Ticks.tick\"}",
          stored(store, "Ticks.tick"));
    }
  }

  @Test
  void aThrowFailsTheRunAndSpringsErrorHandlerIsStillCalled() throws Exception {
    MemoryStore store = new MemoryStore();
    int before = ERRORS_HANDLED.get();
    try (ConfigurableApplicationContext ctx = app(store, new Apps.Errors())) {
      Cronwatch cw = ctx.getBean(Cronwatch.class);
      await("a failed run", () -> !finished(cw, "Broken.boom").isEmpty());
      await("a checked failure", () -> !finished(cw, "Broken.disk").isEmpty());
      Run boom = finished(cw, "Broken.boom").get(0);
      assertEquals(RunStatus.FAILED, boom.status());
      assertTrue(boom.error().startsWith("IllegalStateException: boom\n"), boom.error());
      Run disk = finished(cw, "Broken.disk").get(0);
      assertTrue(disk.error().startsWith("IOException: disk full\n"), disk.error());
      await("Spring's error handler", () -> ERRORS_HANDLED.get() > before);
    }
  }

  @Test
  void theJobsAreDeclaredFromTheAnnotationsAsSpringReadsThem() throws Exception {
    MemoryStore store = new MemoryStore();
    Apps.Errors errors = new Apps.Errors();
    try (ConfigurableApplicationContext ctx = app(store, errors)) {
      CronwatchScheduling scheduling = ctx.getBean(CronwatchScheduling.class);
      assertTrue(scheduling.watchOfJobs().settle(Duration.ofSeconds(10)));
      String tags = "\"tags\":[\"spring-scheduled\",\"spring-scheduled:billing\"]";
      // The simple name of the bean's class, and the properties name it the same way.
      assertEquals(
          "{\"schedule\":\"0 0 2 * * *\",\"timezone\":\"Europe/London\",\"grace\":\"5m\","
              + tags
              + ",\"name\":\"Declared.london\"}",
          stored(store, "Declared.london"));
      assertEquals(
          "{\"schedule\":\"0 30 1 * * *\"," + tags + ",\"name\":\"Declared.placeholder\"}",
          stored(store, "Declared.placeholder"));
      assertEquals(
          "{" + tags + ",\"name\":\"Declared.firstMonday\"}",
          stored(store, "Declared.firstMonday"));
      assertEquals(
          "{\"schedule\":\"every 2h\"," + tags + ",\"name\":\"Declared.rate\"}",
          stored(store, "Declared.rate"));
      assertEquals(
          "{\"schedule\":\"every 1h30m\"," + tags + ",\"name\":\"Declared.delay\"}",
          stored(store, "Declared.delay"));
      assertNull(store.getJob("Declared.disabled"), "cron = \"-\" schedules nothing");
      assertEquals(
          "{\"schedule\":\"0 0 2 1 * *\",\"timezone\":\"UTC\","
              + tags
              + ",\"name\":\"Declared.monthly\"}",
          stored(store, "Declared.monthly"));
      assertEquals(
          "{\"schedule\":\"0 0 3 * * *\",\"timezone\":\"UTC\",\"grace\":\"15m\",\"tags\":[\"reports\","
              + "\"spring-scheduled\",\"spring-scheduled:billing\"],\"name\":\"nightly-report\","
              + "\"expect\":\"contains \\\"Report written\\\"\"}",
          stored(store, "nightly-report"));
      assertEquals("{" + tags + ",\"name\":\"Declared.twice\"}", stored(store, "Declared.twice"));
      String all = errors.joined();
      assertTrue(
          all.contains(
              "declaring @Scheduled method \"Declared.firstMonday\": cronwatch: @Scheduled method"
                  + " \"Declared.firstMonday\" is \"0 0 9 1 * MON\" in UTC"),
          all);
      assertTrue(all.contains("\"Declared.twice\" is run by 2 Spring entries"), all);
    }
  }

  /**
   * The sync before each check walked every cron's fire times beside CronWatch's again: most of a
   * second each for a cron that fires every second in a zone with daylight saving. A cron unchanged
   * is walked once.
   */
  @Test
  void anUnchangedCronIsWalkedOnce() throws Exception {
    MemoryStore store = new MemoryStore();
    Apps.Errors errors = new Apps.Errors();
    try (ConfigurableApplicationContext ctx = app(store, errors)) {
      CronwatchScheduling scheduling = ctx.getBean(CronwatchScheduling.class);
      int walked = scheduling.walks.get();
      assertTrue(walked > 0);
      scheduling.sync();
      scheduling.sync();
      assertEquals(walked, scheduling.walks.get());
    }
  }

  @Test
  void aBeanDestroyedWhileTheAppRunsHasItsJobDeclaredAgainWithoutItsSchedule() throws Exception {
    MemoryStore store = new MemoryStore();
    try (ConfigurableApplicationContext ctx = app(store, new Apps.Errors())) {
      CronwatchScheduling scheduling = ctx.getBean(CronwatchScheduling.class);
      assertTrue(scheduling.watchOfJobs().settle(Duration.ofSeconds(10)));
      assertTrue(stored(store, "Gone.work").contains("\"schedule\""));
      String name = ctx.getBeanNamesForType(Gone.class)[0];
      ((DefaultListableBeanFactory) ctx.getBeanFactory()).destroySingleton(name);
      await(
          "the job declared without its schedule",
          () -> storedOrEmpty(store, "Gone.work").contains("no longer scheduled"));
    }
    // Closing the context unschedules nothing.
    assertTrue(stored(store, "Declared.placeholder").contains("\"schedule\""));
  }

  @Test
  void aReactiveMethodIsReportedAndWatchedWithoutRuns() throws Exception {
    MemoryStore store = new MemoryStore();
    Apps.Errors errors = new Apps.Errors();
    try (ConfigurableApplicationContext ctx = app(store, errors)) {
      Cronwatch cw = ctx.getBean(Cronwatch.class);
      await("a tick", () -> finished(cw, "Ticks.tick").size() >= 2);
      assertTrue(cw.runs("Reactive.refresh", 5).isEmpty());
      assertFalse(stored(store, "Reactive.refresh").contains("\"schedule\""));
      assertTrue(errors.joined().contains("\"Reactive.refresh\" returns Mono"), errors.joined());
    }
  }

  /** An app with an observation registry of its own, whose handler counts scheduled tasks. */
  @SpringBootConfiguration
  @EnableAutoConfiguration
  @EnableScheduling
  @Import(Ticks.class)
  public static class Observed {
    static final AtomicInteger SEEN = new AtomicInteger();

    /** The app's registry, with a handler of its own. */
    @Bean
    public ObservationRegistry observationRegistry() {
      ObservationRegistry registry = ObservationRegistry.create();
      registry
          .observationConfig()
          .observationHandler(
              new ObservationHandler<Observation.Context>() {
                @Override
                public boolean supportsContext(Observation.Context context) {
                  return context instanceof ScheduledTaskObservationContext;
                }

                @Override
                public void onStop(Observation.Context context) {
                  SEEN.incrementAndGet();
                }
              });
      return registry;
    }
  }

  @Test
  void theAppsOwnObservationRegistryKeepsItsHandlers() throws Exception {
    MemoryStore store = new MemoryStore();
    try (ConfigurableApplicationContext ctx =
        Apps.run(Observed.class, store, new Apps.Errors(), "cronwatch.app=billing")) {
      Cronwatch cw = ctx.getBean(Cronwatch.class);
      await("a recorded run", () -> !finished(cw, "Ticks.tick").isEmpty());
      await("the app's handler", () -> Observed.SEEN.get() > 0);
    }
  }

  @Test
  void theHandlerIsDetachedWhenTheContextCloses() throws Exception {
    MemoryStore store = new MemoryStore();
    ConfigurableApplicationContext ctx = app(store, new Apps.Errors());
    CronwatchScheduling scheduling = ctx.getBean(CronwatchScheduling.class);
    Cronwatch cw = ctx.getBean(Cronwatch.class);
    await("a recorded run", () -> !finished(cw, "Ticks.tick").isEmpty());
    ctx.close();
    ScheduledTaskObservationContext context =
        new ScheduledTaskObservationContext(new Ticks(), Ticks.class.getMethod("tick"));
    scheduling.handler().onStart(context);
    RunFrames.Frame frame = context.get(RunFrames.Frame.class);
    assertNotNull(frame);
    assertNull(frame.run, "no run opened once the context has closed");
    scheduling.handler().onStop(context);
  }

  /** An interface two scheduled beans implement, as advised beans behind JDK proxies are seen. */
  public interface SyncTask {
    void sync();
  }

  /** One of the two. */
  public static class OrdersSync implements SyncTask {
    @Override
    @Scheduled(cron = "0 0 * * * *", zone = "UTC")
    public void sync() {}
  }

  /** The other. */
  public static class InvoicesSync implements SyncTask {
    @Override
    @Scheduled(cron = "0 30 * * * *", zone = "UTC")
    public void sync() {}
  }

  /**
   * With {@code spring.aop.proxy-target-class=false}, Spring observes an advised bean's invocation
   * with the JDK proxy's class, which every bean with its interfaces shares, and the interface's
   * method: one bean alone behind it is found, and two are reported once and credited to neither,
   * never both to whichever was found first.
   */
  @Test
  void anInvocationThroughAJdkProxyIsCreditedOnlyWhenOneBeanFits() throws Exception {
    Apps.Errors errors = new Apps.Errors();
    Class<?> proxyClass =
        java.lang.reflect.Proxy.newProxyInstance(
                SyncTask.class.getClassLoader(),
                new Class<?>[] {SyncTask.class},
                (proxy, method, args) -> null)
            .getClass();
    java.lang.reflect.Method sync = SyncTask.class.getMethod("sync");
    try (Cronwatch cw =
        Cronwatch.builder()
            .store(new MemoryStore())
            .alerts(List.of())
            .noShutdownHook()
            .onError(errors)
            .build()) {
      ScheduledMethods one = new ScheduledMethods();
      one.postProcessAfterInitialization(new OrdersSync(), "orders");
      CronwatchScheduling alone =
          new CronwatchScheduling(cw, one, new CronwatchProperties(), "billing", null, false);
      alone.declare();
      CronwatchScheduling.Target found = alone.target(proxyClass, sync);
      assertNotNull(found);
      assertEquals("OrdersSync.sync", found.name());

      ScheduledMethods two = new ScheduledMethods();
      two.postProcessAfterInitialization(new OrdersSync(), "orders");
      two.postProcessAfterInitialization(new InvoicesSync(), "invoices");
      CronwatchScheduling both =
          new CronwatchScheduling(cw, two, new CronwatchProperties(), "billing", null, false);
      both.declare();
      assertNull(both.target(proxyClass, sync));
      assertNull(both.target(proxyClass, sync));
      List<String> reported = errors.seen.stream().filter(e -> e.contains("JDK proxy")).toList();
      assertEquals(1, reported.size(), errors.joined());
      assertTrue(reported.get(0).contains("spring.aop.proxy-target-class=true"), reported.get(0));
      // The beans' own classes are still told apart.
      CronwatchScheduling.Target orders = both.target(OrdersSync.class, sync);
      assertNotNull(orders);
      assertEquals("OrdersSync.sync", orders.name());
    }
  }

  @Test
  void theCronwatchJobAnnotationIsFoundOnTheMethod() throws Exception {
    List<ScheduledMethods.Found> found;
    ScheduledMethods methods = new ScheduledMethods();
    methods.postProcessAfterInitialization(new Declared(), "declared");
    found = methods.all();
    ScheduledMethods.Found named =
        found.stream().filter(f -> f.method().getName().equals("named")).findFirst().orElseThrow();
    assertNotNull(named.job());
    assertEquals("nightly-report", named.job().name());
    assertSame(Declared.class, named.userClass());
    assertEquals(3_600_000L * 2, ScheduledMethods.millis("PT2H", TimeUnit.MILLISECONDS));
    assertEquals(90_000L, ScheduledMethods.millis("90s", TimeUnit.MILLISECONDS));
    assertEquals(5000L, ScheduledMethods.millis("5", TimeUnit.SECONDS));
    assertEquals(-1L, ScheduledMethods.millis("soon", TimeUnit.SECONDS));
  }
}
