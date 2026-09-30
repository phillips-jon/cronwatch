package dev.cronwatch.jdbc;

import static org.junit.jupiter.api.Assumptions.assumeTrue;

import java.io.PrintWriter;
import java.net.URI;
import java.net.URLDecoder;
import java.nio.charset.StandardCharsets;
import java.sql.Connection;
import java.sql.DriverManager;
import java.sql.SQLException;
import java.sql.SQLFeatureNotSupportedException;
import java.sql.Statement;
import java.util.concurrent.ThreadLocalRandom;
import java.util.concurrent.atomic.AtomicInteger;
import java.util.logging.Logger;
import javax.sql.DataSource;
import org.jspecify.annotations.Nullable;

/**
 * The database servers the tests run against when their variables are set: {@code
 * CRONWATCH_TEST_PG} (Postgres), {@code CRONWATCH_TEST_MYSQL} (MySQL), {@code
 * CRONWATCH_TEST_MARIADB} (MariaDB) and {@code CRONWATCH_TEST_PGCRON} (a Postgres with pg_cron),
 * each a URL such as {@code postgres://postgres:pw@127.0.0.1:5432/cw} or {@code
 * mysql://root:pw@127.0.0.1:3306/cw}, as the Go, Rust and Elixir ports read them. A test on a
 * server whose variable is unset is skipped, saying so. Each test uses tables of a prefix of its
 * own, dropped when it ends, so the tests share a server.
 *
 * <p>The drivers are pgjdbc for Postgres, Connector/J for MySQL and MariaDB Connector/J for
 * MariaDB, each through {@link DriverManager}, so no driver class is named here.
 */
public final class Servers {
  private Servers() {}

  /** A server the tests can run against. */
  public enum Kind {
    /** Postgres. */
    PG("CRONWATCH_TEST_PG"),
    /** MySQL. */
    MYSQL("CRONWATCH_TEST_MYSQL"),
    /** MariaDB. */
    MARIADB("CRONWATCH_TEST_MARIADB"),
    /** A Postgres with pg_cron. */
    PGCRON("CRONWATCH_TEST_PGCRON");

    private final String variable;

    Kind(String variable) {
      this.variable = variable;
    }

    /** The variable naming the server. */
    public String variable() {
      return variable;
    }
  }

  private static final AtomicInteger COUNTER = new AtomicInteger();

  /** The server's URL, or null when its variable is unset or empty. */
  public static @Nullable String url(Kind kind) {
    String url = System.getenv(kind.variable());
    return url == null || url.isEmpty() ? null : url;
  }

  /** Skips the test, saying why, when the server's variable is unset. */
  public static void assume(Kind kind) {
    assumeTrue(url(kind) != null, kind.variable() + " is not set");
  }

  /** A table prefix no other test uses, on this run or another at once. */
  public static String prefix() {
    return "cwt"
        + Integer.toString(ThreadLocalRandom.current().nextInt(1 << 20), 36)
        + COUNTER.incrementAndGet()
        + "_";
  }

  /** A data source over the server, a new connection each time it is asked for one. */
  public static DataSource dataSource(Kind kind) {
    return dataSource(kind, "");
  }

  /**
   * A data source over the server with the driver's own settings added to its URL ({@code
   * useAffectedRows=true}, say).
   */
  public static DataSource dataSource(Kind kind, String settings) {
    return dataSource(kind, null, null, null, settings);
  }

  /**
   * A data source over the server, on another database or as another role when they are given (null
   * for the URL's own), with the driver's own settings added to its URL.
   */
  public static DataSource dataSource(
      Kind kind,
      @Nullable String database,
      @Nullable String role,
      @Nullable String rolePassword,
      String settings) {
    String url = url(kind);
    if (url == null) {
      throw new IllegalStateException(kind.variable() + " is not set");
    }
    URI u = URI.create(url);
    String user = "";
    String password = "";
    String info = u.getRawUserInfo();
    if (info != null) {
      int colon = info.indexOf(':');
      user = decode(colon < 0 ? info : info.substring(0, colon));
      password = colon < 0 ? "" : decode(info.substring(colon + 1));
    }
    String path = u.getRawPath() == null ? "" : u.getRawPath();
    if (database != null) {
      path = "/" + database;
    }
    if (role != null) {
      user = role;
      password = rolePassword == null ? "" : rolePassword;
    }
    String jdbc =
        switch (kind) {
          case PG, PGCRON -> "jdbc:postgresql://" + host(u, 5432) + path;
          // TLS off and the server's key fetched for caching_sha2_password: a test server in a
          // container, never an app's.
          case MYSQL ->
              "jdbc:mysql://" + host(u, 3306) + path + "?allowPublicKeyRetrieval=true&useSSL=false";
          case MARIADB -> "jdbc:mariadb://" + host(u, 3306) + path;
        };
    if (!settings.isEmpty()) {
      jdbc += (jdbc.contains("?") ? "&" : "?") + settings;
    }
    return new UrlDataSource(jdbc, user, password);
  }

  private static String host(URI u, int port) {
    return u.getHost() + ":" + (u.getPort() < 0 ? port : u.getPort());
  }

  private static String decode(String s) {
    return URLDecoder.decode(s, StandardCharsets.UTF_8);
  }

  /** The store for the server's database, on tables of {@code prefix}. */
  public static SqlStore store(Kind kind, String prefix) {
    DataSource ds = dataSource(kind);
    SqlStore store =
        kind == Kind.MYSQL || kind == Kind.MARIADB ? SqlStore.mysql(ds) : SqlStore.postgres(ds);
    return store.prefix(prefix);
  }

  /** Runs statements on a connection of their own, as another process would. */
  public static void exec(Kind kind, String... statements) throws SQLException {
    try (Connection c = dataSource(kind).getConnection();
        Statement s = c.createStatement()) {
      for (String statement : statements) {
        s.execute(statement);
      }
    }
  }

  /** Drops the store's three tables of {@code prefix}. */
  public static void drop(Kind kind, String prefix) throws SQLException {
    for (String table : new String[] {"runs", "state", "jobs"}) {
      exec(kind, "DROP TABLE IF EXISTS " + prefix + table);
    }
  }

  /** A data source that opens each connection through {@link DriverManager}. */
  private static final class UrlDataSource implements DataSource {
    private final String url;
    private final String user;
    private final String password;

    UrlDataSource(String url, String user, String password) {
      this.url = url;
      this.user = user;
      this.password = password;
    }

    @Override
    public Connection getConnection() throws SQLException {
      return DriverManager.getConnection(url, user, password);
    }

    @Override
    public Connection getConnection(String username, String pw) throws SQLException {
      return DriverManager.getConnection(url, username, pw);
    }

    @Override
    public @Nullable PrintWriter getLogWriter() {
      return null;
    }

    @Override
    public void setLogWriter(@Nullable PrintWriter out) {}

    @Override
    public void setLoginTimeout(int seconds) {}

    @Override
    public int getLoginTimeout() {
      return 0;
    }

    @Override
    public Logger getParentLogger() throws SQLFeatureNotSupportedException {
      throw new SQLFeatureNotSupportedException();
    }

    @Override
    public <T> T unwrap(Class<T> iface) throws SQLException {
      throw new SQLException("not a wrapper");
    }

    @Override
    public boolean isWrapperFor(Class<?> iface) {
      return false;
    }

    /** Never the URL's credentials. */
    @Override
    public String toString() {
      return "UrlDataSource";
    }
  }
}
