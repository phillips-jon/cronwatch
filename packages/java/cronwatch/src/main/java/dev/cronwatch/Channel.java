package dev.cronwatch;

import java.util.Objects;

/**
 * Where alerts go. {@link Console} is the default; the fifteen channels of the SDK come in a later
 * release, and {@link #of} makes one of a function.
 *
 * <p>Each send runs on a virtual thread of the client's and is waited on for 15 seconds; past its
 * time it is interrupted and counted as failed. A channel that blocks in code that ignores
 * interrupts keeps its virtual thread until it returns, harmlessly.
 */
public interface Channel {
  /** Names the channel in errors ({@code alert channel <name>}). */
  String name();

  /**
   * Sends the alert. Returns once it went out (to at least one recipient); throws when it went
   * nowhere, which the client reports and counts as this channel's failure only.
   *
   * @throws Exception when the alert went nowhere
   */
  void send(Alert alert, ChannelContext context) throws Exception;

  /** A function that sends an alert, for {@link #of}. */
  @FunctionalInterface
  interface Send {
    /**
     * Sends the alert.
     *
     * @throws Exception when it went nowhere
     */
    void send(Alert alert, ChannelContext context) throws Exception;
  }

  /** A function as a channel (the SDK's {@code custom()}). */
  static Channel of(String name, Send send) {
    Objects.requireNonNull(name, "name");
    Objects.requireNonNull(send, "send");
    return new Channel() {
      @Override
      public String name() {
        return name;
      }

      @Override
      public void send(Alert alert, ChannelContext context) throws Exception {
        send.send(alert, context);
      }

      @Override
      public String toString() {
        return "Channel[" + name + "]";
      }
    };
  }
}
