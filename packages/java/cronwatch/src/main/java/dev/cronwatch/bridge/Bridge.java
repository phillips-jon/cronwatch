package dev.cronwatch.bridge;

import dev.cronwatch.Cronwatch;
import dev.cronwatch.Definition;
import dev.cronwatch.JobOptions;
import java.time.Duration;
import org.jspecify.annotations.Nullable;

/**
 * {@link SchedulerBridge} under its name before 0.11: every method and constant is the same one.
 * Like the rest of the package, it is outside the 1.x promise.
 *
 * @deprecated use {@link SchedulerBridge}, the name the .NET port shares; removed in 2.0
 */
@Deprecated(since = "0.11", forRemoval = true)
public final class Bridge {
  private Bridge() {}

  /** {@link SchedulerBridge#SAMPLE_RUNS}. */
  public static final int SAMPLE_RUNS = SchedulerBridge.SAMPLE_RUNS;

  /** {@link SchedulerBridge#SYNC_TIMEOUT}. */
  public static final Duration SYNC_TIMEOUT = SchedulerBridge.SYNC_TIMEOUT;

  /** {@link SchedulerBridge#appName(String)}. */
  public static String appName(@Nullable String fallback) {
    return SchedulerBridge.appName(fallback);
  }

  /** {@link SchedulerBridge#appName()}. */
  public static String appName() {
    return SchedulerBridge.appName();
  }

  /** {@link SchedulerBridge#appTag}. */
  public static String appTag(String tag, String app) {
    return SchedulerBridge.appTag(tag, app);
  }

  /** {@link SchedulerBridge#validName}. */
  public static boolean validName(String name) {
    return SchedulerBridge.validName(name);
  }

  /** {@link SchedulerBridge#definition}. */
  public static Definition definition(Cronwatch cw, String name, JobOptions options) {
    return SchedulerBridge.definition(cw, name, options);
  }

  /** {@link SchedulerBridge#everyText}. */
  public static String everyText(Duration d) {
    return SchedulerBridge.everyText(d);
  }

  /** {@link SchedulerBridge#unscheduled}. */
  public static JobOptions unscheduled(Definition def) {
    return SchedulerBridge.unscheduled(def);
  }

  /** {@link SchedulerBridge#optionsOf}. */
  public static JobOptions optionsOf(Definition def) {
    return SchedulerBridge.optionsOf(def);
  }

  /**
   * {@link SchedulerBridge#checkFires}.
   *
   * @throws ScheduleException as that does
   */
  public static void checkFires(
      FireTimes runs,
      String expr,
      String zone,
      String where,
      String scheduler,
      boolean daily,
      long now)
      throws ScheduleException {
    SchedulerBridge.checkFires(runs, expr, zone, where, scheduler, daily, now);
  }

  /** {@link SchedulerBridge#syncWithin}. */
  public static boolean syncWithin(Cronwatch cw, Duration limit, String where, Runnable sync) {
    return SchedulerBridge.syncWithin(cw, limit, where, sync);
  }
}
