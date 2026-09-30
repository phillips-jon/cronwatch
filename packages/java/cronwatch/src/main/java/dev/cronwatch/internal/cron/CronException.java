package dev.cronwatch.internal.cron;

/** What croner throws for an expression it will not read or walk: its message, word for word. */
public final class CronException extends IllegalArgumentException {
  private static final long serialVersionUID = 1L;

  CronException(String message) {
    super(message);
  }
}
