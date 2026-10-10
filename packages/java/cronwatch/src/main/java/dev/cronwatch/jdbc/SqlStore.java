package dev.cronwatch.jdbc;

import dev.cronwatch.Definition;
import dev.cronwatch.JobState;
import dev.cronwatch.Run;
import dev.cronwatch.RunStatus;
import dev.cronwatch.StoredJob;
import dev.cronwatch.store.Store;
import java.util.List;
import java.util.Objects;
import javax.sql.DataSource;
import org.jspecify.annotations.Nullable;

/**
 * The SQL store under the package it had before 0.11: every call goes to a {@link
 * dev.cronwatch.store.SqlStore}, which is now beside {@code MemoryStore} in {@code
 * dev.cronwatch.store}.
 *
 * @deprecated use {@link dev.cronwatch.store.SqlStore}, the same store; removed in 2.0
 */
@Deprecated(since = "0.11", forRemoval = true)
public final class SqlStore implements Store {
  private final dev.cronwatch.store.SqlStore store;

  private SqlStore(dev.cronwatch.store.SqlStore store) {
    this.store = Objects.requireNonNull(store, "store");
  }

  /**
   * {@link dev.cronwatch.store.SqlStore#sqlite}.
   *
   * @deprecated use {@link dev.cronwatch.store.SqlStore#sqlite}; removed in 2.0
   */
  @Deprecated(since = "0.11", forRemoval = true)
  public static SqlStore sqlite(DataSource dataSource) {
    return new SqlStore(dev.cronwatch.store.SqlStore.sqlite(dataSource));
  }

  /**
   * {@link dev.cronwatch.store.SqlStore#postgres}.
   *
   * @deprecated use {@link dev.cronwatch.store.SqlStore#postgres}; removed in 2.0
   */
  @Deprecated(since = "0.11", forRemoval = true)
  public static SqlStore postgres(DataSource dataSource) {
    return new SqlStore(dev.cronwatch.store.SqlStore.postgres(dataSource));
  }

  /**
   * {@link dev.cronwatch.store.SqlStore#mysql}.
   *
   * @deprecated use {@link dev.cronwatch.store.SqlStore#mysql}; removed in 2.0
   */
  @Deprecated(since = "0.11", forRemoval = true)
  public static SqlStore mysql(DataSource dataSource) {
    return new SqlStore(dev.cronwatch.store.SqlStore.mysql(dataSource));
  }

  /**
   * {@link dev.cronwatch.store.SqlStore#of}.
   *
   * @throws dev.cronwatch.CronwatchException as that does
   * @deprecated use {@link dev.cronwatch.store.SqlStore#of}; removed in 2.0
   */
  @Deprecated(since = "0.11", forRemoval = true)
  public static SqlStore of(DataSource dataSource) {
    return new SqlStore(dev.cronwatch.store.SqlStore.of(dataSource));
  }

  /**
   * {@link dev.cronwatch.store.SqlStore#prefix}.
   *
   * @throws dev.cronwatch.CronwatchException as that does
   */
  public SqlStore prefix(String prefix) {
    return new SqlStore(store.prefix(prefix));
  }

  /** The prefix of the store's tables. */
  public String tablePrefix() {
    return store.tablePrefix();
  }

  /** The store's database: {@code sqlite}, {@code postgres}, or {@code mysql}. */
  public String dialect() {
    return store.dialect();
  }

  @Override
  public void init() throws Exception {
    store.init();
  }

  @Override
  public void upsertJob(Definition definition, long now) throws Exception {
    store.upsertJob(definition, now);
  }

  @Override
  public @Nullable StoredJob getJob(String name) throws Exception {
    return store.getJob(name);
  }

  @Override
  public List<StoredJob> listJobs() throws Exception {
    return store.listJobs();
  }

  @Override
  public void deleteJob(String name) throws Exception {
    store.deleteJob(name);
  }

  @Override
  public void insertRun(Run run) throws Exception {
    store.insertRun(run);
  }

  @Override
  public void updateRun(Run run) throws Exception {
    store.updateRun(run);
  }

  @Override
  public boolean updateRunIf(Run run, List<RunStatus> from) throws Exception {
    return store.updateRunIf(run, from);
  }

  @Override
  public boolean deleteRunIf(String id, String job, RunStatus status) throws Exception {
    return store.deleteRunIf(id, job, status);
  }

  @Override
  public @Nullable Run getRun(String id) throws Exception {
    return store.getRun(id);
  }

  @Override
  public List<Run> listRuns(String job, int limit) throws Exception {
    return store.listRuns(job, limit);
  }

  @Override
  public @Nullable Run lastRun(String job) throws Exception {
    return store.lastRun(job);
  }

  @Override
  public List<Run> runningRuns() throws Exception {
    return store.runningRuns();
  }

  @Override
  public @Nullable JobState getState(String job) throws Exception {
    return store.getState(job);
  }

  @Override
  public void setState(JobState state) throws Exception {
    store.setState(state);
  }

  @Override
  public boolean compareAndSetState(JobState state, long expected) throws Exception {
    return store.compareAndSetState(state, expected);
  }

  @Override
  public long prune(long before) throws Exception {
    return store.prune(before);
  }

  @Override
  public void close() throws Exception {
    store.close();
  }

  @Override
  public String toString() {
    return store.toString();
  }
}
