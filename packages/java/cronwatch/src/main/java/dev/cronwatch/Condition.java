package dev.cronwatch;

import java.util.List;
import java.util.Objects;
import org.jspecify.annotations.Nullable;

/**
 * Something wrong with a job that opens once, alerts, and closes with a recovery: the SDK's string,
 * with constants for the values it knows, in the SDK's order ({@link #ALL}). A value another writer
 * stored that this release does not know is held as it is.
 */
public final class Condition {
  /** The schedule wanted a run and none started within the grace. */
  public static final Condition MISSED = new Condition("missed");

  /** Runs failed, as many in a row as the job's {@code failuresBeforeAlert}. */
  public static final Condition FAILED = new Condition("failed");

  /** A run went on past the job's timeout. */
  public static final Condition STUCK = new Condition("stuck");

  /** A successful run took longer than the job's limit or baseline. */
  public static final Condition SLOW = new Condition("slow");

  /** A successful run reported a metric over its budget or baseline. */
  public static final Condition OVER_BUDGET = new Condition("over_budget");

  /** A successful run reported a metric under its floor, or 0 after runs that reported more. */
  public static final Condition UNDER_FLOOR = new Condition("under_floor");

  /** Every condition the SDK knows, in its order. */
  public static final List<Condition> ALL =
      List.of(MISSED, FAILED, STUCK, SLOW, OVER_BUDGET, UNDER_FLOOR);

  private final String value;

  private Condition(String value) {
    this.value = value;
  }

  /** The condition the SDK's text names: one of the constants, or a value of another writer's. */
  public static Condition of(String value) {
    return switch (value) {
      case "missed" -> MISSED;
      case "failed" -> FAILED;
      case "stuck" -> STUCK;
      case "slow" -> SLOW;
      case "over_budget" -> OVER_BUDGET;
      case "under_floor" -> UNDER_FLOOR;
      default -> new Condition(Objects.requireNonNull(value, "value"));
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
    return o instanceof Condition c && c.value.equals(value);
  }

  @Override
  public int hashCode() {
    return value.hashCode();
  }
}
