package dev.cronwatch;

import java.io.PrintStream;

/**
 * The default channel: it writes each alert as the SDK's console channel does, a recovery to {@code
 * System.out} (the SDK's {@code console.info}) and anything else to {@code System.err} ({@code
 * console.error}), since a crontab's mail and a container's log collector read those streams.
 */
public final class Console implements Channel {
  /** The console channel. */
  public Console() {}

  @Override
  public String name() {
    return "console";
  }

  @Override
  public void send(Alert alert, ChannelContext context) {
    StringBuilder line = new StringBuilder("[cronwatch] ").append(alert.title());
    line.append('\n').append(alert.message());
    String triage = alert.triage();
    if (triage != null && !triage.isEmpty()) {
      line.append("\nTriage: ").append(triage);
    }
    PrintStream out = alert.type().equals(AlertType.RECOVERED) ? System.out : System.err;
    out.println(line);
  }

  @Override
  public String toString() {
    return "Console";
  }
}
