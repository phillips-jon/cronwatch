package dev.cronwatch;

import dev.cronwatch.alerts.Transport;
import java.util.List;
import java.util.Objects;
import org.jspecify.annotations.Nullable;

/**
 * Adds a short diagnosis to every alert except recoveries: Claude triage ({@code
 * dev.cronwatch.triage.Anthropic}) or any function. It runs on a virtual thread of the client's and
 * is waited on for 25 seconds, then interrupted; a throw, a timeout, or an empty answer is no
 * diagnosis, and triage is not tried again for that alert.
 */
@FunctionalInterface
public interface Triage {
  /**
   * A few sentences on what went wrong, or null or {@code ""} for none.
   *
   * @throws Exception when triage failed, which the client reports
   */
  @Nullable String triage(Context context) throws Exception;

  /**
   * What triage is given.
   *
   * @param alert the alert to diagnose
   * @param recentRuns the job's five newest runs
   * @param transport the client's transport, which Claude triage sends through unless its options
   *     name one of its own
   */
  record Context(Alert alert, List<Run> recentRuns, Transport transport) {
    /** Keeps an unmodifiable copy. */
    public Context {
      Objects.requireNonNull(alert, "alert");
      recentRuns = List.copyOf(recentRuns);
      Objects.requireNonNull(transport, "transport");
    }

    /**
     * A context outside a client (a test): a {@code JdkTransport} is made on the first send through
     * it.
     */
    public Context(Alert alert, List<Run> recentRuns) {
      this(alert, recentRuns, new LazyTransport());
    }
  }
}
