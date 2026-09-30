package dev.cronwatch;

import java.util.Objects;
import org.jspecify.annotations.Nullable;

/** Options for {@link Job#start}. Immutable; each method returns a new value. */
public final class StartOptions {
  private static final StartOptions DEFAULT = new StartOptions("start", null);

  final String trigger;
  final @Nullable String id;

  private StartOptions(String trigger, @Nullable String id) {
    this.trigger = trigger;
    this.id = id;
  }

  /** No options: the trigger is {@code start}, and the run gets a new id. */
  public static StartOptions defaults() {
    return DEFAULT;
  }

  /** {@link #withId} on the default options. */
  public static StartOptions id(String id) {
    return DEFAULT.withId(id);
  }

  /** {@link #withTrigger} on the default options. */
  public static StartOptions trigger(String trigger) {
    return DEFAULT.withTrigger(trigger);
  }

  /** Names what started the run. */
  public StartOptions withTrigger(String trigger) {
    return new StartOptions(Objects.requireNonNull(trigger, "trigger"), id);
  }

  /**
   * The app's own stable id for the run, such as a queue's job id: 1 to 200 characters, not
   * starting with {@code pgcron:} (the pg_cron source's). A start with an id already recorded for
   * this job records nothing and returns a handle on that run instead; an id recorded for another
   * job is refused.
   */
  public StartOptions withId(String id) {
    return new StartOptions(trigger, Objects.requireNonNull(id, "id"));
  }

  @Override
  public String toString() {
    return "StartOptions[trigger=" + trigger + (id == null ? "" : ", id=" + id) + "]";
  }
}
