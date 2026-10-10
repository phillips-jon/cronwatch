package dev.cronwatch;

import java.util.Objects;
import org.jspecify.annotations.Nullable;

/**
 * What went wrong outside a job: an option, a name, a schedule, or a run id the SDK refuses (with
 * the SDK's message, word for word), a store that failed (its own exception as the cause), or
 * something else. Unchecked. A read ({@code jobs()}, {@code jobSummary()}, {@code runs()}) and
 * {@code check()} throw it when the store fails; {@code run}, {@code start}, {@code flush}, and
 * {@code finish} never do.
 */
public final class CronwatchException extends RuntimeException {
  private static final long serialVersionUID = 1L;

  /** What kind of failure it is. */
  public enum Kind {
    /** An option, a name, a schedule, or a run id the SDK refuses. */
    INVALID,
    /** The store failed; the cause is its exception. */
    STORE,
    /** Anything else: a stored definition that cannot be evaluated, a state that kept changing. */
    OTHER
  }

  private final Kind kind;

  /** An exception of this kind with this message. */
  public CronwatchException(Kind kind, String message) {
    super(message);
    this.kind = Objects.requireNonNull(kind, "kind");
  }

  /** An exception of this kind with this message and cause. */
  public CronwatchException(Kind kind, String message, @Nullable Throwable cause) {
    super(message, cause);
    this.kind = Objects.requireNonNull(kind, "kind");
  }

  /** What the SDK would refuse, with its message. */
  public static CronwatchException invalid(String message) {
    return new CronwatchException(Kind.INVALID, message);
  }

  /** The store's failure, its message this exception's own. */
  public static CronwatchException store(Throwable cause) {
    if (cause instanceof CronwatchException c) {
      return c;
    }
    String message = cause.getMessage();
    return new CronwatchException(
        Kind.STORE, message == null ? cause.getClass().getName() : message, cause);
  }

  /** What kind of failure it is. */
  public Kind kind() {
    return kind;
  }
}
