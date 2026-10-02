package dev.cronwatch.internal.evaluate;

import dev.cronwatch.Alert;
import dev.cronwatch.AlertDetails;
import dev.cronwatch.AlertType;
import dev.cronwatch.BudgetBreach;
import dev.cronwatch.Condition;
import dev.cronwatch.Definition;
import dev.cronwatch.Run;
import dev.cronwatch.internal.duration.Durations;
import dev.cronwatch.internal.evaluate.Evaluate.AlertDraft;
import dev.cronwatch.internal.js.Js;
import dev.cronwatch.json.JsObject;
import java.math.BigDecimal;
import java.math.RoundingMode;
import java.util.ArrayList;
import java.util.List;
import org.jspecify.annotations.Nullable;

/**
 * Alert titles and messages (the SDK's {@code format.ts}), character for character, and the numbers
 * in them as JavaScript's {@code toLocaleString("en-US")} writes them.
 */
public final class Format {
  private Format() {}

  /**
   * {@code formatNumber}: a whole number grouped in thousands ({@code 1,234}), anything else
   * rounded to at most four decimals ({@code 0.0123}), as {@code Intl.NumberFormat("en-US")} writes
   * them. ICU starts from the shortest decimal digits that read back as the number (as {@code
   * String(n)} has them, so 1234.56785 is those digits, not the binary value just below), rounds
   * half away from zero (0.03125 is {@code 0.0313}), and keeps the sign of a negative number that
   * rounds to zero ({@code -0}). {@link java.text.NumberFormat} rounds half even from the binary
   * value, so it is not used.
   */
  public static String formatNumber(double n) {
    if (Double.isNaN(n)) {
      return "NaN";
    }
    if (Double.isInfinite(n)) {
      return n > 0 ? "∞" : "-∞";
    }
    boolean negative = n < 0 || (n == 0 && 1 / n < 0);
    BigDecimal d = n == 0 ? BigDecimal.ZERO : Js.shortest(Math.abs(n));
    BigDecimal rounded = d.setScale(4, RoundingMode.HALF_UP).stripTrailingZeros();
    String plain = rounded.toPlainString();
    int dot = plain.indexOf('.');
    String whole = dot < 0 ? plain : plain.substring(0, dot);
    String frac = dot < 0 ? "" : plain.substring(dot + 1);
    StringBuilder b = new StringBuilder(negative ? "-" : "");
    b.append(group(whole));
    if (!frac.isEmpty()) {
      b.append('.').append(frac);
    }
    return b.toString();
  }

  /** A comma between each three digits, from the right. */
  private static String group(String digits) {
    if (digits.length() <= 3) {
      return digits;
    }
    StringBuilder b = new StringBuilder();
    int head = digits.length() % 3;
    if (head > 0) {
      b.append(digits, 0, head);
    }
    for (int i = head; i < digits.length(); i += 3) {
      if (b.length() > 0) {
        b.append(',');
      }
      b.append(digits, i, i + 3);
    }
    return b.toString();
  }

  /**
   * {@code 2026-01-05 09:30:00 UTC (5m ago)}, or {@code before 0001-01-01 00:00:00 UTC} (with no
   * relative part) for a time outside the years 1 to 9999.
   */
  static String when(double at, long now) {
    if (!(at >= Js.FIRST_DATE_MS && at <= Js.LAST_DATE_MS)) {
      return at > Js.LAST_DATE_MS ? Js.beyondDates(Long.MAX_VALUE) : Js.beyondDates(Long.MIN_VALUE);
    }
    String iso = Js.isoString((long) at).replaceFirst("T", " ");
    return iso.substring(0, 19) + " UTC (" + relative(at, now) + ")";
  }

  /** {@link #when(double, long)} for a whole millisecond. */
  static String when(long at, long now) {
    return when((double) at, now);
  }

  /** {@code formatRelative} for a time that may carry a fraction of a millisecond. */
  private static String relative(double at, long now) {
    double diff = at - now;
    double abs = Math.abs(diff);
    if (abs < 5_000) {
      return "now";
    }
    String text = Durations.format(abs);
    return diff < 0 ? text + " ago" : "in " + text;
  }

  private static String firstLines(String text, int n) {
    String[] lines = text.split("\n", -1);
    return String.join("\n", List.of(lines).subList(0, Math.min(n, lines.length)));
  }

  private static String tail(@Nullable String text, int n) {
    if (text == null || text.isEmpty()) {
      return "";
    }
    String[] lines = Js.trimEnd(text).split("\n", -1);
    return String.join("\n", List.of(lines).subList(Math.max(0, lines.length - n), lines.length));
  }

  /** Whether the text starts {@code Name: }, as {@code /^[A-Za-z_$][\w$]*: /} matches. */
  static boolean namesItself(String text) {
    if (text.isEmpty()
        || !(isAsciiLetter(text.charAt(0)) || text.charAt(0) == '_' || text.charAt(0) == '$')) {
      return false;
    }
    int end = 1;
    while (end < text.length()) {
      char c = text.charAt(end);
      if (!(isAsciiLetter(c) || (c >= '0' && c <= '9') || c == '_' || c == '$')) {
        break;
      }
      end++;
    }
    return text.startsWith(": ", end);
  }

  private static boolean isAsciiLetter(char c) {
    return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z');
  }

  /**
   * {@code Error: x} for a bare message, but not {@code Error: TypeError: x} for one that already
   * names itself.
   */
  static String errorLine(String error) {
    String text = firstLines(error, 4);
    return namesItself(text) ? text : "Error: " + text;
  }

  /**
   * A JSON value as a JavaScript template literal writes it, and {@code undefined} for a field that
   * is absent.
   */
  public static String jsText(Definition def, String key) {
    return def.has(key) ? jsText(def.get(key)) : "undefined";
  }

  /** A JSON value as a JavaScript template literal writes it. */
  public static String jsText(@Nullable Object v) {
    return switch (v) {
      case null -> "null";
      case String s -> s;
      case Boolean b -> b.toString();
      case Number n -> Js.formatNumber(n.doubleValue());
      case List<?> list -> {
        List<String> parts = new ArrayList<>();
        for (Object e : list) {
          parts.add(e == null ? "" : jsText(e));
        }
        yield String.join(",", parts);
      }
      case JsObject o -> "[object Object]";
      default -> String.valueOf(v);
    };
  }

  /** Turns a draft into the title and message every channel shows. */
  public static Alert composeAlert(AlertDraft draft, Definition def, long now) {
    String name = jsText(def, "name");
    Run run = draft.run();
    List<String> lines = new ArrayList<>();
    AlertType type = draft.type();
    AlertDetails details = draft.details();
    String title = "";
    if (type.equals(AlertType.MISSED) && details instanceof AlertDetails.Missed d) {
      lines.add(
          "Due "
              + when(d.dueAt(), now)
              + ", and no run had started by "
              + when(d.deadline(), now)
              + " (grace "
              + Durations.format(d.graceMs())
              + ").");
      Object tz = def.get("timezone");
      String zone = Evaluate.truthy(tz) ? " (" + jsText(tz) + ")" : "";
      lines.add("Schedule: " + jsText(def, "schedule") + zone + ".");
      lines.add(
          "Last run: "
              + (run == null ? "never" : run.status().value() + " " + when(run.startedAt(), now))
              + ".");
      title = name + " missed its scheduled run";
    } else if (type.equals(AlertType.FAILED)) {
      if (details instanceof AlertDetails.Failure f && f.consecutiveFailures() > 1) {
        lines.add(Js.formatLong(f.consecutiveFailures()) + " consecutive failures.");
      }
      if (run != null) {
        String ran =
            run.durationMs() == null ? "" : ", ran " + Durations.format((double) run.durationMs());
        lines.add("Started " + when(run.startedAt(), now) + ran + ".");
        String error = run.error();
        if (error != null && !error.isEmpty()) {
          lines.add(errorLine(error));
        }
        String out = tail(run.output(), 8);
        if (!out.isEmpty()) {
          lines.add("Output (tail):\n" + out);
        }
      }
      title = name + " failed";
    } else if (type.equals(AlertType.STUCK)) {
      if (run != null) {
        double ran =
            run.durationMs() == null
                ? (double) Evaluate.saturatingSub(now, run.startedAt())
                : (double) run.durationMs();
        lines.add(
            "Started "
                + when(run.startedAt(), now)
                + " and never reported finishing. Marked as timed out after "
                + Durations.format(ran)
                + ".");
        String out = tail(run.output(), 8);
        if (!out.isEmpty()) {
          lines.add("Output so far (tail):\n" + out);
        }
      }
      lines.add(
          "If the process was killed mid-run (a serverless timeout, a deploy), this is what that"
              + " looks like.");
      title = name + " is stuck";
    } else if (type.equals(AlertType.SLOW) && details instanceof AlertDetails.Slow s) {
      lines.add(
          "Took "
              + Durations.format((double) s.durationMs())
              + "; the limit is "
              + Durations.format(s.thresholdMs())
              + " ("
              + s.basis()
              + ").");
      if (run != null) {
        lines.add("Started " + when(run.startedAt(), now) + ".");
      }
      title = name + " was slow";
    } else if (type.equals(AlertType.OVER_BUDGET) && details instanceof AlertDetails.OverBudget o) {
      for (BudgetBreach b : o.breaches()) {
        lines.add(
            b.metric()
                + ": "
                + formatNumber(b.value())
                + ", limit "
                + formatNumber(b.limit())
                + " ("
                + b.basis()
                + ").");
      }
      if (run != null) {
        lines.add("Started " + when(run.startedAt(), now) + ".");
      }
      title = name + " went over budget";
    } else if (type.equals(AlertType.UNDER_FLOOR) && details instanceof AlertDetails.UnderFloor u) {
      for (BudgetBreach b : u.breaches()) {
        lines.add(
            b.basis().equals("floor")
                ? b.metric()
                    + ": "
                    + formatNumber(b.value())
                    + ", below the floor of "
                    + formatNumber(b.limit())
                    + "."
                : b.metric() + ": " + formatNumber(b.value()) + " (" + b.basis() + ").");
      }
      if (run != null) {
        lines.add("Started " + when(run.startedAt(), now) + ".");
      }
      title = name + " fell short";
    } else if (type.equals(AlertType.RECOVERED) && details instanceof AlertDetails.Recovered r) {
      if ("unscheduled".equals(r.reason())) {
        String missed = r.since() == null ? "" : "Missed since " + when(r.since(), now) + ". ";
        lines.add(
            missed + "It has no schedule now, so nothing is due; the missed alert is closed.");
        title = name + " is no longer scheduled";
      } else {
        List<String> after = new ArrayList<>();
        for (Condition c : r.after()) {
          after.add(c.value().replaceFirst("_", " "));
        }
        String joined = String.join(", ", after);
        String at = run == null ? "just now" : when(run.startedAt(), now);
        lines.add(
            "A run " + at + " succeeded" + (joined.isEmpty() ? "" : " after: " + joined) + ".");
        if (run != null && run.durationMs() != null) {
          lines.add("Ran " + Durations.format((double) run.durationMs()) + ".");
        }
        title = name + " recovered";
      }
    }
    return new Alert(
        type, run, details, name, def, title, String.join("\n", lines), null, false, now);
  }
}
