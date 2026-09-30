package dev.cronwatch;

import java.util.Objects;
import java.util.function.Predicate;
import org.jspecify.annotations.Nullable;

/**
 * Options for one run: what started it, its id, whether its thread is interrupted at the job's
 * timeout, and whether it may be given back rather than judged. Immutable; each method returns a
 * new value.
 */
public final class RunOptions {
  private static final RunOptions DEFAULT = new RunOptions("run", false, null, null, false);

  final String trigger;
  final boolean interruptAtTimeout;
  final @Nullable String id;
  final @Nullable Predicate<? super Throwable> discardWhen;
  final boolean mayTakeBack;

  private RunOptions(
      String trigger,
      boolean interruptAtTimeout,
      @Nullable String id,
      @Nullable Predicate<? super Throwable> discardWhen,
      boolean mayTakeBack) {
    this.trigger = trigger;
    this.interruptAtTimeout = interruptAtTimeout;
    this.id = id;
    this.discardWhen = discardWhen;
    this.mayTakeBack = mayTakeBack;
  }

  /** No options: the trigger is {@code run}, a new id, and nothing is interrupted. */
  public static RunOptions defaults() {
    return DEFAULT;
  }

  /** Names what started the run ({@code run} by default). */
  public static RunOptions trigger(String trigger) {
    return DEFAULT.withTrigger(trigger);
  }

  /** {@link #interruptAtTimeout()} on the default options. */
  public static RunOptions interruptingAtTimeout() {
    return DEFAULT.interruptAtTimeout();
  }

  /** {@link #withDiscardWhen(Predicate)} on the default options. */
  public static RunOptions discardWhen(Predicate<? super Throwable> discard) {
    return DEFAULT.withDiscardWhen(discard);
  }

  /** These options with another trigger. */
  public RunOptions withTrigger(String trigger) {
    return new RunOptions(
        Objects.requireNonNull(trigger, "trigger"),
        interruptAtTimeout,
        id,
        discardWhen,
        mayTakeBack);
  }

  /**
   * Also interrupts the running thread at the job's timeout (the only stop Java offers), where by
   * default the run is only marked cancelled ({@link JobContext#cancelled()}). A run that then ends
   * by throwing is recorded as a check would mark it, status {@code timeout} and {@code Still
   * running after 30m; marked as timed out}, so the stuck alert goes out sooner. Opt in, since an
   * interrupt can land in the app's own code in the middle of anything.
   */
  public RunOptions interruptAtTimeout() {
    return new RunOptions(trigger, true, id, discardWhen, mayTakeBack);
  }

  /**
   * These options with the run's own id in place of a new one, such as a scheduler's id for the
   * attempt: 1 to 200 characters, not starting with {@code pgcron:} (the pg_cron source's). An id
   * already stored is reported and the run goes unrecorded, as a start whose store failed does.
   */
  public RunOptions withId(String id) {
    return new RunOptions(
        trigger, interruptAtTimeout, Objects.requireNonNull(id, "id"), discardWhen, mayTakeBack);
  }

  /**
   * Takes a run back rather than judging it when the function throws something {@code discard}
   * answers true for: an attempt a scheduler gives back without failing. The running row is deleted
   * (the store's {@code deleteRunIf}), nothing is judged or alerted, the job's state is left as it
   * was (missed and stuck are closed only once the run is known not to be given back), and the
   * throwable is still thrown. A row a check already marked stuck is left as it is, a store without
   * {@code deleteRunIf} records the run as it ended, and a predicate that throws is reported
   * ({@code discarding <job>}) and the run recorded.
   */
  public RunOptions withDiscardWhen(Predicate<? super Throwable> discard) {
    return new RunOptions(
        trigger, interruptAtTimeout, id, Objects.requireNonNull(discard, "discard"), true);
  }

  /**
   * For a run opened with {@link Job#open(RunOptions)} that its integration may give back ({@link
   * ObservedRun#takeBack()}): missed and stuck are closed only once it is closed, so a run given
   * back leaves the job's state as it was. {@link #withDiscardWhen} implies it.
   */
  public RunOptions mayTakeBack() {
    return new RunOptions(trigger, interruptAtTimeout, id, discardWhen, true);
  }

  @Override
  public String toString() {
    return "RunOptions[trigger="
        + trigger
        + ", interruptAtTimeout="
        + interruptAtTimeout
        + (id == null ? "" : ", id=" + id)
        + (discardWhen == null ? "" : ", discardWhen")
        + (mayTakeBack ? ", mayTakeBack" : "")
        + "]";
  }
}
