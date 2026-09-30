package dev.cronwatch;

import dev.cronwatch.alerts.Transport;
import java.util.Objects;
import java.util.function.Consumer;

/** What the client hands a channel with each alert. */
public final class ChannelContext {
  private final Consumer<Throwable> report;
  private final Transport transport;

  /**
   * A context that reports problems to {@code report}, for sending outside a client (a test). A
   * channel given no transport of its own sends through a {@code JdkTransport} made on first use.
   */
  public ChannelContext(Consumer<Throwable> report) {
    this(report, new LazyTransport());
  }

  /** A context that reports problems to {@code report} and sends through {@code transport}. */
  public ChannelContext(Consumer<Throwable> report, Transport transport) {
    this.report = Objects.requireNonNull(report, "report");
    this.transport = Objects.requireNonNull(transport, "transport");
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

  /**
   * The client's transport, which a channel sends through unless its options name one of its own:
   * the one given to {@code Cronwatch.builder().transport(...)}, else a {@code JdkTransport} the
   * client makes on its first send and closes with itself.
   */
  public Transport transport() {
    return transport;
  }

  @Override
  public String toString() {
    return "ChannelContext";
  }
}
