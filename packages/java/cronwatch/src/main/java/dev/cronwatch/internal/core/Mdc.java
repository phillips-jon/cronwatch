package dev.cronwatch.internal.core;

import org.jspecify.annotations.Nullable;

/**
 * SLF4J's MDC keys {@code cronwatch_job} and {@code cronwatch_run} during a run, when SLF4J is on
 * the class path. SLF4J is an optional dependency, compiled against and never required: the MDC
 * class is touched only from {@link Slf4j}, which is loaded only when SLF4J is present.
 */
public final class Mdc {
  private static final boolean PRESENT = present();

  private Mdc() {}

  private static boolean present() {
    try {
      Class.forName("org.slf4j.MDC", false, Mdc.class.getClassLoader());
      return true;
    } catch (ClassNotFoundException | LinkageError e) {
      return false;
    }
  }

  /** The two values a run replaced, to put back when it ends. */
  public record Saved(@Nullable String job, @Nullable String run) {}

  /** Sets the run's keys, returning what they held; null when SLF4J is absent. */
  public static @Nullable Saved put(String job, String run) {
    if (!PRESENT) {
      return null;
    }
    try {
      return Slf4j.put(job, run);
    } catch (LinkageError | RuntimeException e) {
      return null;
    }
  }

  /** Puts back what {@link #put} replaced. */
  public static void restore(@Nullable Saved saved) {
    if (saved == null) {
      return;
    }
    try {
      Slf4j.restore(saved);
    } catch (LinkageError | RuntimeException e) {
      // SLF4J went away or failed; nothing to put back.
    }
  }

  /** The calls to SLF4J itself, in a class of their own. */
  private static final class Slf4j {
    static Saved put(String job, String run) {
      Saved saved =
          new Saved(org.slf4j.MDC.get("cronwatch_job"), org.slf4j.MDC.get("cronwatch_run"));
      org.slf4j.MDC.put("cronwatch_job", job);
      org.slf4j.MDC.put("cronwatch_run", run);
      return saved;
    }

    static void restore(Saved saved) {
      set("cronwatch_job", saved.job());
      set("cronwatch_run", saved.run());
    }

    private static void set(String key, @Nullable String value) {
      if (value == null) {
        org.slf4j.MDC.remove(key);
      } else {
        org.slf4j.MDC.put(key, value);
      }
    }
  }
}
