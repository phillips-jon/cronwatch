package dev.cronwatch.quartz;

import static org.junit.jupiter.api.Assertions.assertTrue;

import dev.cronwatch.Cronwatch;
import dev.cronwatch.store.Store;
import java.net.URI;
import java.sql.Connection;
import java.sql.DriverManager;
import java.sql.SQLException;
import java.util.List;
import java.util.Properties;
import java.util.UUID;
import java.util.concurrent.CopyOnWriteArrayList;
import java.util.function.BooleanSupplier;
import org.jspecify.annotations.Nullable;
import org.quartz.Scheduler;
import org.quartz.SchedulerException;
import org.quartz.impl.StdSchedulerFactory;
import org.quartz.utils.ConnectionProvider;

/**
 * What the Quartz tests share: schedulers, a client, and waiting for what happens in the
 * background.
 */
final class Quartzes {
  private Quartzes() {}

  /** A scheduler on the RAM job store, not started, named for the test alone. */
  static Scheduler ram() throws SchedulerException {
    Properties p = base("ram-" + UUID.randomUUID(), "AUTO");
    p.setProperty("org.quartz.jobStore.class", "org.quartz.simpl.RAMJobStore");
    return new StdSchedulerFactory(p).getScheduler();
  }

  /**
   * A clustered scheduler on the JDBC job store over the Postgres {@code CRONWATCH_TEST_PG} names,
   * not started, with the instance id given and a quick check-in, so a node that stops is found
   * soon.
   */
  static Scheduler clustered(String name, String instanceId) throws SchedulerException {
    Properties p = base(name, instanceId);
    p.setProperty("org.quartz.jobStore.class", "org.quartz.impl.jdbcjobstore.JobStoreTX");
    p.setProperty(
        "org.quartz.jobStore.driverDelegateClass",
        "org.quartz.impl.jdbcjobstore.PostgreSQLDelegate");
    p.setProperty("org.quartz.jobStore.dataSource", "cw");
    p.setProperty("org.quartz.jobStore.isClustered", "true");
    p.setProperty("org.quartz.jobStore.clusterCheckinInterval", "500");
    p.setProperty("org.quartz.jobStore.misfireThreshold", "1000");
    p.setProperty("org.quartz.dataSource.cw.connectionProvider.class", Pg.class.getName());
    return new StdSchedulerFactory(p).getScheduler();
  }

  private static Properties base(String name, String instanceId) {
    Properties p = new Properties();
    p.setProperty("org.quartz.scheduler.instanceName", name);
    p.setProperty("org.quartz.scheduler.instanceId", instanceId);
    p.setProperty("org.quartz.threadPool.threadCount", "4");
    p.setProperty("org.quartz.scheduler.skipUpdateCheck", "true");
    return p;
  }

  /** {@code CRONWATCH_TEST_PG}, or null when it is not set. */
  static @Nullable String pgUrl() {
    String url = System.getenv("CRONWATCH_TEST_PG");
    return url == null || url.isBlank() ? null : url;
  }

  /** A connection to the database {@code CRONWATCH_TEST_PG} names ({@code postgres://...}). */
  static Connection pg() throws SQLException {
    String url = pgUrl();
    if (url == null) {
      throw new SQLException("CRONWATCH_TEST_PG is not set");
    }
    URI uri = URI.create(url);
    String[] user = uri.getUserInfo() == null ? new String[0] : uri.getUserInfo().split(":", 2);
    Properties props = new Properties();
    if (user.length > 0) {
      props.setProperty("user", user[0]);
    }
    if (user.length > 1) {
      props.setProperty("password", user[1]);
    }
    int port = uri.getPort() < 0 ? 5432 : uri.getPort();
    return DriverManager.getConnection(
        "jdbc:postgresql://" + uri.getHost() + ":" + port + uri.getPath(), props);
  }

  /** Quartz's connections for the JDBC job store, straight from the driver. */
  public static final class Pg implements ConnectionProvider {
    /** Made by Quartz. */
    public Pg() {}

    @Override
    public Connection getConnection() throws SQLException {
      return pg();
    }

    @Override
    public void shutdown() {}

    @Override
    public void initialize() {}
  }

  /** A client on {@code store} with no channels, keeping its errors as {@code where: message}. */
  static Cronwatch client(Store store, List<String> errors) {
    return Cronwatch.builder()
        .store(store)
        .alerts(List.of())
        .noShutdownHook()
        .onError((where, error) -> errors.add(where + ": " + error.getMessage()))
        .build();
  }

  /** A list safe to add to from Quartz's threads. */
  static List<String> errors() {
    return new CopyOnWriteArrayList<>();
  }

  /** Waits up to twenty seconds for {@code condition}, polling, and fails with {@code what}. */
  static void await(String what, BooleanSupplier condition) throws InterruptedException {
    long deadline = System.nanoTime() + 20_000_000_000L;
    while (!condition.getAsBoolean()) {
      if (System.nanoTime() > deadline) {
        assertTrue(condition.getAsBoolean(), "waited twenty seconds for: " + what);
        return;
      }
      Thread.sleep(20);
    }
  }
}
