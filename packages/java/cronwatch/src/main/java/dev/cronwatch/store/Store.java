package dev.cronwatch.store;

import dev.cronwatch.Definition;
import dev.cronwatch.JobState;
import dev.cronwatch.Run;
import dev.cronwatch.RunStatus;
import dev.cronwatch.StoredJob;
import java.util.List;
import org.jspecify.annotations.Nullable;

/**
 * Where jobs, runs, and state live: the SDK's {@code Store}. {@link MemoryStore} is one, and {@code
 * SqlStore} keeps them in the app's own database. A store of the app's own should pass {@code
 * dev.cronwatch.storetest.StoreContract}.
 *
 * <p>Every method may be called from any number of threads at once. Any exception is the store's
 * failure: the client reports it to its error handler and carries on, and never lets it stop a job.
 * The three conditional writes are default methods that throw {@link
 * UnsupportedOperationException}; the client then falls back to a read and a write, as the SDK
 * does, which is safe only while one process at a time writes a given run or state. A store that
 * can make them in one step overrides them.
 */
public interface Store extends AutoCloseable {
  /**
   * Called once before first use: create tables here.
   *
   * @throws Exception when the store cannot be used
   */
  default void init() throws Exception {}

  /**
   * Writes a job's definition, keeping its {@code createdAt} when it is already stored.
   *
   * @throws Exception when the store fails
   */
  void upsertJob(Definition definition, long now) throws Exception;

  /**
   * The job, or null when the store does not know it.
   *
   * @throws Exception when the store fails
   */
  @Nullable StoredJob getJob(String name) throws Exception;

  /**
   * Every job, by name in UTF-16 code unit order (which is byte order for UTF-8 text outside the
   * surrogates, and what {@code COLLATE "C"} and SQLite give).
   *
   * @throws Exception when the store fails
   */
  List<StoredJob> listJobs() throws Exception;

  /**
   * Removes a job, its runs, and its state.
   *
   * @throws Exception when the store fails
   */
  void deleteJob(String name) throws Exception;

  /**
   * Inserts a run, refusing an id already stored.
   *
   * @throws Exception when the store fails or the id is taken
   */
  void insertRun(Run run) throws Exception;

  /**
   * Writes a run's status, finish, duration, error, output, and metrics. A run that is gone stays
   * gone.
   *
   * @throws Exception when the store fails
   */
  void updateRun(Run run) throws Exception;

  /**
   * The run, or null when there is no such run.
   *
   * @throws Exception when the store fails
   */
  @Nullable Run getRun(String id) throws Exception;

  /**
   * A job's newest runs first (ties broken by the order they were inserted, newest first), at most
   * {@code limit} of them.
   *
   * @throws Exception when the store fails
   */
  List<Run> listRuns(String job, int limit) throws Exception;

  /**
   * A job's newest run, or null.
   *
   * @throws Exception when the store fails
   */
  default @Nullable Run lastRun(String job) throws Exception {
    List<Run> runs = listRuns(job, 1);
    return runs.isEmpty() ? null : runs.get(0);
  }

  /**
   * Every run still running, oldest first.
   *
   * @throws Exception when the store fails
   */
  List<Run> runningRuns() throws Exception;

  /**
   * A job's state, or null when it has none yet.
   *
   * @throws Exception when the store fails
   */
  @Nullable JobState getState(String job) throws Exception;

  /**
   * Writes a job's state unconditionally. Used only when {@link #compareAndSetState} is
   * unsupported.
   *
   * @throws Exception when the store fails
   */
  void setState(JobState state) throws Exception;

  /**
   * Deletes finished runs that started before this time, keeping each job's newest run whatever its
   * age, and returns how many.
   *
   * @throws Exception when the store fails
   */
  long prune(long before) throws Exception;

  /**
   * Lets go of what the store holds. The client calls it from its own {@code close()}.
   *
   * @throws Exception when closing fails
   */
  @Override
  default void close() throws Exception {}

  /**
   * Writes the run as {@link #updateRun} does, only when its stored status is one of {@code from},
   * in one step (SQL: {@code UPDATE ... WHERE id = ? AND status IN (...)}), and says whether it
   * wrote. This is what lets exactly one of several processes finishing the same run evaluate it.
   *
   * @throws UnsupportedOperationException when the store cannot (the default)
   * @throws Exception when the store fails
   */
  default boolean updateRunIf(Run run, List<RunStatus> from) throws Exception {
    throw new UnsupportedOperationException("updateRunIf");
  }

  /**
   * Writes {@code state} only when the stored state's version (absent, or no row at all, counts as
   * 0; see {@link JobState#countedVersion}) equals {@code expected}, and says whether it wrote.
   * This keeps two processes sharing a store from overwriting each other's updates.
   *
   * @throws UnsupportedOperationException when the store cannot (the default)
   * @throws Exception when the store fails
   */
  default boolean compareAndSetState(JobState state, long expected) throws Exception {
    throw new UnsupportedOperationException("compareAndSetState");
  }

  /**
   * Deletes the run {@code id} only when its stored job is {@code job} and its status is {@code
   * status} (SQL: {@code DELETE ... WHERE id = ? AND job = ? AND status = ?}), and says whether it
   * deleted. The SDK has no counterpart: it is how an attempt a scheduler gave back without failing
   * leaves no run behind, as the Go, PHP, Rust, and Elixir ports' stores take one back.
   *
   * @throws UnsupportedOperationException when the store cannot (the default)
   * @throws Exception when the store fails
   */
  default boolean deleteRunIf(String id, String job, RunStatus status) throws Exception {
    throw new UnsupportedOperationException("deleteRunIf");
  }
}
