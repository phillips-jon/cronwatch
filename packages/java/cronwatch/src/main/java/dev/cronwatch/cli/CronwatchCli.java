package dev.cronwatch.cli;

import dev.cronwatch.CheckResult;
import dev.cronwatch.Cronwatch;
import java.io.PrintStream;
import java.util.Objects;
import java.util.function.Supplier;

/**
 * A check from a crontab line: the second of the two lines a plain crontab runs, beside the job
 * itself. The check needs the same store and channels as the job, which only the app knows, so this
 * is called from a {@code main} of the app's own with the app's factory for its client:
 *
 * <pre>{@code
 * public final class CronwatchMain {
 *   public static void main(String[] args) {
 *     CronwatchCli.main(MyApp::cronwatch, args);
 *   }
 * }
 * }</pre>
 *
 * <p>and the crontab line is {@code java -cp app.jar com.example.CronwatchMain check}. {@code
 * check} makes the client, runs one check, prints {@code cronwatch: checked 3 jobs, sent 1 alert}
 * (or the failure, to standard error), and closes the client.
 */
public final class CronwatchCli {
  private static final String USAGE =
      "usage: cronwatch check\n\n  check    run one check: missed and stuck runs, retries, pruning\n";

  private CronwatchCli() {}

  /**
   * Runs the command in {@code args} and, when it fails, ends the JVM with its status (1 for a
   * failed check, 2 for a command it does not know), so cron mails the failure. For a {@code main}
   * of the app's own, in a JVM of its own: code already running in an app calls {@link #run}, which
   * never ends the JVM.
   */
  public static void main(Supplier<Cronwatch> factory, String[] args) {
    int status = run(factory, args, System.out, System.err);
    if (status != 0) {
      System.exit(status);
    }
  }

  /**
   * Runs the command in {@code args} and answers its exit status (0, 1 for a failed check, 2 for a
   * command it does not know) without ending the JVM, printing to {@code out} and {@code err}.
   * {@code factory} is called for a client, which is closed at the end.
   */
  public static int run(
      Supplier<Cronwatch> factory, String[] args, PrintStream out, PrintStream err) {
    Objects.requireNonNull(factory, "factory");
    if (args.length == 1 && (args[0].equals("help") || args[0].equals("--help"))) {
      out.print(USAGE);
      return 0;
    }
    if (args.length != 1 || !args[0].equals("check")) {
      err.print(
          (args.length == 0
                  ? "cronwatch: no command given\n"
                  : "cronwatch: unknown command " + String.join(" ", args) + "\n")
              + USAGE);
      return 2;
    }
    Cronwatch cw;
    try {
      cw = Objects.requireNonNull(factory.get(), "the factory answered null");
    } catch (RuntimeException e) {
      err.println("cronwatch: the client could not be made: " + describe(e));
      return 1;
    }
    try (cw) {
      CheckResult result = cw.check();
      int jobs = result.jobs().size();
      int alerts = result.alerts().size();
      out.println(
          "cronwatch: checked "
              + jobs
              + " job"
              + plural(jobs)
              + ", sent "
              + alerts
              + " alert"
              + plural(alerts));
      return 0;
    } catch (RuntimeException e) {
      err.println("cronwatch: the check failed: " + describe(e));
      return 1;
    }
  }

  private static String plural(int n) {
    return n == 1 ? "" : "s";
  }

  private static String describe(Throwable e) {
    String message = e.getMessage();
    return message == null || message.isEmpty() ? e.getClass().getSimpleName() : message;
  }
}
