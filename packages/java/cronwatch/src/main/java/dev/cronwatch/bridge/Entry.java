package dev.cronwatch.bridge;

import dev.cronwatch.JobOptions;
import java.util.Objects;
import org.jspecify.annotations.Nullable;

/**
 * One job a scheduler runs, as an integration reads it.
 *
 * @param name the job's name
 * @param label names the entry in messages: {@code Quartz job "reports.nightly"}
 * @param schedule the scheduler's schedule as CronWatch reads it, {@code ""} for none
 * @param timezone the zone the schedule is read in, {@code ""} for the JVM's own
 * @param problem why an entry with a schedule of its own has none here, or a note about the one it
 *     has: reported once; null for none
 * @param defaults the integration's options for every job, applied before the schedule, as the SDK
 *     spreads a client's defaults first
 * @param options the options the app gave this entry, applied after the schedule, so a schedule
 *     among them replaces the scheduler's
 */
public record Entry(
    String name,
    String label,
    String schedule,
    String timezone,
    @Nullable String problem,
    JobOptions defaults,
    JobOptions options) {
  /** Checks that every part but the problem is there. */
  public Entry {
    Objects.requireNonNull(name, "name");
    Objects.requireNonNull(label, "label");
    Objects.requireNonNull(schedule, "schedule");
    Objects.requireNonNull(timezone, "timezone");
    Objects.requireNonNull(defaults, "defaults");
    Objects.requireNonNull(options, "options");
  }

  /** An entry with no problem, no defaults and no options of the app's. */
  public static Entry of(String name, String label, String schedule, String timezone) {
    return new Entry(
        name, label, schedule, timezone, null, JobOptions.builder(), JobOptions.builder());
  }
}
