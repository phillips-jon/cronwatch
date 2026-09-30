package dev.cronwatch.bridge;

/**
 * A scheduler's schedule that cannot be read, or cannot be taken as CronWatch's exactly: the job is
 * watched without a schedule, and the message reported once.
 */
public final class ScheduleException extends Exception {
  private static final long serialVersionUID = 1L;

  private final boolean never;

  /** A refusal with its message. */
  public ScheduleException(String message) {
    this(message, false);
  }

  private ScheduleException(String message, boolean never) {
    super(message, null, false, false);
    this.never = never;
  }

  /** What a {@link FireTimes} answers for a schedule that never fires again. */
  public static ScheduleException neverFires(String why) {
    return new ScheduleException(why, true);
  }

  boolean never() {
    return never;
  }
}
