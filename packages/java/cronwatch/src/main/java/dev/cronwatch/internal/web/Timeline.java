package dev.cronwatch.internal.web;

import static dev.cronwatch.internal.web.Text.count;
import static dev.cronwatch.internal.web.Text.encodeUriComponent;
import static dev.cronwatch.internal.web.Text.escapeHtml;
import static dev.cronwatch.internal.web.Text.escapeName;
import static dev.cronwatch.internal.web.Text.num;
import static dev.cronwatch.internal.web.Text.toFixed;

import dev.cronwatch.Condition;
import dev.cronwatch.Definition;
import dev.cronwatch.JobHealth;
import dev.cronwatch.JobSummary;
import dev.cronwatch.Run;
import dev.cronwatch.RunStatus;
import dev.cronwatch.internal.duration.Durations;
import dev.cronwatch.internal.duration.Schedules;
import dev.cronwatch.internal.duration.Schedules.ParsedSchedule;
import dev.cronwatch.internal.evaluate.Evaluate;
import dev.cronwatch.internal.evaluate.Format;
import dev.cronwatch.internal.js.Js;
import dev.cronwatch.json.JsObject;
import java.util.ArrayList;
import java.util.Comparator;
import java.util.List;
import java.util.Map;
import java.util.TreeSet;
import org.jspecify.annotations.Nullable;

/**
 * The dashboard's timelines ({@code routes/timeline.ts}), markup for markup, carried over from the
 * Rust port's {@code web/timeline.rs}: one lane per job (or per day, on a job's page), drawn on the
 * server as inline SVG so the page needs no script.
 *
 * <p>Every time a job was due is a faint tick, worked out from its schedule with the same functions
 * the checks use, so the lane shows the cadence the job is meant to keep. Every run it recorded is
 * a solid mark on top, as wide as it took and coloured by how it ended. A slot the check has
 * reported missed is a dashed box. The empty part of a lane carries a short note about anything
 * open, and a visually hidden list says the same things in words. Every time is UTC: without script
 * the page cannot know the viewer's zone.
 */
public final class Timeline {
  private Timeline() {}

  private static final long HOUR_MS = 3_600_000L;
  private static final long DAY_MS = 24 * HOUR_MS;

  /** The board's span: the last day, plus a few hours ahead so what is due soon shows. */
  public static final long BOARD_BEHIND_MS = DAY_MS;

  /** How far ahead the board looks. */
  public static final long BOARD_AHEAD_MS = 3 * HOUR_MS;

  /** How many jobs the board's timeline draws. The table below it lists every job. */
  public static final int BOARD_LANES = 30;

  /**
   * Runs read for a lane when the twenty the table reads start inside the span, so a frequent job's
   * lane is not cut short. Older runs than this are shown as not loaded rather than as absent.
   */
  public static final int BOARD_RUNS = 200;

  /** How many days a job's page draws. */
  private static final long WEEK_DAYS = 7;

  /** Width of a lane in SVG units. Lanes stretch to fit, so strokes do not scale. */
  private static final double LANE_WIDTH = 1000;

  /** A lane with more due times than this shows its cadence as a dotted line instead. */
  private static final int MAX_TICKS = 330;

  /** More missed slots than this are drawn as one dashed band. */
  private static final int MAX_BOXES = 8;

  /** The narrowest a missed box is drawn, in SVG units. */
  private static final double MIN_BOX = 10;

  private static final String[] MONTHS = {
    "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"
  };
  private static final String[] WEEKDAYS = {"Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"};

  /** "22:42", in UTC. */
  public static String clock(long t) {
    return Js.isoString(t).substring(11, 16);
  }

  /** "Sat 26 Sep", in UTC. */
  static String dayLabel(long t) {
    long days = Math.floorDiv(t, DAY_MS);
    long[] ymd = Js.civilFromDays(days);
    int weekday = Math.floorMod(days + 4, 7);
    return WEEKDAYS[weekday] + " " + ymd[2] + " " + MONTHS[(int) ymd[1] - 1];
  }

  /**
   * "22:42" on the same UTC day as {@code now}, otherwise "25 Sep 22:42", and "1 Jan 0001 02:00" in
   * another UTC year. A time before the year 1 or after 9999 (a start read from a foreign or
   * damaged row) is "before 1 Jan 0001 00:00" or "after 31 Dec 9999 23:59".
   */
  public static String when(long t, long now) {
    if (t > Js.LAST_DATE_MS) {
      return "after 31 Dec 9999 23:59";
    }
    if (t < Js.FIRST_DATE_MS) {
      return "before 1 Jan 0001 00:00";
    }
    if (Math.floorDiv(t, DAY_MS) == Math.floorDiv(now, DAY_MS)) {
      return clock(t);
    }
    long[] ymd = Js.civilFromDays(Math.floorDiv(t, DAY_MS));
    long[] nowYmd = Js.civilFromDays(Math.floorDiv(now, DAY_MS));
    String other = ymd[0] == nowYmd[0] ? "" : " " + Js.pad(ymd[0], 4);
    return ymd[2] + " " + MONTHS[(int) ymd[1] - 1] + other + " " + clock(t);
  }

  /** The stretch of time a timeline draws, and the moment it was drawn. */
  public record Span(long from, long to, long now) {}

  /** The job's schedule, parsed, or null when it has none or it no longer parses. */
  public static @Nullable ParsedSchedule laneSchedule(JobSummary job) {
    if (!Evaluate.truthy(job.definition().get("schedule"))) {
      return null;
    }
    try {
      return Evaluate.parsedSchedule(job.definition());
    } catch (RuntimeException e) {
      return null;
    }
  }

  private record Due(List<Long> times, boolean dense) {}

  private static long saturatingAdd(long a, long b) {
    long sum = a + b;
    if (((a ^ sum) & (b ^ sum)) < 0) {
      return a < 0 ? Long.MIN_VALUE : Long.MAX_VALUE;
    }
    return sum;
  }

  private static long saturatingMul(long a, long b) {
    long hi = Math.multiplyHigh(a, b);
    long lo = a * b;
    if ((hi == 0 && lo >= 0) || (hi == -1 && lo < 0)) {
      return lo;
    }
    return (a < 0) == (b < 0) ? Long.MAX_VALUE : Long.MIN_VALUE;
  }

  private static long saturatingSub(long a, long b) {
    try {
      return Math.subtractExact(a, b);
    } catch (ArithmeticException e) {
      return a > b ? Long.MAX_VALUE : Long.MIN_VALUE;
    }
  }

  /**
   * When the job was due within {@code from} to {@code to}, ascending, and whether they are too
   * many to draw one by one. A cron's fires come from its schedule. An interval is due one period
   * after each run started, and after the last run once a period for as long as nothing runs; with
   * no run yet, from its next expected time.
   */
  private static Due dueTimes(
      JobSummary job, @Nullable ParsedSchedule parsed, List<Run> runs, long from, long to) {
    if (parsed == null) {
      return new Due(List.of(), false);
    }
    if (parsed.isInterval()) {
      long every = (long) parsed.everyMs();
      if (every <= 0) {
        return new Due(List.of(), false);
      }
      if ((double) (to - from) / (double) every > MAX_TICKS) {
        return new Due(List.of(), true);
      }
      List<Long> starts = new ArrayList<>();
      for (Run r : runs) {
        starts.add(r.startedAt());
      }
      starts.sort(null);
      TreeSet<Long> set = new TreeSet<>();
      for (long start : starts) {
        long t = saturatingAdd(start, every);
        if (t >= from && t <= to) {
          set.add(t);
        }
      }
      Long next =
          starts.isEmpty()
              ? job.nextExpectedAt()
              : Long.valueOf(saturatingAdd(starts.get(starts.size() - 1), every));
      if (next != null) {
        long t = next;
        if (t < from) {
          // Saturating: a foreign row's start can be anywhere.
          long steps = (long) Math.ceil((double) saturatingSub(from, t) / (double) every);
          t = saturatingAdd(t, saturatingMul(steps, every));
        }
        while (t <= to) {
          set.add(t);
          t += every;
        }
      }
      return new Due(new ArrayList<>(set), false);
    }
    List<Long> fires;
    try {
      fires = Schedules.firesBetween(parsed, from - 1, to, MAX_TICKS);
    } catch (RuntimeException e) {
      return new Due(List.of(), false);
    }
    return fires == null ? new Due(List.of(), true) : new Due(fires, false);
  }

  private static double graceOrZero(Definition d) {
    try {
      return Evaluate.graceMs(d);
    } catch (RuntimeException e) {
      return 0;
    }
  }

  /**
   * The slot a missed job was due at, the one the check reported: the first fire its last run does
   * not cover. A job that never ran has no run to count from, so the latest due time whose grace
   * has passed stands in. Null when missed is not open.
   */
  public static @Nullable Long missedAt(
      JobSummary job, @Nullable ParsedSchedule parsed, List<Long> times, long now) {
    if (parsed == null || !job.open().contains(Condition.MISSED)) {
      return null;
    }
    double grace = graceOrZero(job.definition());
    Run last = job.lastRun();
    if (last != null) {
      long started = last.startedAt();
      try {
        Schedules.Expectation e = Schedules.expectation(parsed, started, started, grace);
        return e == null ? null : e.dueAt();
      } catch (RuntimeException e) {
        return null;
      }
    }
    for (int i = times.size() - 1; i >= 0; i--) {
      long t = times.get(i);
      if ((double) t + grace < (double) now) {
        return t;
      }
    }
    return null;
  }

  private static boolean stuck(JobSummary job, Run run, long now) {
    try {
      return Evaluate.isStuck(job.definition(), run, now);
    } catch (RuntimeException e) {
      return false;
    }
  }

  private static String toneOf(Run run, JobSummary job, long now) {
    if (run.status().equals(RunStatus.RUNNING)) {
      return stuck(job, run, now) ? "stuck" : "running";
    }
    if (run.status().equals(RunStatus.FAILED)) {
      return "bad";
    }
    if (run.status().equals(RunStatus.TIMEOUT)) {
      return "timeout";
    }
    Run last = job.lastRun();
    boolean latest = last != null && last.id().equals(run.id());
    if (latest
        && (job.open().contains(Condition.OVER_BUDGET) || job.open().contains(Condition.SLOW))) {
      return "warn";
    }
    return "ok";
  }

  private static String timeoutText(JobSummary job) {
    try {
      return Durations.format(Evaluate.timeoutMs(job.definition()));
    } catch (RuntimeException e) {
      return "configured";
    }
  }

  /** One run, as its tooltip says it. */
  private static String describeRun(Run run, String tone, JobSummary job, long now) {
    String at = when(run.startedAt(), now) + " UTC";
    switch (tone) {
      case "running" -> {
        return "running since "
            + at
            + ", "
            + Durations.format((double) saturatingSub(now, run.startedAt()))
            + " so far";
      }
      case "stuck" -> {
        return "running since " + at + ", past its " + timeoutText(job) + " timeout";
      }
      default -> {}
    }
    String took =
        run.durationMs() == null ? "" : ", took " + Durations.format((double) run.durationMs());
    String extra = "";
    if (tone.equals("warn")) {
      extra = job.open().contains(Condition.OVER_BUDGET) ? ", over budget" : ", slow";
    }
    return run.status().value() + " at " + at + took + extra;
  }

  /** The metrics of the job's last run that went over their ceilings. */
  private static List<String> overCeilings(JobSummary job) {
    List<String> out = new ArrayList<>();
    if (!(job.definition().get("budget") instanceof JsObject budget)) {
      return out;
    }
    Run last = job.lastRun();
    for (Map.Entry<String, @Nullable Object> e : budget.entries()) {
      Double v = last == null ? null : last.metrics().get(e.getKey());
      double value = v == null ? Double.NEGATIVE_INFINITY : v;
      if (value > Evaluate.jsNumber(e.getValue())) {
        out.add(e.getKey());
      }
    }
    return out;
  }

  /** What is worth saying about the job in a few words, or {@code ""} when all is well. */
  public static String laneNote(JobSummary job, @Nullable Long missed, long now) {
    Run last = job.lastRun();
    List<Condition> open = job.open();
    Long until = job.silencedUntil();
    if (until != null && until > now) {
      return "silenced until " + when(until, now);
    }
    if (open.contains(Condition.MISSED)) {
      return missed != null ? "due " + when(missed, now) + ", nothing ran" : "overdue, nothing ran";
    }
    if (last != null) {
      if (last.status().equals(RunStatus.RUNNING)) {
        if (stuck(job, last, now)) {
          return "running since "
              + when(last.startedAt(), now)
              + ", past its "
              + timeoutText(job)
              + " timeout";
        }
        return "running since " + when(last.startedAt(), now);
      }
      if (last.status().equals(RunStatus.FAILED)) {
        String text = "failed at " + when(last.startedAt(), now);
        if (job.consecutiveFailures() > 1) {
          text += ", " + num((double) job.consecutiveFailures()) + " in a row";
        }
        return text;
      }
      if (last.status().equals(RunStatus.TIMEOUT)) {
        return "timed out at " + when(last.startedAt(), now);
      }
    }
    if (open.contains(Condition.STUCK)) {
      return "stuck";
    }
    if (open.contains(Condition.OVER_BUDGET) && last != null) {
      String text = "went over budget";
      List<String> over = overCeilings(job);
      if (!over.isEmpty()) {
        text += " on " + String.join(" and ", over);
      }
      return text + " at " + when(last.startedAt(), now);
    }
    if (open.contains(Condition.SLOW) && last != null && last.durationMs() != null) {
      return "slow: took " + Durations.format((double) last.durationMs());
    }
    if (open.contains(Condition.FAILED)) {
      return "failing";
    }
    if (last == null && job.nextExpectedAt() != null) {
      return "no runs yet, first due " + when(job.nextExpectedAt(), now);
    }
    return "";
  }

  /**
   * Everything one lane of the board shows.
   *
   * @param job the job
   * @param runs its runs, any order; only those overlapping the span are drawn
   * @param complete false when older runs exist that were not read; the lane says so before its
   *     oldest run
   */
  public record LaneInput(JobSummary job, List<Run> runs, boolean complete) {}

  private record LaneParts(String svg, String note, String words) {}

  /** {@code toFixed(1)}, the precision every coordinate is written with. */
  private static String fx(double n) {
    return toFixed(n, 1);
  }

  /** The animation delay for a mark at {@code x}, so marks arrive in time order, left to right. */
  private static String delay(double x, double base, double perUnit) {
    return "--d:" + num(Js.round(base + Math.max(x, 0) * perUnit)) + "ms";
  }

  private static long finishedOr(Run r, long now) {
    return r.finishedAt() != null ? r.finishedAt() : now;
  }

  private static double clampLane(double v) {
    return Math.max(0, Math.min(LANE_WIDTH, v));
  }

  /** A lane's x for a time. */
  private static double x(long t, Span sp) {
    return clampLane(((double) (t - sp.from()) / (double) (sp.to() - sp.from())) * LANE_WIDTH);
  }

  /** A lane's x for a time that need not be whole (a slot plus its grace). */
  private static double xf(double t, Span sp) {
    return clampLane(((t - (double) sp.from()) / (double) (sp.to() - sp.from())) * LANE_WIDTH);
  }

  private static LaneParts lane(
      JobSummary job, List<Run> runs, boolean complete, Span sp, boolean nowInLane, String name) {
    long from = sp.from();
    long to = sp.to();
    long now = sp.now();
    ParsedSchedule parsed = laneSchedule(job);
    Due due = dueTimes(job, parsed, runs, from, to);
    List<Long> times = due.times();
    boolean dense = due.dense();
    Long missed = missedAt(job, parsed, times, now);
    double grace = graceOrZero(job.definition());
    List<double[]> busy = new ArrayList<>();

    StringBuilder s =
        new StringBuilder(
            "<svg class=\"marks\" viewBox=\"0 0 1000 24\" preserveAspectRatio=\"none\""
                + " aria-hidden=\"true\" focusable=\"false\">");
    if (nowInLane && now > from && now < to) {
      s.append("<rect class=\"ahead\" x=\"")
          .append(fx(x(now, sp)))
          .append("\" y=\"0\" width=\"")
          .append(fx(LANE_WIDTH - x(now, sp)))
          .append("\" height=\"24\"/>");
    }
    s.append("<line class=\"base\" x1=\"0\" y1=\"12\" x2=\"1000\" y2=\"12\"/>");

    List<Run> inSpan = new ArrayList<>();
    for (Run r : runs) {
      if (r.startedAt() <= to && finishedOr(r, now) >= from) {
        inSpan.add(r);
      }
    }
    inSpan.sort(Comparator.comparingLong(Run::startedAt));
    if (!complete && !runs.isEmpty()) {
      long oldest = Long.MAX_VALUE;
      for (Run r : runs) {
        oldest = Math.min(oldest, r.startedAt());
      }
      if (oldest > from) {
        s.append("<rect class=\"unloaded\" x=\"0\" y=\"4\" width=\"")
            .append(fx(x(oldest, sp)))
            .append("\" height=\"16\"><title>")
            .append(
                escapeHtml(
                    name + ": runs before " + when(oldest, now) + " UTC are not loaded here"))
            .append("</title></rect>");
      }
    }

    if (dense) {
      s.append("<line class=\"cadence\" x1=\"0\" y1=\"12\" x2=\"1000\" y2=\"12\"><title>")
          .append(
              escapeHtml(name + ": due " + scheduleText(job, "") + ", too often to mark each time"))
          .append("</title></line>");
    }
    for (long t : times) {
      double tx = x(t, sp);
      String ahead = t > now ? " ahead" : "";
      s.append("<line class=\"tick")
          .append(ahead)
          .append("\" x1=\"")
          .append(fx(tx))
          .append("\" y1=\"6\" x2=\"")
          .append(fx(tx))
          .append("\" y2=\"18\" style=\"")
          .append(delay(tx, 0, 0.45))
          .append("\"/>");
    }

    // Missed slots: the reported one and every later one whose grace has run out.
    if (missed != null && missed <= to) {
      long m = missed;
      List<Long> slots = new ArrayList<>();
      if (!dense) {
        for (long t : times) {
          if (t >= m && (double) t + grace < (double) now) {
            slots.add(t);
          }
        }
      }
      if (!slots.contains(m) && m >= from) {
        slots.add(0, m);
      }
      String title = name + ": due " + when(m, now) + " UTC, nothing started";
      if (slots.size() > 1) {
        title += " (" + count(slots.size()) + " slots in this span)";
      }
      title = escapeHtml(title);
      if (dense || slots.size() > MAX_BOXES) {
        double x1 = x(Math.max(m, from), sp);
        double x2 = Math.max(x(now, sp), x1 + MIN_BOX);
        missedBox(s, x1, x2 - x1, title);
        busy.add(new double[] {x1, x2});
      } else {
        for (long t : slots) {
          if (t < from) {
            continue;
          }
          double x1 = x(t, sp);
          double width = Math.max(xf((double) t + grace, sp) - x1, MIN_BOX);
          missedBox(s, x1, width, title);
          busy.add(new double[] {x1, x1 + width});
        }
      }
    }

    for (Run run : inSpan) {
      String tone = toneOf(run, job, now);
      // A zero-width rect is not drawn at all; its stroke gives short runs their width.
      double x1 = x(run.startedAt(), sp);
      double x2 = Math.max(x(finishedOr(run, now), sp), x1 + 0.5);
      s.append("<rect class=\"run ")
          .append(tone)
          .append("\" x=\"")
          .append(fx(x1))
          .append("\" y=\"5\" width=\"")
          .append(fx(x2 - x1))
          .append("\" height=\"14\" style=\"")
          .append(delay(x1, 80, 0.75))
          .append("\"><title>")
          .append(escapeHtml(name + ": " + describeRun(run, tone, job, now)))
          .append("</title></rect>");
      busy.add(new double[] {x1, x2});
    }

    if (nowInLane && now > from && now < to) {
      String nx = fx(x(now, sp));
      s.append("<line class=\"nowline\" x1=\"")
          .append(nx)
          .append("\" y1=\"0\" x2=\"")
          .append(nx)
          .append("\" y2=\"24\"/>");
    }
    s.append("</svg>");

    // The note goes wherever the lane is actually empty, so it never sits on the marks it
    // describes; it is cut short with an ellipsis when narrow.
    String text = laneNote(job, missed, now);
    String note = "";
    if (!text.isEmpty()) {
      double nowX = x(now, sp);
      double lo = nowX;
      double hi = nowX;
      if (!busy.isEmpty()) {
        lo = Double.POSITIVE_INFINITY;
        hi = Double.NEGATIVE_INFINITY;
        for (double[] b : busy) {
          lo = Math.min(lo, b[0]);
          hi = Math.max(hi, b[1]);
        }
      }
      boolean right = LANE_WIDTH - hi >= lo;
      double room = right ? LANE_WIDTH - hi : lo;
      if (room > 90) {
        String place;
        String cls;
        if (right) {
          place = "left:" + fx((hi + 14) / 10) + "%";
          cls = "";
        } else {
          place = "right:" + fx(100 - (lo - 14) / 10) + "%";
          cls = " before";
        }
        note =
            "<span class=\"note"
                + cls
                + "\" style=\""
                + place
                + ";max-width:"
                + fx((room - 18) / 10)
                + "%\">"
                + escapeHtml(text)
                + "</span>";
      }
    }
    String words = laneWords(job, inSpan, times, dense, missed, sp, text);
    return new LaneParts(s.toString(), note, words);
  }

  private static void missedBox(StringBuilder s, double x1, double width, String title) {
    s.append("<rect class=\"missed\" x=\"")
        .append(fx(x1))
        .append("\" y=\"5\" width=\"")
        .append(fx(width))
        .append("\" height=\"14\" style=\"")
        .append(delay(x1, 80, 0.75))
        .append("\"><title>")
        .append(title)
        .append("</title></rect>");
  }

  /** {@code `${definition.schedule ?? fallback}`}. */
  private static String scheduleText(JobSummary job, String fallback) {
    Object v = job.definition().get("schedule");
    return v == null ? fallback : Format.jsText(v);
  }

  /** The lane in words, for anyone who cannot see it. */
  private static String laneWords(
      JobSummary job,
      List<Run> runs,
      List<Long> times,
      boolean dense,
      @Nullable Long missed,
      Span sp,
      String note) {
    List<String> parts = new ArrayList<>();
    if (dense) {
      parts.add("due " + Format.jsText(job.definition(), "schedule"));
    } else if (Evaluate.truthy(job.definition().get("schedule"))) {
      long n = 0;
      for (long t : times) {
        if (t <= sp.now()) {
          n++;
        }
      }
      parts.add(
          n == 0
              ? "due no times so far"
              : n == 1 ? "due once so far" : "due " + count(n) + " times so far");
    }
    long ok = 0;
    for (Run r : runs) {
      if (r.status().equals(RunStatus.OK)) {
        ok++;
      }
    }
    String recorded = runs.size() == 1 ? "1 run recorded" : count(runs.size()) + " runs recorded";
    if (!runs.isEmpty()) {
      if (ok == runs.size() && ok == 1) {
        recorded += ", ok";
      } else if (ok == runs.size()) {
        recorded += ", all ok";
      } else if (ok > 0) {
        recorded += ", " + count(ok) + " ok";
      }
    }
    parts.add(recorded);
    List<Run> bad = new ArrayList<>();
    for (Run r : runs) {
      if (r.status().equals(RunStatus.FAILED) || r.status().equals(RunStatus.TIMEOUT)) {
        bad.add(r);
      }
    }
    for (Run r : bad.subList(Math.max(0, bad.size() - 5), bad.size())) {
      parts.add(
          r.status().value()
              + " at "
              + when(r.startedAt(), sp.now())
              + " UTC after "
              + Durations.format(r.durationMs() == null ? 0 : (double) r.durationMs()));
    }
    if (missed != null) {
      parts.add("due at " + when(missed, sp.now()) + " UTC and nothing started");
    }
    if (!note.isEmpty()
        && !note.startsWith("due ")
        && !note.startsWith("failed at")
        && !note.startsWith("timed out")) {
      parts.add(note);
    }
    return String.join("; ", parts);
  }

  /** The grid lines and hour labels every {@code step}, on UTC boundaries. */
  private static String[] hourGrid(Span sp, long step, boolean nowLabel) {
    double nowX = gridX(sp.now(), sp);
    StringBuilder lines = new StringBuilder();
    StringBuilder labels = new StringBuilder();
    long t = -Math.floorDiv(-sp.from(), step) * step;
    while (t <= sp.to()) {
      double gx = gridX(t, sp);
      lines.append("<i class=\"gl\" style=\"left:").append(fx(gx / 10)).append("%\"></i>");
      boolean nearNow = nowLabel && Math.abs(gx - nowX) < 70;
      if (gx >= 25 && gx <= LANE_WIDTH - 25 && !nearNow) {
        List<String> cls = new ArrayList<>();
        if (Js.round((double) t / (double) HOUR_MS) % 6.0 != 0.0) {
          cls.add("minor");
        }
        // On a phone the track is too narrow for a label this close to "now"; CSS hides it there.
        if (nowLabel && Math.abs(gx - nowX) < 170) {
          cls.add("near");
        }
        labels
            .append("<span class=\"")
            .append(String.join(" ", cls))
            .append("\" style=\"left:")
            .append(fx(gx / 10))
            .append("%\">")
            .append(clock(t))
            .append("</span>");
      }
      t += step;
    }
    if (nowLabel && sp.now() >= sp.from() && sp.now() <= sp.to()) {
      labels
          .append("<span class=\"nowlabel\" style=\"left:")
          .append(fx(nowX / 10))
          .append("%\">now ")
          .append(clock(sp.now()))
          .append("</span>");
    }
    return new String[] {lines.toString(), labels.toString()};
  }

  private static double gridX(long t, Span sp) {
    return ((double) (t - sp.from()) / (double) (sp.to() - sp.from())) * LANE_WIDTH;
  }

  private static String key(String inner) {
    return "<svg class=\"key\" viewBox=\"0 0 16 12\" aria-hidden=\"true\" focusable=\"false\">"
        + inner
        + "</svg>";
  }

  private static String boxed(String cls) {
    return key("<rect class=\"" + cls + "\" x=\"2\" y=\"1\" width=\"12\" height=\"10\"/>");
  }

  /** The key under a timeline: a small sample of each mark and what it means. */
  private static String legend() {
    String[][] items = {
      {key("<line class=\"tick\" x1=\"8\" y1=\"1\" x2=\"8\" y2=\"11\"/>"), "due"},
      {boxed("run ok"), "ran"},
      {boxed("run bad"), "failed"},
      {boxed("run timeout"), "timed out"},
      {boxed("run warn"), "over budget or slow"},
      {boxed("run running"), "running"},
      {boxed("missed"), "missed"},
    };
    StringBuilder b = new StringBuilder("<p class=\"legend\" aria-hidden=\"true\">");
    for (String[] item : items) {
      b.append("<span>").append(item[0]).append(item[1]).append("</span>");
    }
    return b.append("</p>").toString();
  }

  private static String stateClass(JobSummary job) {
    JobHealth h = job.health();
    if (h.equals(JobHealth.HEALTHY)) {
      return "ok";
    }
    if (h.equals(JobHealth.LATE)) {
      return "warn";
    }
    if (h.equals(JobHealth.FAILING) || h.equals(JobHealth.STUCK)) {
      return "bad";
    }
    return "muted";
  }

  /**
   * The board's timeline: one lane per job across {@code sp}, with a shared now line and the first
   * {@link #BOARD_LANES} jobs only. {@code total} is how many jobs there are in all, for the note
   * when some are left out.
   */
  public static String dayTimeline(List<LaneInput> lanes, Span sp, String base, int total) {
    String[] grid = hourGrid(sp, 3 * HOUR_MS, true);
    double nowX = ((double) (sp.now() - sp.from()) / (double) (sp.to() - sp.from())) * 100;
    StringBuilder rows = new StringBuilder();
    StringBuilder words = new StringBuilder();
    for (LaneInput input : lanes) {
      JobSummary job = input.job();
      LaneParts parts = lane(job, input.runs(), input.complete(), sp, false, job.name());
      String sched = scheduleText(job, "no schedule");
      rows.append("<li class=\"lane\"><div class=\"who\"><i class=\"sq ")
          .append(stateClass(job))
          .append("\" aria-hidden=\"true\"></i><a class=\"name\" href=\"")
          .append(escapeHtml(base))
          .append("/jobs/")
          .append(encodeUriComponent(job.name()))
          .append("\">")
          .append(escapeName(job.name()))
          .append("</a><span class=\"sched\">")
          .append(escapeHtml(sched))
          .append("</span></div><div class=\"track\">")
          .append(parts.svg())
          .append(parts.note())
          .append("</div></li>");
      words
          .append("<li>")
          .append(escapeHtml(job.name() + " (" + sched + "): " + parts.words() + "."))
          .append("</li>");
    }
    String more = "";
    if (total > lanes.size()) {
      more =
          "<p class=\"more\">Showing the first "
              + count(lanes.size())
              + " of "
              + count(total)
              + " jobs here; the table below lists them all.</p>";
    }
    return "<figure class=\"timeline day\">\n<div class=\"axis\" aria-hidden=\"true\"><span></span><div class=\"hours\">"
        + grid[1]
        + "</div></div>\n<div class=\"field\">\n<div class=\"under\" aria-hidden=\"true\"><span></span><div>"
        + grid[0]
        + "<i class=\"future\" style=\"left:"
        + fx(nowX)
        + "%\"></i></div></div>\n<ol class=\"lanes\">"
        + rows
        + "</ol>\n<div class=\"over\" aria-hidden=\"true\"><span></span><div><i class=\"now\" style=\"left:"
        + fx(nowX)
        + "%\"></i></div></div>\n</div>\n"
        + legend()
        + more
        + "\n<ul class=\"vh\">"
        + words
        + "</ul>\n</figure>";
  }

  /**
   * A job's page: its last seven UTC days, today first, one lane each. {@code complete} is false
   * when the runs read do not reach back over the week.
   */
  public static String weekTimeline(JobSummary job, List<Run> runs, boolean complete, long now) {
    long today = Math.floorDiv(now, DAY_MS) * DAY_MS;
    Long oldest = null;
    for (Run r : runs) {
      oldest = oldest == null ? r.startedAt() : Math.min(oldest, r.startedAt());
    }
    String[] grid = hourGrid(new Span(today, today + DAY_MS, now), 3 * HOUR_MS, false);
    StringBuilder rows = new StringBuilder();
    StringBuilder words = new StringBuilder();
    for (long i = 0; i < WEEK_DAYS; i++) {
      long from = today - i * DAY_MS;
      Span sp = new Span(from, from + DAY_MS, now);
      long n = 0;
      for (Run r : runs) {
        if (r.startedAt() < sp.to() && finishedOr(r, now) >= from) {
          n++;
        }
      }
      boolean known = complete || (oldest != null && oldest <= from);
      String label = i == 0 ? "today" : dayLabel(from);
      LaneParts parts = lane(job, runs, known, sp, i == 0, job.name() + ", " + label);
      String countText = n == 1 ? "1 run" : count(n) + " runs";
      String cls;
      String name;
      String note;
      String said;
      if (i == 0) {
        cls = " today";
        name = "Today, " + dayLabel(from).substring(4);
        note = parts.note();
        said = "Today";
      } else {
        cls = "";
        name = dayLabel(from);
        note = "";
        said = dayLabel(from);
      }
      rows.append("<li class=\"lane")
          .append(cls)
          .append("\"><div class=\"who\"><span class=\"name\">")
          .append(escapeHtml(name))
          .append("</span><span class=\"sched\">")
          .append(escapeHtml(countText))
          .append("</span></div><div class=\"track\">")
          .append(parts.svg())
          .append(note)
          .append("</div></li>");
      words.append("<li>").append(escapeHtml(said + ": " + parts.words() + ".")).append("</li>");
    }
    return "<figure class=\"timeline week\">\n<div class=\"axis\" aria-hidden=\"true\"><span></span><div class=\"hours\">"
        + grid[1]
        + "</div></div>\n<div class=\"field\">\n<div class=\"under\" aria-hidden=\"true\"><span></span><div>"
        + grid[0]
        + "</div></div>\n<ol class=\"lanes\">"
        + rows
        + "</ol>\n</div>\n"
        + legend()
        + "\n<ul class=\"vh\">"
        + words
        + "</ul>\n</figure>";
  }

  /**
   * How many runs a job's page reads so its week is drawn in full: roughly how often the schedule
   * was due over the week, with room to spare, from 50 (what the run list shows) to 500 (the most
   * {@code runs} returns).
   */
  public static int weekRunsLimit(JobSummary job, long now) {
    ParsedSchedule parsed = laneSchedule(job);
    if (parsed == null) {
      return 50;
    }
    long from = Math.floorDiv(now, DAY_MS) * DAY_MS - (WEEK_DAYS - 1) * DAY_MS;
    double width = (double) (now + DAY_MS - from);
    double expected;
    if (parsed.isInterval()) {
      expected = width / (double) (long) parsed.everyMs();
    } else {
      // A cron's fires over one day, times the week: close enough, and cheap.
      Due due = dueTimes(job, parsed, List.of(), now - DAY_MS, now);
      expected =
          due.dense() ? Double.POSITIVE_INFINITY : due.times().size() * width / (double) DAY_MS;
    }
    return (int) Math.max(50, Math.min(500, Math.ceil(expected * 1.2) + 10));
  }
}
