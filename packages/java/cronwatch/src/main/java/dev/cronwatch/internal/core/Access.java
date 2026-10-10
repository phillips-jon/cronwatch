package dev.cronwatch.internal.core;

import dev.cronwatch.Cronwatch;
import dev.cronwatch.Definition;
import dev.cronwatch.Job;
import dev.cronwatch.JobContext;
import dev.cronwatch.JobOptions;
import dev.cronwatch.JobState;
import dev.cronwatch.Run;
import java.util.List;
import org.jspecify.annotations.Nullable;

/**
 * What the rest of the module needs of the client that its public API does not offer: for the
 * dashboard and a job's handler ({@code dev.cronwatch.web}), a silence of any number of
 * milliseconds, the environment as the client reads it, the cron secret's opt-out, and a run whose
 * throw is handed back rather than thrown; for the bridge, a job's definition before it is
 * declared, the store once it is ready, a stored expect rule, and a job's tags. {@code Cronwatch}
 * installs the client's side when its class is initialized, which it is before any client or job
 * exists to pass here, and only that first installation counts.
 */
public final class Access {
  private Access() {}

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

  /** The client's side. */
  public interface Client {
    /** {@code cw.silence(name, ms)} for a duration already read. */
    JobState silence(Cronwatch cw, String name, double ms);

    /** The environment as the client reads it, the builder's fallback included. */
    String environment(Cronwatch cw);

    /** Whether the client declares {@code name} now (not forgotten since it was declared). */
    boolean declares(Cronwatch cw, String name);

    /** Whether the client was built with {@code noCronSecret()}. */
    boolean secretOptOut(Cronwatch cw);

    /** True the first time a handler of this client refuses a request for want of a secret. */
    boolean firstNoSecretRefusal(Cronwatch cw);

    /** Runs {@code body} as a recorded run with this trigger, handing back what it threw. */
    Caught run(Job job, String trigger, Body body);

    /**
     * The definition {@code cw.job(name, options)} would declare, checked with the SDK's messages
     * and not declared.
     */
    Definition describe(Cronwatch cw, String name, JobOptions options);

    /** Initializes the client's store, once. */
    void ensureReady(Cronwatch cw);

    /**
     * {@code options} with the expect rule a stored definition describes ({@code contains "x"},
     * {@code matches /x/}, {@code custom function}): a pattern the engine cannot read passes every
     * output and keeps its description, and a custom function passes every output.
     */
    JobOptions withStoredExpect(JobOptions options, String description);

    /** The tags {@code options} gives, in order; none when it gives none or not a list. */
    List<String> tags(JobOptions options);

    /**
     * The definition {@code {name}} a store reads from a row whose definition is not a JSON object,
     * marked so the client reports the job rather than evaluate it.
     */
    Definition unreadableDefinition(String name);
  }

  private static volatile @Nullable Client client;

  /**
   * Installs the client's side; called once, by {@code Cronwatch}'s static initializer. A later
   * call (code on the class path reaching into this package) changes nothing.
   */
  public static synchronized void install(Client c) {
    if (client == null) {
      client = c;
    }
  }

  /** The client's side. */
  public static Client client() {
    Client c = client;
    if (c == null) {
      try {
        Class.forName("dev.cronwatch.Cronwatch", true, Access.class.getClassLoader());
      } catch (ClassNotFoundException e) {
        throw new IllegalStateException(e);
      }
      c = client;
      if (c == null) {
        throw new IllegalStateException("dev.cronwatch.Cronwatch did not install its access");
      }
    }
    return c;
  }
}
