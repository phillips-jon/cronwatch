package dev.cronwatch;

import dev.cronwatch.store.SqlStore;
import dev.cronwatch.store.Store;
import java.io.PrintWriter;
import java.sql.Connection;
import java.sql.SQLException;
import java.sql.SQLFeatureNotSupportedException;
import java.util.List;
import java.util.logging.Logger;
import javax.sql.DataSource;
import org.sqlite.SQLiteDataSource;

/**
 * The child JVM {@link ShutdownHookTest} starts: a client over a SQLite file, a run that sleeps,
 * and {@code System.exit} while it sleeps. Its arguments are the file and {@code hook}, {@code
 * nohook}, {@code atstart}, which stops the JVM the moment the run's row is written, or {@code
 * context}, which also closes the client and then the pool from a shutdown hook of its own, as a
 * Spring context closing at shutdown destroys the client's bean before the {@code DataSource}'s.
 */
final class ShutdownChild {
  private ShutdownChild() {}

  /** A pool that refuses connections once closed, as a closed connection pool does. */
  private static final class Pool implements DataSource {
    private final SQLiteDataSource inner;
    private volatile boolean closed;

    Pool(SQLiteDataSource inner) {
      this.inner = inner;
    }

    void close() {
      closed = true;
    }

    private void open() throws SQLException {
      if (closed) {
        throw new SQLException("the pool is closed");
      }
    }

    @Override
    public Connection getConnection() throws SQLException {
      open();
      return inner.getConnection();
    }

    @Override
    public Connection getConnection(String user, String password) throws SQLException {
      open();
      return inner.getConnection(user, password);
    }

    @Override
    public PrintWriter getLogWriter() throws SQLException {
      return inner.getLogWriter();
    }

    @Override
    public void setLogWriter(PrintWriter out) throws SQLException {
      inner.setLogWriter(out);
    }

    @Override
    public void setLoginTimeout(int seconds) throws SQLException {
      inner.setLoginTimeout(seconds);
    }

    @Override
    public int getLoginTimeout() throws SQLException {
      return inner.getLoginTimeout();
    }

    @Override
    public Logger getParentLogger() throws SQLFeatureNotSupportedException {
      throw new SQLFeatureNotSupportedException();
    }

    @Override
    public <T> T unwrap(Class<T> type) throws SQLException {
      return inner.unwrap(type);
    }

    @Override
    public boolean isWrapperFor(Class<?> type) throws SQLException {
      return inner.isWrapperFor(type);
    }
  }

  public static void main(String[] args) throws Exception {
    SQLiteDataSource ds = new SQLiteDataSource();
    ds.setUrl("jdbc:sqlite:" + args[0]);
    Pool pool = new Pool(ds);
    Store store = SqlStore.sqlite(pool);
    if (args[1].equals("atstart")) {
      // The JVM begins to stop the moment the run's row is written, before the client has gone on.
      Support.Wrapped wrapped = new Support.Wrapped(store);
      store = wrapped;
      wrapped.afterInsert =
          () -> {
            Thread.ofPlatform().start(() -> System.exit(3));
            try {
              Thread.sleep(500);
            } catch (InterruptedException e) {
              Thread.currentThread().interrupt();
            }
          };
    }
    Cronwatch.Builder builder = Cronwatch.builder().store(store).alerts(List.of()).noCronSecret();
    if (args[1].equals("nohook")) {
      builder.noShutdownHook();
    }
    Cronwatch cw = builder.build();
    if (args[1].equals("context")) {
      Runtime.getRuntime()
          .addShutdownHook(
              new Thread(
                  () -> {
                    cw.close();
                    pool.close();
                  }));
    }
    Thread.ofPlatform()
        .start(
            () -> {
              try {
                cw.run("interrupted-by-exit", j -> Thread.sleep(120_000));
              } catch (InterruptedException e) {
                Thread.currentThread().interrupt();
              }
            });
    if (args[1].equals("atstart")) {
      Thread.sleep(60_000);
    }
    long deadline = System.nanoTime() + 30_000_000_000L;
    while (cw.runs("interrupted-by-exit", 1).isEmpty() && System.nanoTime() < deadline) {
      Thread.sleep(10);
    }
    System.exit(3);
  }
}
