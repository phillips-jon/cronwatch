package dev.cronwatch.store;

import dev.cronwatch.Definition;
import dev.cronwatch.JobState;
import dev.cronwatch.Metrics;
import dev.cronwatch.Run;
import dev.cronwatch.RunStatus;
import dev.cronwatch.StoredJob;
import dev.cronwatch.internal.output.Output;
import dev.cronwatch.json.Json;
import java.util.ArrayList;
import java.util.Comparator;
import java.util.HashMap;
import java.util.Iterator;
import java.util.List;
import java.util.Map;
import java.util.concurrent.locks.ReentrantLock;
import java.util.function.Predicate;
import org.jspecify.annotations.Nullable;

/**
 * Keeps everything in process memory (the SDK's {@code stores/memory.ts}). The default when no
 * store is given, good for tests and for trying the library out. State is gone on restart, so a
 * missed run cannot be noticed across one. Its values are immutable records, so what goes in and
 * out needs no copying.
 */
public final class MemoryStore implements Store {
  private final ReentrantLock lock = new ReentrantLock();
  private final Map<String, StoredJob> jobs = new HashMap<>();

  /**
   * Each run and the order it was inserted in, which breaks ties between runs that started in the
   * same millisecond.
   */
  private final Map<String, Entry> runs = new HashMap<>();

  private final Map<String, JobState> states = new HashMap<>();
  private long seq;

  private record Entry(Run run, long seq) {}

  /** An empty in-memory store. */
  public MemoryStore() {}

  // Text is held as the SQL store writes it, without U+0000, so every store reads back the same:
  // a run's trigger, output, error, and metric names, and every key and string of a definition and
  // a state. Identifiers are held as given.

  private static Definition kept(Definition definition) {
    String json = definition.toJson();
    String clean = Output.stripJsonNul(json);
    return clean.equals(json) ? definition : Definition.fromJson(clean);
  }

  private static JobState kept(JobState state) {
    String json = state.toJson();
    String clean = Output.stripJsonNul(json);
    return clean.equals(json) ? state : JobState.fromJson(clean);
  }

  private static Metrics kept(Metrics metrics) {
    String json = metrics.toJson();
    String clean = Output.stripJsonNul(json);
    return clean.equals(json) ? metrics : Metrics.lenient(Json.parse(clean));
  }

  private static Run kept(Run run) {
    return Run.of(
        run.id(),
        run.job(),
        run.status(),
        run.startedAt(),
        run.finishedAt(),
        run.durationMs(),
        Output.stripNulOrNull(run.error()),
        Output.stripNulOrNull(run.output()),
        kept(run.metrics()),
        Output.stripNul(run.trigger()));
  }

  @Override
  public void upsertJob(Definition definition, long now) {
    lock.lock();
    try {
      String name = definition.name();
      StoredJob existing = jobs.get(name);
      long createdAt = existing == null ? now : existing.createdAt();
      jobs.put(name, StoredJob.of(name, kept(definition), createdAt, now));
    } finally {
      lock.unlock();
    }
  }

  @Override
  public @Nullable StoredJob getJob(String name) {
    lock.lock();
    try {
      return jobs.get(name);
    } finally {
      lock.unlock();
    }
  }

  /**
   * Every job by name in UTF-16 code unit order, JavaScript's default sort, as the SDK's has it.
   */
  @Override
  public List<StoredJob> listJobs() {
    List<StoredJob> out;
    lock.lock();
    try {
      out = new ArrayList<>(jobs.values());
    } finally {
      lock.unlock();
    }
    out.sort(Comparator.comparing(StoredJob::name));
    return out;
  }

  @Override
  public void deleteJob(String name) {
    lock.lock();
    try {
      jobs.remove(name);
      states.remove(name);
      runs.values().removeIf(e -> e.run().job().equals(name));
    } finally {
      lock.unlock();
    }
  }

  /** Refuses an id already recorded, like SQL's primary key. */
  @Override
  public void insertRun(Run run) {
    lock.lock();
    try {
      if (runs.containsKey(run.id())) {
        throw new IllegalStateException("run " + run.id() + " already exists");
      }
      runs.put(run.id(), new Entry(kept(run), ++seq));
    } finally {
      lock.unlock();
    }
  }

  /** Changes only the finish's fields; a run that is gone (its job was forgotten) stays gone. */
  @Override
  public void updateRun(Run run) {
    lock.lock();
    try {
      Entry e = runs.get(run.id());
      if (e != null) {
        runs.put(run.id(), new Entry(finish(e.run(), run), e.seq()));
      }
    } finally {
      lock.unlock();
    }
  }

  @Override
  public boolean updateRunIf(Run run, List<RunStatus> from) {
    lock.lock();
    try {
      Entry e = runs.get(run.id());
      if (e == null || !from.contains(e.run().status())) {
        return false;
      }
      runs.put(run.id(), new Entry(finish(e.run(), run), e.seq()));
      return true;
    } finally {
      lock.unlock();
    }
  }

  @Override
  public boolean deleteRunIf(String id, String job, RunStatus status) {
    lock.lock();
    try {
      Entry e = runs.get(id);
      if (e == null || !e.run().job().equals(job) || !e.run().status().equals(status)) {
        return false;
      }
      runs.remove(id);
      return true;
    } finally {
      lock.unlock();
    }
  }

  /** The fields a finish changes, written onto a stored run. */
  private static Run finish(Run existing, Run run) {
    return existing.finished(
        run.status(),
        run.finishedAt(),
        run.durationMs(),
        Output.stripNulOrNull(run.error()),
        Output.stripNulOrNull(run.output()),
        kept(run.metrics()));
  }

  @Override
  public @Nullable Run getRun(String id) {
    lock.lock();
    try {
      Entry e = runs.get(id);
      return e == null ? null : e.run();
    } finally {
      lock.unlock();
    }
  }

  private List<Run> sorted(Predicate<Run> keep, boolean newestFirst) {
    List<Entry> out = new ArrayList<>();
    lock.lock();
    try {
      for (Entry e : runs.values()) {
        if (keep.test(e.run())) {
          out.add(e);
        }
      }
    } finally {
      lock.unlock();
    }
    Comparator<Entry> order =
        Comparator.comparingLong((Entry e) -> e.run().startedAt()).thenComparingLong(Entry::seq);
    out.sort(newestFirst ? order.reversed() : order);
    List<Run> runsOut = new ArrayList<>(out.size());
    for (Entry e : out) {
      runsOut.add(e.run());
    }
    return runsOut;
  }

  @Override
  public List<Run> listRuns(String job, int limit) {
    List<Run> out = sorted(r -> r.job().equals(job), true);
    return out.size() > limit ? new ArrayList<>(out.subList(0, Math.max(0, limit))) : out;
  }

  @Override
  public List<Run> runningRuns() {
    return sorted(r -> r.status().equals(RunStatus.RUNNING), false);
  }

  @Override
  public @Nullable JobState getState(String job) {
    lock.lock();
    try {
      return states.get(job);
    } finally {
      lock.unlock();
    }
  }

  @Override
  public void setState(JobState state) {
    lock.lock();
    try {
      states.put(state.job(), kept(state));
    } finally {
      lock.unlock();
    }
  }

  @Override
  public boolean compareAndSetState(JobState state, long expected) {
    lock.lock();
    try {
      JobState current = states.get(state.job());
      long version = current == null ? 0 : current.countedVersion();
      if (version != expected) {
        return false;
      }
      states.put(state.job(), kept(state));
      return true;
    } finally {
      lock.unlock();
    }
  }

  /**
   * Keeps each job's newest run whatever its age: without it, a job that runs less often than the
   * retention looks like it never ran.
   */
  @Override
  public long prune(long before) {
    lock.lock();
    try {
      Map<String, Long> newest = new HashMap<>();
      for (Entry e : runs.values()) {
        newest.merge(e.run().job(), e.run().startedAt(), Math::max);
      }
      long n = 0;
      for (Iterator<Entry> it = runs.values().iterator(); it.hasNext(); ) {
        Run r = it.next().run();
        if (!r.status().equals(RunStatus.RUNNING)
            && r.startedAt() < before
            && r.startedAt() < newest.get(r.job())) {
          it.remove();
          n++;
        }
      }
      return n;
    } finally {
      lock.unlock();
    }
  }
}
