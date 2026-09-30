package dev.cronwatch.bridge;

import dev.cronwatch.internal.cron.Zones;
import dev.cronwatch.internal.duration.Schedules;
import dev.cronwatch.internal.duration.Schedules.ParsedSchedule;
import dev.cronwatch.internal.js.Js;
import java.time.Instant;
import java.time.LocalDateTime;
import java.time.ZoneId;
import java.time.ZoneOffset;
import java.time.zone.ZoneOffsetTransition;
import java.time.zone.ZoneRules;
import java.util.ArrayList;
import java.util.HashSet;
import java.util.List;
import java.util.Locale;
import java.util.Set;
import org.jspecify.annotations.Nullable;

/**
 * The check that a schedule taken from a scheduler (Spring's {@code CronExpression}, Quartz's)
 * makes CronWatch expect runs exactly when the scheduler makes them, as the Go port checks
 * robfig/cron's and the gem Solid Queue's against Fugit: the scheduler's own runs, from its own
 * code, walked beside CronWatch's fires around every clock change in the next few years and from
 * the start of each month of a sample year, so the answer does not depend on when the app starts.
 *
 * <p>Between two runs of the scheduler, CronWatch must not want one of its own, or it would report
 * it missed: a fire CronWatch has and the scheduler does not (a time the scheduler skips when
 * clocks go forward, a run its steps drop that day) is refused unless the run before it covers it
 * (a minute of early slack, or a fire moved past a spring-forward jump). Away from clock changes
 * every run the scheduler makes must also be one CronWatch expects; near one, the scheduler may run
 * a repeated time twice, which CronWatch takes as an early run. The Go port's {@code
 * bridge/check.go} through the Rust port's {@code bridge/check.rs}, line for line.
 */
final class Checker {
  /** How far ahead the daylight saving check looks. */
  private static final long HORIZON_YEARS = 5;

  /**
   * How far either side of each clock change the scheduler's runs are compared with CronWatch's.
   */
  private static final long CHANGE_WINDOW_MS = 2 * 86_400_000L;

  /** Away from clock changes, runs from the start of each month of this year are compared too. */
  private static final long SAMPLE_YEAR = 2026;

  private static final long DAY_MS = 86_400_000L;

  private final FireTimes runs;
  private final ParsedSchedule parsed;
  private final ZoneRules rules;
  private final String zone;
  private final String where;
  private final String scheduler;

  private Checker(
      FireTimes runs,
      ParsedSchedule parsed,
      ZoneRules rules,
      String zone,
      String where,
      String scheduler) {
    this.runs = runs;
    this.parsed = parsed;
    this.rules = rules;
    this.zone = zone;
    this.where = where;
    this.scheduler = scheduler;
  }

  static void check(
      FireTimes runs,
      String expr,
      String zone,
      String where,
      String scheduler,
      boolean daily,
      long now)
      throws ScheduleException {
    ParsedSchedule parsed;
    try {
      parsed = Schedules.parse(expr, zone.isEmpty() ? null : zone);
    } catch (IllegalArgumentException e) {
      throw new ScheduleException(
          where + " is " + Bridge.quote(expr) + ", which CronWatch cannot read: " + e.getMessage());
    }
    ZoneId tz = Zones.find(zone);
    if (tz == null) {
      throw new ScheduleException(
          where + ": timezone " + Bridge.quote(zone) + " is not an IANA timezone");
    }
    Checker checker =
        new Checker(
            runs, parsed, tz.getRules(), zone, where + " is " + Bridge.quote(expr), scheduler);
    try {
      checker.check(daily, now);
    } catch (ScheduleException e) {
      if (e.never()) {
        throw new ScheduleException(checker.where + ", which never fires: " + e.getMessage());
      }
      throw e;
    }
  }

  /** A clock change: when, and the zone's offset in seconds before and after. */
  private record Transition(long at, long before, long after) {}

  /** The zone's clock changes after one instant and at or before another, epoch milliseconds. */
  private List<Transition> transitions(long startMs, long endMs) {
    List<Transition> found = new ArrayList<>();
    Instant start = Instant.ofEpochMilli(startMs);
    long before = rules.getOffset(start).getTotalSeconds();
    ZoneOffsetTransition t = rules.nextTransition(start);
    while (t != null) {
      long at = t.toEpochSecond() * 1000;
      if (at > endMs) {
        break;
      }
      long after = t.getOffsetAfter().getTotalSeconds();
      if (after != before) {
        found.add(new Transition(at, before, after));
      }
      before = after;
      t = rules.nextTransition(t.getInstant());
    }
    return found;
  }

  private static long yearStart(long year) {
    return Js.dateUtc(year, 0, 1, 0, 0, 0, 0);
  }

  private void check(boolean daily, long now) throws ScheduleException {
    long year = LocalDateTime.ofEpochSecond(Math.floorDiv(now, 1000), 0, ZoneOffset.UTC).getYear();
    Set<List<Long>> seen = new HashSet<>();
    for (Transition change : transitions(yearStart(year), yearStart(year + HORIZON_YEARS + 1))) {
      List<Long> kind =
          List.of(
              Math.floorMod(change.at() / 1000 + change.before(), 86_400L),
              change.after() - change.before());
      if (daily && seen.contains(kind)) {
        continue;
      }
      seen.add(kind);
      long start = change.at() - CHANGE_WINDOW_MS;
      long end = start + 2 * CHANGE_WINDOW_MS;
      // Near a change only CronWatch's own fires can be refused, so a stretch where it has none
      // needs no walk.
      Long first = Schedules.nextFire(parsed, start - 1, null);
      if (first == null || first > end) {
        continue;
      }
      compare(runs.between(start, end), false);
    }

    Long comparedUntil = null;
    for (int month = 0; month < 12; month++) {
      long start = Js.dateUtc(SAMPLE_YEAR, month, 1, 0, 0, 0, 0);
      if (comparedUntil != null && start < comparedUntil) {
        continue; // a sparse cron's earlier sample reached past this month
      }
      List<Long> found = runs.between(start, null);
      if (found.isEmpty()) {
        continue;
      }
      long last = found.get(found.size() - 1);
      comparedUntil = last;
      boolean near = !transitions(found.get(0) - DAY_MS, last + DAY_MS).isEmpty();
      compare(found, !near);
    }
  }

  /** CronWatch's fires after {@code start}, up to and including {@code end}. */
  private List<Long> fires(long start, long end) {
    List<Long> out = new ArrayList<>();
    long at = start;
    while (true) {
      Long fire = Schedules.nextFire(parsed, at, null);
      if (fire == null || fire > end) {
        return out;
      }
      out.add(fire);
      at = fire;
    }
  }

  /** The first fire a run starting at {@code at} does not cover, or null. */
  private @Nullable Long dueAfterRun(long at) {
    Schedules.Expectation e = Schedules.expectation(parsed, at, at, 0);
    return e == null ? null : e.dueAt();
  }

  /**
   * Refuses where, after one of the scheduler's runs, CronWatch would want a run before the
   * scheduler's next (or, when strict, where the scheduler's next is not a time CronWatch fires).
   */
  private void compare(List<Long> runs, boolean strict) throws ScheduleException {
    if (runs.size() < 2) {
      return;
    }
    List<Long> fires = fires(runs.get(0), runs.get(runs.size() - 1));
    Set<Long> expected = strict ? new HashSet<>(fires) : Set.of();
    int i = 0;
    for (int k = 0; k + 1 < runs.size(); k++) {
      long at = runs.get(k);
      long following = runs.get(k + 1);
      while (i < fires.size() && fires.get(i) <= at) {
        i++;
      }
      boolean own = i >= fires.size() || fires.get(i) < following;
      boolean unexpected = strict && !expected.contains(following);
      if (!own && !unexpected) {
        continue;
      }
      Long due = dueAfterRun(at);
      if (!unexpected && due != null && due >= following) {
        continue;
      }
      throw mismatch(at, following, due);
    }
  }

  private String zoneName() {
    return zone.isEmpty() ? "the process's zone" : zone;
  }

  private LocalDateTime wall(long ms) {
    Instant at = Instant.ofEpochMilli(ms);
    return LocalDateTime.ofInstant(at, rules.getOffset(at));
  }

  private String stamp(long ms) {
    LocalDateTime w = wall(ms);
    return String.format(
        Locale.ROOT,
        "%04d-%02d-%02d %02d:%02d:%02d",
        w.getYear(),
        w.getMonthValue(),
        w.getDayOfMonth(),
        w.getHour(),
        w.getMinute(),
        w.getSecond());
  }

  private ScheduleException mismatch(long at, long following, @Nullable Long due) {
    Transition skipped = null;
    if (due != null) {
      for (Transition change : transitions(due - DAY_MS, due + 1000)) {
        long gap = change.after() - change.before();
        if (gap > 0 && due < change.at() + gap * 1000) {
          skipped = change;
          break;
        }
      }
    }
    if (skipped == null) {
      String expected = due == null ? "nothing" : stamp(due);
      return new ScheduleException(
          where
              + " in "
              + zoneName()
              + ", but after a run at "
              + stamp(at)
              + " "
              + scheduler
              + " runs it next at "
              + stamp(following)
              + " and CronWatch would expect "
              + expected
              + ", so it cannot be converted exactly; give the job a schedule of its own");
    }
    LocalDateTime old =
        LocalDateTime.ofEpochSecond(
            Math.floorDiv(skipped.at() + skipped.before() * 1000, 1000), 0, ZoneOffset.UTC);
    LocalDateTime moved =
        LocalDateTime.ofEpochSecond(
            Math.floorDiv(skipped.at() + skipped.after() * 1000, 1000), 0, ZoneOffset.UTC);
    return new ScheduleException(
        String.format(
            Locale.ROOT,
            "%s, due at a time that does not exist in %s on %04d-%02d-%02d, when clocks go forward"
                + " from %02d:%02d to %02d:%02d. %s does not run it then and CronWatch would expect"
                + " it at %s, so it would be reported missed. Move the time outside the change,"
                + " give the schedule a zone without daylight saving (such as UTC), or give the job"
                + " a schedule of its own",
            where,
            zoneName(),
            old.getYear(),
            old.getMonthValue(),
            old.getDayOfMonth(),
            old.getHour(),
            old.getMinute(),
            moved.getHour(),
            moved.getMinute(),
            scheduler,
            stamp(due == null ? 0 : due)));
  }
}
