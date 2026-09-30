package dev.cronwatch.internal.duration;

import dev.cronwatch.internal.cron.Cron;
import dev.cronwatch.internal.cron.CronException;
import dev.cronwatch.internal.cron.Zones;
import dev.cronwatch.internal.js.Js;
import java.time.ZoneId;
import java.time.ZoneOffset;
import java.util.ArrayList;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.concurrent.ConcurrentHashMap;
import org.jspecify.annotations.Nullable;

/**
 * The SDK's {@code schedule.ts}: schedules ("0 2 * * *", "@hourly", "every 5m") with their fire
 * times, due times, deadlines and what a run covers. Cron fire times come from the port of croner
 * in {@code internal.cron}, so a Java process and a Node, Ruby, Python, PHP, Go, Rust or Elixir
 * process sharing one store agree on every due time. Refusals are {@link IllegalArgumentException}s
 * with the SDK's message.
 */
public final class Schedules {
  private Schedules() {}

  /** How early a run may start and still count for the fire it was meant for. */
  public static final long EARLY_SLACK_MS = 60_000;

  /**
   * The longest interval kept, 2^53 ms: added to any time the SDK meets it stays well inside a
   * {@code long}. A longer "every" is read as this long, which fires no sooner in any run's
   * lifetime.
   */
  static final double MAX_INTERVAL_MS = 9_007_199_254_740_992.0;

  /**
   * A schedule as {@code parseSchedule} returns it: a cron (with the zone it is read in, when one
   * was given) or an interval (with its period in milliseconds; 0 for a cron).
   */
  public record ParsedSchedule(
      Kind kind, String source, @Nullable String timezone, double everyMs) {
    /** Whether this is "every duration" rather than a cron. */
    public boolean isInterval() {
      return kind == Kind.INTERVAL;
    }
  }

  /** What kind of schedule a {@link ParsedSchedule} is. */
  public enum Kind {
    CRON,
    INTERVAL
  }

  /** When the next run is due, and when it is missed. */
  public record Expectation(long dueAt, double deadline) {}

  private static final int CACHE_LIMIT = 10_000;
  private static final Map<String, ParsedSchedule> CACHE = new ConcurrentHashMap<>();

  /** The croner expression behind each cron schedule, kept out of the public record. */
  private static final Map<ParsedSchedule, Cron> CRONS = new ConcurrentHashMap<>();

  /**
   * {@code parseSchedule}: a cron of five or six fields, a nickname, or "every 5m". Each (schedule,
   * timezone) pair is parsed once and kept. Without a timezone (null or "") a cron is read in the
   * JVM's zone, as crontab reads the system's.
   *
   * @throws IllegalArgumentException with the SDK's message
   */
  public static ParsedSchedule parse(String schedule, @Nullable String timezone) {
    String zone = timezone == null ? "" : timezone;
    String key = zone + "|" + schedule;
    ParsedSchedule hit = CACHE.get(key);
    if (hit != null) {
      return hit;
    }
    ParsedSchedule parsed = parseUncached(schedule, zone);
    // A long-running process parses a handful of schedules; the bound only keeps one fed endless
    // distinct schedules from growing without end.
    if (CACHE.size() >= CACHE_LIMIT) {
      CACHE.clear();
      CRONS.clear();
    }
    CACHE.put(key, parsed);
    return parsed;
  }

  private static ParsedSchedule parseUncached(String schedule, String zone) {
    String text = Js.trim(schedule);
    String rest = every(text);
    if (rest != null) {
      double ms = Durations.parse(rest, "schedule interval");
      if (ms < 1000) {
        throw new IllegalArgumentException(
            "schedule \"" + schedule + "\" is shorter than one second");
      }
      return new ParsedSchedule(Kind.INTERVAL, text, null, Math.min(ms, MAX_INTERVAL_MS));
    }
    ZoneId tz = zone.isEmpty() ? ZoneId.systemDefault() : Zones.find(zone);
    Cron cron;
    try {
      cron = Cron.parse(text, tz == null ? ZoneOffset.UTC : tz);
    } catch (CronException e) {
      throw new IllegalArgumentException(
          "schedule \""
              + schedule
              + "\" is not a cron expression or \"every <duration>\": "
              + e.getMessage(),
          e);
    }
    if (tz == null) {
      throw new IllegalArgumentException(
          "CronDate: Failed to convert date to timezone '"
              + zone
              + "'. This may happen with invalid timezone names or dates. Original error: toTZ:"
              + " Invalid timezone '"
              + zone
              + "' or date. Please provide a valid IANA timezone (e.g., 'America/New_York',"
              + " 'Europe/Stockholm'). Original error: Invalid time zone specified: "
              + zone);
    }
    ParsedSchedule parsed = new ParsedSchedule(Kind.CRON, text, zone.isEmpty() ? null : zone, 0);
    CRONS.put(parsed, cron);
    return parsed;
  }

  /** The croner expression behind a cron schedule, read again if it was let go. */
  private static Cron cronOf(ParsedSchedule p) {
    Cron cron = CRONS.get(p);
    if (cron != null) {
      return cron;
    }
    ParsedSchedule again = parseUncached(p.source(), p.timezone() == null ? "" : p.timezone());
    Cron made = CRONS.get(again);
    if (made == null || again.kind() != Kind.CRON) {
      throw new IllegalArgumentException(
          "schedule \"" + p.source() + "\" was not made by parseSchedule");
    }
    return made;
  }

  /**
   * {@code /^every\s+(.+)$/i}: "every" in any ASCII case, whitespace, and the rest, which must hold
   * no line terminator (JavaScript's "." matches none). Null when it does not match.
   */
  private static @Nullable String every(String text) {
    if (text.length() < 5 || !text.substring(0, 5).toLowerCase(Locale.ROOT).equals("every")) {
      return null;
    }
    for (int i = 0; i < 5; i++) {
      if (text.charAt(i) > 0x7f) {
        return null;
      }
    }
    int i = 5;
    while (i < text.length() && Js.isSpace(text.charAt(i))) {
      i++;
    }
    if (i == 5 || i == text.length()) {
      return null;
    }
    String rest = text.substring(i);
    for (int k = 0; k < rest.length(); k++) {
      char c = rest.charAt(k);
      if (c == '\n' || c == '\r' || c == ' ' || c == ' ') {
        return null;
      }
    }
    return rest;
  }

  /**
   * Four hundred Gregorian years: 146,097 days, a whole number of weeks, after which the calendar
   * repeats date for date and weekday for weekday.
   */
  private static final long CYCLE_MS = 146_097L * 86_400_000L;

  /** 0400-01-01T00:00:00Z: croner misreads a year below 100, so an earlier time is asked later. */
  private static final long CRONER_FIRST_MS = -49_544_438_400_000L;

  /** 2800-01-01T00:00:00Z: croner finds no fire past 3000, so a later time is asked earlier. */
  private static final long CRONER_LAST_MS = 26_192_246_400_000L;

  /**
   * {@code runsAfter}: the next {@code n} fires of a cron strictly after {@code from}, which lies
   * within the years 1 to 9999, dropping any after 9999. A time croner cannot answer for is moved
   * by whole 400-year cycles into the years it can, and its fires moved back: a time before 400
   * goes forward, into the same local mean time every zone kept then, and one from 2800 goes back,
   * to where the zone's present rules already hold.
   */
  private static List<Long> runsAfter(Cron cron, int n, long from) {
    long shift = 0;
    if (from < CRONER_FIRST_MS) {
      shift = Math.ceilDiv(CRONER_FIRST_MS - from, CYCLE_MS) * CYCLE_MS;
    } else if (from >= CRONER_LAST_MS) {
      shift = -((from - CRONER_LAST_MS) / CYCLE_MS + 1) * CYCLE_MS;
    }
    List<Long> out = new ArrayList<>(n);
    for (long t : cron.nextRuns(n, from + shift)) {
      long back = t - shift;
      if (back > Js.LAST_DATE_MS) {
        break;
      }
      out.add(back);
    }
    return out;
  }

  /**
   * {@code countFrom}: a stored time as a cron's fires are counted from it. A start read from a
   * foreign or damaged row can be any number: one before the year 1 counts from just before its
   * first millisecond, so the first fire of the year 1 is the next one, and one at or after the
   * last millisecond of 9999 has no fire after it at all (null). No fire is ever after 9999.
   */
  private static @Nullable Long countFrom(long from) {
    if (from >= Js.LAST_DATE_MS) {
      return null;
    }
    return Math.max(from, Js.FIRST_DATE_MS - 1);
  }

  /**
   * The first fire strictly after {@code from}, or null when the cron never fires again. croner
   * answers with times in the past when asked from inside the hour that repeats when clocks go
   * back, so its answers are filtered, and a stretch of nothing but past times is stepped over an
   * hour at a time.
   */
  private static @Nullable Long fireAfter(Cron cron, long from) {
    Long start = countFrom(from);
    if (start == null) {
      return null;
    }
    long probe = start;
    for (int attempt = 0; attempt < 4; attempt++) {
      List<Long> runs = runsAfter(cron, 8, probe);
      if (runs.isEmpty()) {
        return null;
      }
      for (long t : runs) {
        if (t > start) {
          return t;
        }
      }
      probe += 3_600_000L;
    }
    return null;
  }

  /**
   * {@code firesBetween}: every fire of a cron strictly after {@code from} and at or before {@code
   * to}, ascending, or null when there are more than {@code limit}. Fires are asked for in batches,
   * and any that do not move forward are dropped.
   */
  public static @Nullable List<Long> firesBetween(
      ParsedSchedule parsed, long from, long to, int limit) {
    Cron cron = cronOf(parsed);
    List<Long> out = new ArrayList<>();
    Long start = countFrom(from);
    if (start == null) {
      return out;
    }
    long probe = start;
    long last = start;
    for (int guard = 0; guard < 1000; guard++) {
      List<Long> batch = runsAfter(cron, Math.min(limit + 1 - out.size(), 24), probe);
      if (batch.isEmpty()) {
        return out;
      }
      for (long t : batch) {
        if (t <= last) {
          continue;
        }
        if (t > to) {
          return out;
        }
        out.add(t);
        last = t;
        if (out.size() > limit) {
          return null;
        }
      }
      long end = batch.get(batch.size() - 1);
      probe = end > probe ? end : probe + 3_600_000L;
    }
    return out;
  }

  private static long add(long a, double ms) {
    long b = (long) ms;
    long sum = a + b;
    if (((a ^ sum) & (b ^ sum)) < 0) {
      return a < 0 ? Long.MIN_VALUE : Long.MAX_VALUE;
    }
    return sum;
  }

  /**
   * {@code nextFire}: the next time the schedule fires strictly after {@code from}; for an
   * interval, counted from the last run when there is one. Null when a cron never fires again.
   */
  public static @Nullable Long nextFire(
      ParsedSchedule parsed, long from, @Nullable Long lastRunAt) {
    if (parsed.isInterval()) {
      return add(lastRunAt != null ? lastRunAt : from, parsed.everyMs());
    }
    return fireAfter(cronOf(parsed), from);
  }

  /**
   * {@code expectation}: when the schedule next wants a run, given the last one. For a cron that is
   * the first fire the last run does not already cover; with no run yet, the first fire at or after
   * registration. For an interval it is the last run's start (or registration) plus the interval.
   * Null for a cron that never fires again.
   */
  public static @Nullable Expectation expectation(
      ParsedSchedule parsed, @Nullable Long lastRunAt, long registeredAt, double graceMs) {
    Long due;
    if (parsed.isInterval()) {
      due = add(lastRunAt != null ? lastRunAt : registeredAt, parsed.everyMs());
    } else if (lastRunAt == null) {
      due =
          fireAfter(
              cronOf(parsed), registeredAt == Long.MIN_VALUE ? registeredAt : registeredAt - 1);
    } else {
      due = dueAfterRun(parsed, lastRunAt);
    }
    return due == null ? null : new Expectation(due, (double) due + graceMs);
  }

  /**
   * The first fire that a run starting at {@code startedAt} does not cover. A start before the year
   * 1 covers none of them, so the first fire of the year 1 is due; after 9999 there is none.
   */
  private static @Nullable Long dueAfterRun(ParsedSchedule parsed, long startedAt) {
    Cron cron = cronOf(parsed);
    // A fire at or before the start is covered by the run itself.
    Long next = fireAfter(cron, startedAt);
    if (next == null) {
      return null;
    }
    Long following = fireAfter(cron, next);
    boolean covers =
        runCovers(startedAt, next, following) || inSpringForwardGap(cron, startedAt, next);
    return covers ? following : next;
  }

  /**
   * {@code runCovers}: whether a run starting at {@code startedAt} covers the fire at {@code
   * dueAt}. A minute of slack before the tick absorbs schedulers that fire a touch early. When the
   * fire after {@code dueAt} is known, the slack is at most half the gap between the two, so one
   * run of an every-minute cron never covers two fires.
   */
  public static boolean runCovers(long startedAt, long dueAt, @Nullable Long followingAt) {
    long slack =
        followingAt == null
            ? EARLY_SLACK_MS
            : Math.min(EARLY_SLACK_MS, Math.floorDiv(followingAt - dueAt, 2));
    return startedAt >= dueAt - slack;
  }

  /**
   * On the night clocks spring forward, a fire whose local time does not exist (02:30 when 02:00
   * jumps to 03:00) is moved by croner to the same distance past the jump (03:30), while vixie cron
   * runs it at the jump itself (03:00). A run that starts at or after the jump, and before the
   * first fire after it when that fire lies within one gap of it, is taken to cover that fire, so
   * neither scheduler's run is reported as missed.
   */
  private static boolean inSpringForwardGap(Cron cron, long startedAt, long fireAt) {
    final long lookback = 3 * 3_600_000L;
    // Every zone kept its local mean time, with no clock change, in the year 1.
    if (fireAt - lookback < Js.FIRST_DATE_MS) {
      return false;
    }
    long after = utcOffset(fireAt, cron);
    long before = utcOffset(fireAt - lookback, cron);
    long gap = after - before;
    if (gap <= 0) {
      return false;
    }
    // Find the jump: the first minute in the window with the later offset.
    long lo = fireAt - lookback;
    long hi = fireAt;
    while (hi - lo > 60_000) {
      long mid = lo + (hi - lo) / 2;
      if (utcOffset(mid, cron) == after) {
        hi = mid;
      } else {
        lo = mid;
      }
    }
    long jumpAt = Math.floorDiv(hi, 60_000L) * 60_000L;
    if (fireAt - jumpAt >= gap || startedAt < jumpAt - EARLY_SLACK_MS || startedAt >= fireAt) {
      return false;
    }
    // Only the first fire after the jump can be a moved one; a cron that also fires at the jump
    // (every 10 minutes, say) was not moved at all.
    Long first = fireAfter(cron, jumpAt - 1);
    return first != null && first == fireAt;
  }

  /** The milliseconds the zone's wall clock is ahead of UTC at {@code at}. */
  private static long utcOffset(long at, Cron cron) {
    return Zones.offset(Math.floorDiv(at, 1000), cron.rules()) * 1000;
  }

  /**
   * Whether {@code new Intl.DateTimeFormat("en-US", { timeZone })} accepts the name: an IANA zone,
   * matched without regard to case, or a fixed offset such as "+05:30".
   */
  public static boolean isZone(String name) {
    return !name.isEmpty() && Zones.find(name) != null;
  }
}
