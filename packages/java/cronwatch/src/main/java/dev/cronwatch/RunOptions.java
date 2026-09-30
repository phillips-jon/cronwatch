package dev.cronwatch;

import java.util.Objects;

/**
 * Options for one run: what started it, and whether its thread is interrupted at the job's timeout.
 * Immutable; each method returns a new value.
 */
public final class RunOptions {
  private static final RunOptions DEFAULT = new RunOptions("run", false);

  final String trigger;
  final boolean interruptAtTimeout;

  private RunOptions(String trigger, boolean interruptAtTimeout) {
    this.trigger = trigger;
    this.interruptAtTimeout = interruptAtTimeout;
  }

  /** No options: the trigger is {@code run}, and nothing is interrupted. */
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

  /** These options with another trigger. */
  public RunOptions withTrigger(String trigger) {
    return new RunOptions(Objects.requireNonNull(trigger, "trigger"), interruptAtTimeout);
  }

  /**
   * Also interrupts the running thread at the job's timeout (the only stop Java offers), where by
   * default the run is only marked cancelled ({@link JobContext#cancelled()}). A run that then ends
   * by throwing is recorded as a check would mark it, status {@code timeout} and {@code Still
   * running after 30m; marked as timed out}, so the stuck alert goes out sooner. Opt in, since an
   * interrupt can land in the app's own code in the middle of anything.
   */
  public RunOptions interruptAtTimeout() {
    return new RunOptions(trigger, true);
  }

  @Override
  public String toString() {
    return "RunOptions[trigger=" + trigger + ", interruptAtTimeout=" + interruptAtTimeout + "]";
  }
}
