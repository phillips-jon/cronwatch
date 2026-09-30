package dev.cronwatch.internal.core;

import dev.cronwatch.Cronwatch;
import dev.cronwatch.Job;
import dev.cronwatch.JobContext;
import dev.cronwatch.JobState;
import dev.cronwatch.Run;
import org.jspecify.annotations.Nullable;

/**
 * What the dashboard and a job's handler ({@code dev.cronwatch.web}) need of the client that its
 * public API does not offer: a silence of any number of milliseconds, the environment as the client
 * reads it, the cron secret's opt-out, and a run whose throw is handed back rather than thrown.
 * {@code Cronwatch} installs the hooks when its class is initialized, which it is before any client
 * or job exists to pass here.
 */
public final class WebAccess {
  private WebAccess() {}

  /** A run as recorded, what its function returned, and what it threw. */
  public record Caught(Run run, @Nullable Object value, @Nullable Throwable thrown) {}

  /** A handler's function over the run's context. */
  @FunctionalInterface
  public interface Body {
    /**
     * Runs the function.
     *
     * @throws Exception whatever the function throws
     */
    @Nullable Object call(JobContext job) throws Exception;
  }

  /** What the client offers the web package. */
  public interface Hooks {
    /** {@code cw.silence(name, ms)} for a duration already read. */
    JobState silence(Cronwatch cw, String name, double ms);

    /** The environment as the client reads it, the builder's fallback included. */
    String environment(Cronwatch cw);

    /** Whether the client was built with {@code noCronSecret()}. */
    boolean secretOptOut(Cronwatch cw);

    /** True the first time a handler of this client refuses a request for want of a secret. */
    boolean firstNoSecretRefusal(Cronwatch cw);

    /** Runs {@code body} as a recorded run with this trigger, handing back what it threw. */
    Caught run(Job job, String trigger, Body body);
  }

  private static volatile @Nullable Hooks hooks;

  /** Installs the hooks; called once, by {@code Cronwatch}'s static initializer. */
  public static void install(Hooks h) {
    hooks = h;
  }

  /** The hooks. */
  public static Hooks hooks() {
    Hooks h = hooks;
    if (h == null) {
      try {
        Class.forName("dev.cronwatch.Cronwatch", true, WebAccess.class.getClassLoader());
      } catch (ClassNotFoundException e) {
        throw new IllegalStateException(e);
      }
      h = hooks;
      if (h == null) {
        throw new IllegalStateException("dev.cronwatch.Cronwatch did not install its hooks");
      }
    }
    return h;
  }
}
