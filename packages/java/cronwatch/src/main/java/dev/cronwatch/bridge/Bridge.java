package dev.cronwatch.bridge;

import dev.cronwatch.Cronwatch;
import dev.cronwatch.CronwatchException;
import dev.cronwatch.Definition;
import dev.cronwatch.JobOptions;
import dev.cronwatch.internal.core.Friends;
import dev.cronwatch.internal.js.Js;
import dev.cronwatch.json.JsObject;
import dev.cronwatch.json.Json;
import java.nio.file.Path;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
import java.time.Duration;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.concurrent.CompletableFuture;
import java.util.concurrent.ExecutionException;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.TimeoutException;
import java.util.regex.Pattern;
import org.jspecify.annotations.Nullable;

/**
 * What the scheduler integrations share ({@code @Scheduled} in the Spring Boot starter, {@code
 * cronwatch-quartz}), carried over from the Go, Rust and Elixir ports' bridge. An app does not need
 * it; a scheduler integration of the app's own can.
 *
 * <ul>
 *   <li>{@link Watch} declares a scheduler's entries as jobs, one per name, tagged with the
 *       integration and the app, and declares a job whose entry is gone again without its schedule,
 *       so it is never reported missed.
 *   <li>{@link #checkFires} checks a schedule taken from a scheduler against the scheduler's own
 *       fire times.
 * </ul>
 *
 * <p>Which jobs are this app's is told by two tags, the integration's ({@code quartz}) and the
 * app's under it ({@code quartz:<app>}, see {@link #appTag}), so two apps sharing one store never
 * declare each other's jobs without a schedule. That is the PHP port's rule for Laravel and
 * Symfony, as the Go, Rust and Elixir ports have it.
 */
public final class Bridge {
  private static final Pattern NAME = Pattern.compile("[A-Za-z0-9][A-Za-z0-9._:-]{0,119}");

  /** The options a job keeps when it is declared again without its schedule. */
  private static final List<String> KEPT =
      List.of("tags", "grace", "timeout", "maxDuration", "budget", "failuresBeforeAlert");

  private Bridge() {}

  /**
   * The app's name for its tag: {@code $CRONWATCH_APP_ID} when set, else {@code fallback} when it
   * is not empty (the starter gives {@code spring.application.name}), else the simple name of the
   * main class (or the jar's name without {@code .jar}). Two apps that share a store and would get
   * the same name need {@code CRONWATCH_APP_ID} (or the integration's {@code app} option) to tell
   * them apart; every process of one app needs the same.
   */
  public static String appName(@Nullable String fallback) {
    String id = System.getenv("CRONWATCH_APP_ID");
    if (id != null && !Js.trim(id).isEmpty()) {
      return Js.trim(id);
    }
    if (fallback != null && !Js.trim(fallback).isEmpty()) {
      return Js.trim(fallback);
    }
    return mainName();
  }

  /** {@link #appName(String)} with no fallback. */
  public static String appName() {
    return appName(null);
  }

  /** The main class's simple name, or the jar's name, from the command the JVM was started with. */
  private static String mainName() {
    String command = System.getProperty("sun.java.command", "");
    String first = Js.trim(command).split("\\s+", 2)[0];
    if (first.isEmpty()) {
      return "java";
    }
    if (first.endsWith(".jar")) {
      Path file = Path.of(first).getFileName();
      String name = file == null ? first : file.toString();
      return name.substring(0, name.length() - ".jar".length());
    }
    int dot = first.lastIndexOf('.');
    String simple = first.substring(dot + 1);
    int nested = simple.lastIndexOf('$');
    return nested >= 0 ? simple.substring(nested + 1) : simple;
  }

  /**
   * The tag that names the app under an integration's tag: {@code <tag>:<app>}, the app's name
   * lowercased, with anything but letters, digits, {@code .}, {@code _} and {@code -} made {@code
   * -}. A name that is empty once cleaned, or longer than 48 characters, is cut and given 8 hex
   * characters of its MD5, so two names never share a tag. The PHP port's {@code appTag()},
   * character for character.
   */
  public static String appTag(String tag, String app) {
    String trimmed = trimPhp(app);
    StringBuilder slug = new StringBuilder();
    boolean run = false;
    for (int i = 0; i < trimmed.length(); i++) {
      char c = trimmed.charAt(i);
      // ASCII letters only, as PHP 8's strtolower, so the Kelvin sign is not a "k".
      if (c >= 'A' && c <= 'Z') {
        c = (char) (c + ('a' - 'A'));
      }
      if ((c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '.' || c == '_' || c == '-') {
        slug.append(c);
        run = false;
      } else if (!run) {
        slug.append('-');
        run = true;
      }
    }
    String s = strip(slug.toString(), '-');
    if (s.isEmpty() || s.length() > 48) {
      String cut = s.substring(0, Math.min(39, s.length())) + "-";
      while (cut.startsWith("-")) {
        cut = cut.substring(1);
      }
      s = cut + md5(app).substring(0, 8);
    }
    return tag + ":" + s;
  }

  /** PHP's {@code trim()}: spaces, tabs, newlines, returns, NULs and vertical tabs. */
  private static String trimPhp(String s) {
    int start = 0;
    int end = s.length();
    while (start < end && " \t\n\r\0\u000b".indexOf(s.charAt(start)) >= 0) {
      start++;
    }
    while (end > start && " \t\n\r\0\u000b".indexOf(s.charAt(end - 1)) >= 0) {
      end--;
    }
    return s.substring(start, end);
  }

  private static String strip(String s, char c) {
    int start = 0;
    int end = s.length();
    while (start < end && s.charAt(start) == c) {
      start++;
    }
    while (end > start && s.charAt(end - 1) == c) {
      end--;
    }
    return s.substring(start, end);
  }

  private static String md5(String s) {
    try {
      byte[] sum = MessageDigest.getInstance("MD5").digest(Js.utf8(s));
      StringBuilder out = new StringBuilder();
      for (byte b : sum) {
        out.append(String.format(Locale.ROOT, "%02x", b & 0xff));
      }
      return out.toString();
    } catch (NoSuchAlgorithmException e) {
      // Every JDK has MD5 (it is one of the algorithms every implementation must support).
      throw new IllegalStateException(e);
    }
  }

  /**
   * Whether {@code name} is a CronWatch job name: 1 to 120 letters, digits, {@code .}, {@code _},
   * {@code :} or {@code -}, starting with a letter or digit.
   */
  public static boolean validName(String name) {
    return NAME.matcher(name).matches();
  }

  /**
   * The definition {@code cw.job(name, options)} would declare, without declaring anything, so an
   * integration can refuse a scheduler job whose runs it could not record.
   *
   * @throws CronwatchException for a name or an option the SDK refuses, with its message
   */
  public static Definition definition(Cronwatch cw, String name, JobOptions options) {
    return Friends.client().describe(cw, name, options.copy());
  }

  /**
   * An interval as CronWatch's schedule text, exact to the millisecond: {@code every 1h30m}.
   * Rounded to the nearest millisecond; {@code every 0ms} for none.
   */
  public static String everyText(Duration d) {
    long ms = d.getSeconds() * 1000 + (d.getNano() + 500_000) / 1_000_000;
    StringBuilder out = new StringBuilder();
    String[] names = {"d", "h", "m", "s", "ms"};
    long[] sizes = {86_400_000L, 3_600_000L, 60_000L, 1000L, 1L};
    for (int i = 0; i < names.length; i++) {
      if (ms >= sizes[i]) {
        out.append(ms / sizes[i]).append(names[i]);
        ms %= sizes[i];
      }
    }
    return out.isEmpty() ? "every 0ms" : "every " + out;
  }

  /**
   * The options that declare a job again without its schedule: its description followed by {@code
   * (no longer scheduled)} ({@code A scheduled task} when it had none), its tags, grace, timeout,
   * maxDuration, budget and failuresBeforeAlert, as stored.
   */
  public static JobOptions unscheduled(Definition def) {
    String description = def.description();
    if (description == null || description.isEmpty()) {
      description = "A scheduled task";
    }
    if (!description.endsWith(" (no longer scheduled)")) {
      description += " (no longer scheduled)";
    }
    JobOptions options = JobOptions.builder().description(description);
    for (String key : KEPT) {
      if (def.has(key)) {
        withField(options, def, key);
      }
    }
    return options;
  }

  /**
   * The options that declare a stored definition again, in its order: schedule, timezone, grace,
   * timeout, maxDuration, budget, failuresBeforeAlert, description, tags, and expect ({@code
   * contains} as {@code expect}, a pattern as the same pattern run by the JavaScript engine, and a
   * custom function as one that passes every output, since the function is the other process's).
   * Fields no option gives are left out. For a worker whose job another process scheduled.
   */
  public static JobOptions optionsOf(Definition def) {
    JobOptions options = JobOptions.builder();
    for (String key : def.keys()) {
      switch (key) {
        case "schedule", "timezone", "description" -> {
          if (def.get(key) instanceof String text) {
            switch (key) {
              case "schedule" -> options.schedule(text);
              case "timezone" -> options.timezone(text);
              default -> options.description(text);
            }
          }
        }
        case "expect" -> {
          String expect = def.expect();
          if (expect != null) {
            Friends.client().withStoredExpect(options, expect);
          }
        }
        default -> withField(options, def, key);
      }
    }
    return options;
  }

  /**
   * {@code options} with one of the fields {@link #unscheduled} keeps, as stored: a duration's text
   * as text and a number of milliseconds as a number, a budget in the order its metrics were given.
   */
  private static void withField(JobOptions options, Definition def, String key) {
    Object value = def.get(key);
    switch (key) {
      case "tags" -> options.tags(def.tags());
      case "grace" -> {
        if (value instanceof String text) {
          options.grace(text);
        } else if (value instanceof Number ms) {
          options.grace(ms.doubleValue());
        }
      }
      case "timeout" -> {
        if (value instanceof String text) {
          options.timeout(text);
        } else if (value instanceof Number ms) {
          options.timeout(ms.doubleValue());
        }
      }
      case "maxDuration" -> {
        if (value instanceof String text) {
          options.maxDuration(text);
        } else if (value instanceof Number ms) {
          options.maxDuration(ms.doubleValue());
        }
      }
      case "budget" -> {
        if (value instanceof JsObject budget) {
          for (Map.Entry<String, @Nullable Object> e : budget.entries()) {
            if (e.getValue() instanceof Number ceiling) {
              options.budget(e.getKey(), ceiling.doubleValue());
            }
          }
        }
      }
      case "failuresBeforeAlert" -> {
        if (value instanceof Number n) {
          double d = n.doubleValue();
          if (d >= 0 && d <= Integer.MAX_VALUE && d == Math.floor(d)) {
            options.failuresBeforeAlert((int) d);
          }
        }
      }
      default -> {
        // Not an option an integration carries over.
      }
    }
  }

  /** How many runs a {@link FireTimes} gives after the first when it is asked without an end. */
  public static final int SAMPLE_RUNS = 8;

  /**
   * Refuses a cron CronWatch would not expect runs of when the scheduler makes them, with a message
   * naming {@code where} (the job) and {@code scheduler} (the scheduler's name). {@code runs} are
   * the scheduler's own fire times, from its own code (see {@link FireTimes}). {@code expr} and
   * {@code zone} are the schedule as CronWatch reads it, {@code zone} {@code ""} for the JVM's own.
   * {@code daily} is a cron that names no day or month, which meets every clock change of one kind
   * alike, so one of each is walked. {@code now} is the epoch milliseconds the horizon starts from.
   *
   * <p>Between two runs of the scheduler, CronWatch must not want one of its own, or it would
   * report it missed; away from clock changes every run the scheduler makes must also be one
   * CronWatch expects. The Go port's {@code bridge/check.go}, line for line.
   *
   * @throws ScheduleException when the two differ, or either cannot read the schedule
   */
  public static void checkFires(
      FireTimes runs,
      String expr,
      String zone,
      String where,
      String scheduler,
      boolean daily,
      long now)
      throws ScheduleException {
    Checker.check(runs, expr, zone, where, scheduler, daily, now);
  }

  /** How long a sync an integration starts itself may take before it is given up. */
  public static final Duration SYNC_TIMEOUT = Duration.ofSeconds(30);

  /**
   * Runs {@code sync} (an integration's declarations, {@link Watch#settle} and {@link
   * Watch#unschedule}) on a thread of its own and waits at most {@code limit} for it, so a store
   * that hangs never holds the caller (a scheduler's thread) for good. A throw in it, or running
   * past the limit ({@code the sync took longer than 30 seconds; gave up}), is reported to the
   * client's error handler as {@code where}. Says whether it finished without a throw.
   */
  public static boolean syncWithin(Cronwatch cw, Duration limit, String where, Runnable sync) {
    CompletableFuture<@Nullable Void> done = new CompletableFuture<>();
    Thread.ofVirtual()
        .name("cronwatch-sync")
        .start(
            () -> {
              try {
                sync.run();
                done.complete(null);
              } catch (Throwable t) {
                done.completeExceptionally(t);
              }
            });
    try {
      done.get(limit.toMillis(), TimeUnit.MILLISECONDS);
      return true;
    } catch (TimeoutException e) {
      cw.reportError(
          new CronwatchException(
              CronwatchException.Kind.OTHER,
              "the sync took longer than " + limit.toSeconds() + " seconds; gave up"),
          where);
    } catch (InterruptedException e) {
      Thread.currentThread().interrupt();
    } catch (ExecutionException e) {
      Throwable cause = e.getCause() == null ? e : e.getCause();
      cw.reportError(cause, where);
      if (cause instanceof Error err) {
        throw err;
      }
    }
    return false;
  }

  /** {@code name} as JSON writes it, for messages. */
  static String quote(String name) {
    return Json.quote(name);
  }
}
