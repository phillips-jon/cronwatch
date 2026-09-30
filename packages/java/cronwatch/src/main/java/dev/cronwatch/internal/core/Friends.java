package dev.cronwatch.internal.core;

import dev.cronwatch.Cronwatch;
import dev.cronwatch.Definition;
import dev.cronwatch.JobOptions;
import java.util.List;
import org.jspecify.annotations.Nullable;

/**
 * What the client lets the rest of the module do without making it public API: the bridge's reads
 * of a job's definition before it is declared, and of the store once it is ready. Set by {@code
 * Cronwatch}'s class initializer, which runs before any of these can be asked, since each takes a
 * client.
 */
public final class Friends {
  /** The client's side. */
  public interface Client {
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
  }

  private static volatile @Nullable Client client;

  private Friends() {}

  /** Called once, by {@code Cronwatch}. */
  public static void set(Client c) {
    client = c;
  }

  /** The client's side. */
  public static Client client() {
    Client c = client;
    if (c == null) {
      try {
        Class.forName("dev.cronwatch.Cronwatch", true, Friends.class.getClassLoader());
      } catch (ClassNotFoundException e) {
        throw new IllegalStateException(e);
      }
      c = client;
      if (c == null) {
        throw new IllegalStateException("dev.cronwatch.Cronwatch did not initialize");
      }
    }
    return c;
  }
}
