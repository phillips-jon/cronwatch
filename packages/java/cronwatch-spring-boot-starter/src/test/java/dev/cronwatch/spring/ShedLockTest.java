package dev.cronwatch.spring;

import static dev.cronwatch.spring.Apps.await;
import static dev.cronwatch.spring.Apps.finished;
import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertTrue;

import dev.cronwatch.Cronwatch;
import dev.cronwatch.Run;
import dev.cronwatch.RunStatus;
import dev.cronwatch.store.MemoryStore;
import java.util.Map;
import java.util.Optional;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.atomic.AtomicInteger;
import net.javacrumbs.shedlock.core.LockConfiguration;
import net.javacrumbs.shedlock.core.LockProvider;
import net.javacrumbs.shedlock.core.SimpleLock;
import net.javacrumbs.shedlock.spring.annotation.EnableSchedulerLock;
import net.javacrumbs.shedlock.spring.annotation.SchedulerLock;
import org.junit.jupiter.api.Test;
import org.springframework.boot.SpringBootConfiguration;
import org.springframework.boot.autoconfigure.EnableAutoConfiguration;
import org.springframework.context.ConfigurableApplicationContext;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Import;
import org.springframework.core.env.Environment;
import org.springframework.scheduling.annotation.EnableScheduling;
import org.springframework.scheduling.annotation.Scheduled;

/**
 * Two instances of one app sharing one store, each running the same {@code @Scheduled} method under
 * ShedLock: the one that takes the lock records the run, and the other gives its run back, so each
 * fire is one run.
 */
class ShedLockTest {
  /** How often the method ran in each instance, by its {@code test.instance}. */
  static final Map<String, AtomicInteger> RAN = new ConcurrentHashMap<>();

  /** Locks the instance {@code test.grant} lets take every lock, and no other. */
  static final class Granting implements LockProvider {
    private final boolean grant;

    Granting(boolean grant) {
      this.grant = grant;
    }

    @Override
    public Optional<SimpleLock> lock(LockConfiguration configuration) {
      return grant ? Optional.of(() -> {}) : Optional.empty();
    }
  }

  /** The method each instance runs under the lock. */
  public static class Report {
    private final Environment environment;

    /** Made by Spring. */
    public Report(Environment environment) {
      this.environment = environment;
    }

    @Scheduled(fixedRate = 1000)
    @SchedulerLock(name = "report", lockAtMostFor = "PT10S")
    public void build() {
      String instance = environment.getProperty("test.instance", "?");
      RAN.computeIfAbsent(instance, k -> new AtomicInteger()).incrementAndGet();
    }
  }

  /** The app. */
  @SpringBootConfiguration
  @EnableAutoConfiguration
  @EnableScheduling
  @EnableSchedulerLock(defaultLockAtMostFor = "PT30S")
  @Import(Report.class)
  public static class App {
    /** A lock provider that answers as {@code test.grant} says. */
    @Bean
    public LockProvider lockProvider(Environment environment) {
      return new Granting(Boolean.parseBoolean(environment.getProperty("test.grant")));
    }
  }

  @Test
  void theInstanceThatTookTheLockRecordsTheRunAndTheOtherGivesItBack() throws Exception {
    MemoryStore store = new MemoryStore();
    Apps.Errors errors = new Apps.Errors();
    try (ConfigurableApplicationContext winner =
            Apps.run(
                App.class,
                store,
                errors,
                "cronwatch.app=billing",
                "test.instance=a",
                "test.grant=true");
        ConfigurableApplicationContext loser =
            Apps.run(
                App.class,
                store,
                errors,
                "cronwatch.app=billing",
                "test.instance=b",
                "test.grant=false")) {
      Cronwatch cw = winner.getBean(Cronwatch.class);
      await("three runs", () -> finished(cw, "Report.build").size() >= 3);
      assertEquals(0, RAN.getOrDefault("b", new AtomicInteger()).get(), "b never ran it");
      // Every finished run the store holds is one a ran: b's were given back, where without the
      // wrapped lock provider each would be recorded too, twice as many.
      int ranA = RAN.get("a").get();
      long ok =
          cw.runs("Report.build", 50).stream().filter(r -> r.status().equals(RunStatus.OK)).count();
      assertTrue(ok <= ranA, "a ran " + ranA + " times, and " + ok + " runs are recorded");
      for (Run r : cw.runs("Report.build", 50)) {
        assertTrue(
            r.status().equals(RunStatus.OK) || r.status().equals(RunStatus.RUNNING), r.toString());
      }
      assertTrue(errors.seen.stream().noneMatch(e -> e.startsWith("discarding")), errors.joined());
      assertEquals(
          CronwatchProperties.CheckMode.SHEDLOCK,
          winner.getBean(CronwatchChecker.class).mode(),
          "with ShedLock, the check runs under its lock");
    }
  }
}
