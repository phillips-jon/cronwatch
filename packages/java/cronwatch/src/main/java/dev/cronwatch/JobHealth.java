package dev.cronwatch;

import java.util.Objects;
import org.jspecify.annotations.Nullable;

/**
 * How a job looks at a glance: the SDK's string, with constants for the values it knows. Silence
 * wins, then stuck, failing and late.
 */
public final class JobHealth {
  /** Nothing is wrong. */
  public static final JobHealth HEALTHY = new JobHealth("healthy");

  /** Missed is open. */
  public static final JobHealth LATE = new JobHealth("late");

  /** Failed is open, or the last run failed or timed out. */
  public static final JobHealth FAILING = new JobHealth("failing");

  /** Stuck is open, or the last run is running past the timeout. */
  public static final JobHealth STUCK = new JobHealth("stuck");

  /** The job is silenced. */
  public static final JobHealth SILENCED = new JobHealth("silenced");

  /** The job has no runs. */
  public static final JobHealth NEVER_RAN = new JobHealth("never_ran");

  private final String value;

  private JobHealth(String value) {
    this.value = value;
  }

  /** The health the SDK's text names: one of the constants, or a value of another writer's. */
  public static JobHealth of(String value) {
    return switch (value) {
      case "healthy" -> HEALTHY;
      case "late" -> LATE;
      case "failing" -> FAILING;
      case "stuck" -> STUCK;
      case "silenced" -> SILENCED;
      case "never_ran" -> NEVER_RAN;
      default -> new JobHealth(Objects.requireNonNull(value, "value"));
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
    return o instanceof JobHealth h && h.value.equals(value);
  }

  @Override
  public int hashCode() {
    return value.hashCode();
  }
}
