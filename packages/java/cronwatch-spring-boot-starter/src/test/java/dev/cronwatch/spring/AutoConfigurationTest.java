package dev.cronwatch.spring;

import static dev.cronwatch.spring.Apps.stored;
import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertInstanceOf;
import static org.junit.jupiter.api.Assertions.assertNotSame;
import static org.junit.jupiter.api.Assertions.assertSame;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;

import dev.cronwatch.Cronwatch;
import dev.cronwatch.JobOptions;
import dev.cronwatch.jdbc.SqlStore;
import dev.cronwatch.quartz.CronwatchQuartz;
import dev.cronwatch.store.MemoryStore;
import java.time.Duration;
import java.util.List;
import java.util.Properties;
import java.util.UUID;
import javax.sql.DataSource;
import org.junit.jupiter.api.Test;
import org.quartz.CronScheduleBuilder;
import org.quartz.Job;
import org.quartz.JobBuilder;
import org.quartz.JobExecutionContext;
import org.quartz.Scheduler;
import org.quartz.SchedulerException;
import org.quartz.TriggerBuilder;
import org.quartz.impl.StdSchedulerFactory;
import org.springframework.boot.SpringBootConfiguration;
import org.springframework.boot.autoconfigure.EnableAutoConfiguration;
import org.springframework.context.ConfigurableApplicationContext;
import org.springframework.context.annotation.Bean;
import org.springframework.jdbc.datasource.TransactionAwareDataSourceProxy;
import org.sqlite.SQLiteDataSource;

/**
 * The client from {@code cronwatch.*} properties and the app's own beans, the store over the app's
 * {@code DataSource}, the integrations switched on only when the app has what they watch, the
 * check's mode, and Quartz's schedulers.
 */
class AutoConfigurationTest {
  /** An app with no scheduling and nothing else. */
  @SpringBootConfiguration
  @EnableAutoConfiguration
  public static class Plain {}

  @Test
  void theClientComesFromTheProperties() throws Exception {
    MemoryStore store = new MemoryStore();
    try (ConfigurableApplicationContext ctx =
        Apps.run(
            Plain.class,
            store,
            new Apps.Errors(),
            "cronwatch.retention=7d",
            "cronwatch.defaults.grace=5m",
            "cronwatch.defaults.timezone=UTC",
            "cronwatch.check-mode=none")) {
      Cronwatch cw = ctx.getBean(Cronwatch.class);
      assertSame(store, cw.store(), "the app's Store bean");
      cw.job("x", JobOptions.builder().schedule("0 2 * * *"));
      cw.check();
      assertEquals(
          "{\"grace\":\"5m\",\"timezone\":\"UTC\",\"schedule\":\"0 2 * * *\",\"name\":\"x\"}",
          stored(store, "x"));
      assertTrue(ctx.getBeansOfType(CronwatchScheduling.class).isEmpty(), "no @EnableScheduling");
      assertEquals(CronwatchProperties.CheckMode.NONE, ctx.getBean(CronwatchChecker.class).mode());
    }
  }

  @Test
  void theEnvironmentIsTheActiveProfile() {
    assertEquals("prod", CronwatchAutoConfiguration.profile(new String[] {"cloud", "prod"}));
    assertEquals("cloud", CronwatchAutoConfiguration.profile(new String[] {"cloud", "eu"}));
    assertEquals("dev", CronwatchAutoConfiguration.profile(new String[] {"dev"}));
    assertEquals(null, CronwatchAutoConfiguration.profile(new String[] {}));
  }

  @Test
  void cronwatchEnabledFalseMakesNoClient() {
    try (ConfigurableApplicationContext ctx =
        Apps.run(Plain.class, new MemoryStore(), new Apps.Errors(), "cronwatch.enabled=false")) {
      assertTrue(ctx.getBeansOfType(Cronwatch.class).isEmpty());
      assertTrue(ctx.getBeansOfType(CronwatchChecker.class).isEmpty());
    }
  }

  /** An app with a client of its own. */
  @SpringBootConfiguration
  @EnableAutoConfiguration
  public static class Own {
    static final Cronwatch MINE = Cronwatch.builder().noShutdownHook().alerts(List.of()).build();

    /** The app's own client, which the starter's gives way to. */
    @Bean
    public Cronwatch cronwatch() {
      return MINE;
    }
  }

  @Test
  void anAppsOwnClientReplacesTheStarters() {
    try (ConfigurableApplicationContext ctx =
        Apps.run(Own.class, null, new Apps.Errors(), "cronwatch.check-mode=none")) {
      assertSame(Own.MINE, ctx.getBean(Cronwatch.class));
    }
  }

  /** An app with a DataSource, behind Spring's transaction-aware proxy. */
  @SpringBootConfiguration
  @EnableAutoConfiguration
  public static class WithDatabase {
    /** An in-memory SQLite database, shared while the context lives. */
    @Bean
    public DataSource dataSource() {
      SQLiteDataSource ds = new SQLiteDataSource();
      ds.setUrl("jdbc:sqlite:file:cw" + UUID.randomUUID() + "?mode=memory&cache=shared");
      return new TransactionAwareDataSourceProxy(ds);
    }
  }

  @Test
  void theStoreIsTheAppsDataSourceUnderTheTransactionProxy() {
    try (ConfigurableApplicationContext ctx =
        Apps.run(WithDatabase.class, null, new Apps.Errors(), "cronwatch.check-mode=none")) {
      Cronwatch cw = ctx.getBean(Cronwatch.class);
      assertInstanceOf(SqlStore.class, cw.store());
      cw.job("x", JobOptions.builder());
      cw.check();
      assertEquals(1, cw.jobs().size());
      DataSource proxy = ctx.getBean(DataSource.class);
      DataSource plain = CronwatchAutoConfiguration.plain(proxy);
      assertInstanceOf(SQLiteDataSource.class, plain);
      assertNotSame(proxy, plain);
    }
  }

  @Test
  void aMemoryStoreCanBeAskedForOverTheDataSource() {
    try (ConfigurableApplicationContext ctx =
        Apps.run(
            WithDatabase.class,
            null,
            new Apps.Errors(),
            "cronwatch.store=memory",
            "cronwatch.check-mode=none")) {
      assertInstanceOf(MemoryStore.class, ctx.getBean(Cronwatch.class).store());
    }
  }

  /** An app whose database cannot be reached when it starts. */
  @SpringBootConfiguration
  @EnableAutoConfiguration
  public static class DatabaseDown {
    /** A SQLite database in a directory that does not exist, so no connection can be made. */
    @Bean
    public DataSource dataSource() {
      SQLiteDataSource ds = new SQLiteDataSource();
      ds.setUrl("jdbc:sqlite:/nonexistent-" + UUID.randomUUID() + "/cw.db");
      return ds;
    }
  }

  /**
   * A database that is down when the app starts is not a database the store refuses: the store is
   * not quietly the in-memory one for the life of the app (each instance keeping its own runs, and
   * nothing surviving a restart). The app does not start, as it would not with its own queries.
   */
  @Test
  void aDatabaseDownAtTheStartIsNotTheMemoryStore() {
    Exception e =
        assertThrows(
            Exception.class,
            () ->
                Apps.run(DatabaseDown.class, null, new Apps.Errors(), "cronwatch.check-mode=none"));
    Throwable t = e;
    while (t.getCause() != null && !(t instanceof dev.cronwatch.CronwatchException)) {
      t = t.getCause();
    }
    assertInstanceOf(dev.cronwatch.CronwatchException.class, t, e.toString());
  }

  /** Does nothing, for the scheduler's jobs. */
  public static final class Nothing implements Job {
    @Override
    public void execute(JobExecutionContext context) {}
  }

  /** An app with a Quartz scheduler of its own. */
  @SpringBootConfiguration
  @EnableAutoConfiguration
  public static class WithQuartz {
    /** A scheduler on the RAM job store, with one job, never started. */
    @Bean(destroyMethod = "shutdown")
    public Scheduler scheduler() throws SchedulerException {
      Properties p = new Properties();
      p.setProperty("org.quartz.scheduler.instanceName", "starter-" + UUID.randomUUID());
      p.setProperty("org.quartz.threadPool.threadCount", "1");
      p.setProperty("org.quartz.scheduler.skipUpdateCheck", "true");
      Scheduler s = new StdSchedulerFactory(p).getScheduler();
      s.scheduleJob(
          JobBuilder.newJob(Nothing.class).withIdentity("nightly", "reports").build(),
          TriggerBuilder.newTrigger()
              .withSchedule(CronScheduleBuilder.cronSchedule("0 0 2 * * ?").inTimeZone(utc()))
              .build());
      return s;
    }

    private static java.util.TimeZone utc() {
      return java.util.TimeZone.getTimeZone("UTC");
    }
  }

  @Test
  void theAppsQuartzSchedulersAreWatched() throws Exception {
    MemoryStore store = new MemoryStore();
    try (ConfigurableApplicationContext ctx =
        Apps.run(WithQuartz.class, store, new Apps.Errors(), "cronwatch.app=billing")) {
      Scheduler scheduler = ctx.getBean(Scheduler.class);
      Object watched = scheduler.getContext().get("dev.cronwatch.quartz.CronwatchQuartz");
      assertInstanceOf(CronwatchQuartz.class, watched);
      assertTrue(((CronwatchQuartz) watched).settle(Duration.ofSeconds(10)));
      assertEquals(
          "{\"schedule\":\"0 0 2 * * *\",\"timezone\":\"UTC\",\"tags\":[\"quartz\",\"quartz:billing\"],"
              + "\"name\":\"reports.nightly\"}",
          stored(store, "reports.nightly"));
      CronwatchChecker checker = ctx.getBean(CronwatchChecker.class);
      assertEquals(CronwatchProperties.CheckMode.LOCAL, checker.mode(), "not clustered");
      checker.tick(CronwatchProperties.CheckMode.LOCAL);
    }
  }
}
