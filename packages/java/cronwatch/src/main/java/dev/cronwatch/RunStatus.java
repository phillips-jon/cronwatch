package dev.cronwatch;

import java.util.Objects;
import org.jspecify.annotations.Nullable;

/**
 * Where a run stands: the SDK's string, with constants for the values it knows. A value another
 * writer stored that this release does not know is held as it is and written back unchanged, so
 * this is a small class rather than an enum; compare with {@link #equals}, or {@code switch} over
 * {@link #value()}.
 */
public final class RunStatus {
  /** Started and not finished. */
  public static final RunStatus RUNNING = new RunStatus("running");

  /** Finished successfully. */
  public static final RunStatus OK = new RunStatus("ok");

  /** Finished with an error, an HTTP answer of 400 or more, or an unmet expect rule. */
  public static final RunStatus FAILED = new RunStatus("failed");

  /** Still running past the job's timeout, marked by a check. */
  public static final RunStatus TIMEOUT = new RunStatus("timeout");

  private final String value;

  private RunStatus(String value) {
    this.value = value;
  }

  /** The status the SDK's text names: one of the constants, or a value of another writer's. */
  public static RunStatus of(String value) {
    return switch (value) {
      case "running" -> RUNNING;
      case "ok" -> OK;
      case "failed" -> FAILED;
      case "timeout" -> TIMEOUT;
      default -> new RunStatus(Objects.requireNonNull(value, "value"));
    };
  }

  /** The value as the SDK writes it. */
  public String value() {
    return value;
  }

  @Override
  public String toString() {
    return value;
  }

  @Override
  public boolean equals(@Nullable Object o) {
    return o instanceof RunStatus s && s.value.equals(value);
  }

  @Override
  public int hashCode() {
    return value.hashCode();
  }
}
