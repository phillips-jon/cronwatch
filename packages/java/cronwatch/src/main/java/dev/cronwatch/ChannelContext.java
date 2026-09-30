package dev.cronwatch;

import java.util.Objects;
import java.util.function.Consumer;

/** What the client hands a channel with each alert. */
public final class ChannelContext {
  private final Consumer<Throwable> report;

  /** A context that reports problems to {@code report}, for sending outside a client (a test). */
  public ChannelContext(Consumer<Throwable> report) {
    this.report = Objects.requireNonNull(report, "report");
  }

  /**
   * Reports a problem that did not stop the alert going out, such as one of several recipients
   * refusing it. It goes to the client's error handler as {@code alert channel <name>}.
   */
  public void reportError(Throwable error) {
    report.accept(error);
  }

  /** {@link #reportError(Throwable)} for a message. */
  public void reportError(String message) {
    report.accept(new CronwatchException(CronwatchException.Kind.OTHER, message));
  }

  @Override
  public String toString() {
    return "ChannelContext";
  }
}
