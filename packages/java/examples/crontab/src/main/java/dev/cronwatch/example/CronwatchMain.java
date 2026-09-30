package dev.cronwatch.example;

import dev.cronwatch.cli.CronwatchCli;

/** The check's crontab line: {@code java -cp app.jar dev.cronwatch.example.CronwatchMain check}. */
public final class CronwatchMain {
  private CronwatchMain() {}

  /** Runs the command given, with the app's own client. */
  public static void main(String[] args) {
    CronwatchCli.main(Nightly::cronwatch, args);
  }
}
