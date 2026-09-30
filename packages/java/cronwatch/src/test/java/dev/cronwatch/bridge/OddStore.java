package dev.cronwatch.bridge;

import dev.cronwatch.Definition;
import dev.cronwatch.JobState;
import dev.cronwatch.Run;
import dev.cronwatch.RunStatus;
import dev.cronwatch.StoredJob;
import dev.cronwatch.store.MemoryStore;
import dev.cronwatch.store.Store;
import java.util.List;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.atomic.AtomicBoolean;
import java.util.concurrent.atomic.AtomicReference;
import org.jspecify.annotations.Nullable;

/**
 * A memory store whose {@code getJob} fails while {@link #failing} is set, whose {@code upsertJob}
 * throws once while {@link #throwsOnce} is set, hangs while {@link #hang} is closed, and whose
 * {@code listJobs} runs {@link #meanwhile} once.
 */
final class OddStore implements Store {
  final MemoryStore inner = new MemoryStore();
  final AtomicBoolean failing = new AtomicBoolean();
  final AtomicBoolean throwsOnce = new AtomicBoolean();
  final AtomicReference<@Nullable Runnable> meanwhile = new AtomicReference<>();
  volatile @Nullable CountDownLatch hang;

  @Override
  public void init() throws Exception {
    inner.init();
  }

  @Override
  public void upsertJob(Definition definition, long now) throws Exception {
    if (throwsOnce.compareAndSet(true, false)) {
      throw new IllegalStateException("the store fell over");
    }
    CountDownLatch h = hang;
    if (h != null) {
      h.await();
    }
    inner.upsertJob(definition, now);
  }

  @Override
  public @Nullable StoredJob getJob(String name) throws Exception {
    if (failing.get()) {
      throw new IllegalStateException("the store is down");
    }
    return inner.getJob(name);
  }

  @Override
  public List<StoredJob> listJobs() throws Exception {
    Runnable m = meanwhile.getAndSet(null);
    if (m != null) {
      m.run();
    }
    return inner.listJobs();
  }

  @Override
  public void deleteJob(String name) throws Exception {
    inner.deleteJob(name);
  }

  @Override
  public void insertRun(Run run) throws Exception {
    inner.insertRun(run);
  }

  @Override
  public void updateRun(Run run) throws Exception {
    inner.updateRun(run);
  }

  @Override
  public @Nullable Run getRun(String id) throws Exception {
    return inner.getRun(id);
  }

  @Override
  public List<Run> listRuns(String job, int limit) throws Exception {
    return inner.listRuns(job, limit);
  }

  @Override
  public List<Run> runningRuns() throws Exception {
    return inner.runningRuns();
  }

  @Override
  public @Nullable JobState getState(String job) throws Exception {
    return inner.getState(job);
  }

  @Override
  public void setState(JobState state) throws Exception {
    inner.setState(state);
  }

  @Override
  public long prune(long before) throws Exception {
    return inner.prune(before);
  }

  @Override
  public boolean updateRunIf(Run run, List<RunStatus> from) throws Exception {
    return inner.updateRunIf(run, from);
  }

  @Override
  public boolean compareAndSetState(JobState state, long expected) throws Exception {
    return inner.compareAndSetState(state, expected);
  }

  @Override
  public boolean deleteRunIf(String id, String job, RunStatus status) throws Exception {
    return inner.deleteRunIf(id, job, status);
  }
}
