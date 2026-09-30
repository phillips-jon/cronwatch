package dev.cronwatch.spring;

import dev.cronwatch.Cronwatch;
import dev.cronwatch.bridge.Bridge;
import java.time.Duration;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.locks.Condition;
import java.util.concurrent.locks.ReentrantLock;
import org.jspecify.annotations.Nullable;
import org.springframework.context.SmartLifecycle;

/**
 * The check, from when the context has started until it stops: every {@code cronwatch.check-every}
 * (a minute by default, the first a second after the start) the integrations sync (their jobs
 * declared again, and jobs gone from the app declared again without their schedule) and a check
 * runs, on a thread of its own. How it runs across a cluster is {@code cronwatch.check-mode}: under
 * a ShedLock lock of its own name when the app has a {@code LockProvider}, else as a Quartz job
 * when the app's Quartz scheduler is clustered, else in each instance.
 */
final class CronwatchChecker implements SmartLifecycle {
  private static final System.Logger LOGGER = System.getLogger("dev.cronwatch.spring");

  /** Runs work once across a cluster: ShedLock's lock, when the app has one. */
  @FunctionalInterface
  interface ClusterLock {
    /** Runs {@code work} if this instance takes the lock; says whether it did. */
    boolean run(Runnable work);
  }

  /** The Quartz integration, as the check sees it. */
  interface QuartzChecks {
    /** Whether an app's Quartz scheduler is clustered over a JDBC job store. */
    boolean clustered();

    /** Whether the Quartz integration runs the check as a Quartz job. */
    boolean runsTheCheck();

    /** Syncs the Quartz integration's jobs. */
    void sync();
  }

  private final Cronwatch cw;
  private final CronwatchProperties properties;
  private final @Nullable CronwatchScheduling scheduling;
  private final @Nullable ClusterLock clusterLock;
  private final @Nullable QuartzChecks quartz;

  private final ReentrantLock lock = new ReentrantLock();
  private final Condition wake = lock.newCondition();
  private boolean running;

  /** The first check's delay after the start; the tests shorten it. */
  volatile Duration firstDelay = Duration.ofSeconds(1);

  CronwatchChecker(
      Cronwatch cw,
      CronwatchProperties properties,
      @Nullable CronwatchScheduling scheduling,
      @Nullable ClusterLock clusterLock,
      @Nullable QuartzChecks quartz) {
    this.cw = cw;
    this.properties = properties;
    this.scheduling = scheduling;
    this.clusterLock = clusterLock;
    this.quartz = quartz;
  }

  /** The mode {@code cronwatch.check-mode} comes to with what the app has. */
  CronwatchProperties.CheckMode mode() {
    CronwatchProperties.CheckMode mode = properties.getCheckMode();
    return switch (mode) {
      case AUTO -> {
        if (clusterLock != null) {
          yield CronwatchProperties.CheckMode.SHEDLOCK;
        }
        if (quartz != null && quartz.clustered()) {
          yield CronwatchProperties.CheckMode.QUARTZ;
        }
        yield CronwatchProperties.CheckMode.LOCAL;
      }
      case SHEDLOCK -> {
        if (clusterLock == null) {
          LOGGER.log(
              System.Logger.Level.WARNING,
              "[cronwatch] cronwatch.check-mode=shedlock, but the app has no LockProvider; the"
                  + " check runs in each instance");
          yield CronwatchProperties.CheckMode.LOCAL;
        }
        yield mode;
      }
      case QUARTZ -> {
        if (quartz == null) {
          LOGGER.log(
              System.Logger.Level.WARNING,
              "[cronwatch] cronwatch.check-mode=quartz, but the app has no Quartz scheduler; the"
                  + " check runs in each instance");
          yield CronwatchProperties.CheckMode.LOCAL;
        }
        yield mode;
      }
      default -> mode;
    };
  }

  @Override
  public void start() {
    CronwatchProperties.CheckMode mode = mode();
    lock.lock();
    try {
      if (running) {
        return;
      }
      running = true;
    } finally {
      lock.unlock();
    }
    boolean check =
        mode == CronwatchProperties.CheckMode.LOCAL
            || mode == CronwatchProperties.CheckMode.SHEDLOCK;
    if (!check && scheduling == null) {
      return; // nothing to do here: the check is Quartz's or the app's
    }
    Thread.ofVirtual().name("cronwatch-check").start(() -> loop(mode));
  }

  private void loop(CronwatchProperties.CheckMode mode) {
    long wait = firstDelay.toNanos();
    long every = Math.max(TimeUnit.SECONDS.toNanos(5), properties.getCheckEvery().toNanos());
    while (true) {
      lock.lock();
      try {
        long left = wait;
        while (running && left > 0) {
          left = wake.awaitNanos(left);
        }
        if (!running) {
          return;
        }
      } catch (InterruptedException e) {
        return;
      } finally {
        lock.unlock();
      }
      tick(mode);
      wait = every;
    }
  }

  /** One interval's work: the syncs, and the check unless Quartz or nobody runs it. */
  void tick(CronwatchProperties.CheckMode mode) {
    boolean check =
        mode == CronwatchProperties.CheckMode.LOCAL
            || mode == CronwatchProperties.CheckMode.SHEDLOCK;
    Runnable work =
        () -> {
          CronwatchScheduling s = scheduling;
          if (s != null) {
            Bridge.syncWithin(cw, Bridge.SYNC_TIMEOUT, "scheduled", s::sync);
          }
          QuartzChecks q = quartz;
          if (check && q != null && !q.runsTheCheck()) {
            Bridge.syncWithin(cw, Bridge.SYNC_TIMEOUT, "quartz", q::sync);
          }
          if (check) {
            try {
              cw.check();
            } catch (RuntimeException e) {
              cw.reportError(e, "check");
            }
          }
        };
    ClusterLock cluster = clusterLock;
    try {
      if (mode == CronwatchProperties.CheckMode.SHEDLOCK && cluster != null) {
        cluster.run(work);
      } else {
        work.run();
      }
    } catch (RuntimeException e) {
      cw.reportError(e, "check");
    }
  }

  @Override
  public void stop() {
    lock.lock();
    try {
      running = false;
      wake.signalAll();
    } finally {
      lock.unlock();
    }
  }

  @Override
  public boolean isRunning() {
    lock.lock();
    try {
      return running;
    } finally {
      lock.unlock();
    }
  }

  @Override
  public String toString() {
    return "CronwatchChecker[" + properties.getCheckMode() + "]";
  }
}
