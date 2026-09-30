package dev.cronwatch;

import java.util.Objects;
import org.jspecify.annotations.Nullable;

/**
 * What an alert says: a {@link Condition} opening, or {@code recovered}. The SDK's string, with
 * constants for the values it knows; a value another writer stored is held as it is.
 */
public final class AlertType {
  /** Missed opened. */
  public static final AlertType MISSED = new AlertType("missed");

  /** Failed opened. */
  public static final AlertType FAILED = new AlertType("failed");

  /** Stuck opened. */
  public static final AlertType STUCK = new AlertType("stuck");

  /** Slow opened. */
  public static final AlertType SLOW = new AlertType("slow");

  /** Over budget opened. */
  public static final AlertType OVER_BUDGET = new AlertType("over_budget");

  /** Conditions that alerted have closed. */
  public static final AlertType RECOVERED = new AlertType("recovered");

  private final String value;

  private AlertType(String value) {
    this.value = value;
  }

  /** The type the SDK's text names: one of the constants, or a value of another writer's. */
  public static AlertType of(String value) {
    return switch (value) {
      case "missed" -> MISSED;
      case "failed" -> FAILED;
      case "stuck" -> STUCK;
      case "slow" -> SLOW;
      case "over_budget" -> OVER_BUDGET;
      case "recovered" -> RECOVERED;
      default -> new AlertType(Objects.requireNonNull(value, "value"));
    };
  }

  /** The alert a condition opening sends. */
  public static AlertType of(Condition condition) {
    return of(condition.value());
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
    return o instanceof AlertType t && t.value.equals(value);
  }

  @Override
  public int hashCode() {
    return value.hashCode();
  }
}
