package dev.cronwatch.internal.duration;

import static org.junit.jupiter.api.Assertions.assertEquals;

import dev.cronwatch.Fixtures;
import dev.cronwatch.internal.duration.Schedules.Expectation;
import dev.cronwatch.internal.duration.Schedules.ParsedSchedule;
import dev.cronwatch.json.JsObject;
import dev.cronwatch.json.Json;
import java.util.ArrayList;
import java.util.List;
import java.util.Set;
import org.jspecify.annotations.Nullable;
import org.junit.jupiter.api.Test;

/**
 * Replays conformance/schedule.json, the cases scripts/conformance.mjs writes by running the SDK in
 * UTC, comparing every answer as the JSON the SDK writes, byte for byte.
 */
class ScheduleConformanceTest {
  /** The SDK's JSON of a parsed schedule. */
  static JsObject json(ParsedSchedule p) {
    JsObject o =
        new JsObject().set("kind", p.isInterval() ? "interval" : "cron").set("source", p.source());
    if (p.isInterval()) {
      o.set("everyMs", p.everyMs());
    } else if (p.timezone() != null) {
      o.set("timezone", p.timezone());
    }
    return o;
  }

  private static @Nullable String zone(JsObject c) {
    return Fixtures.string(c, "timezone");
  }

  @Test
  void everyCaseMatchesTheSdk() {
    JsObject f = Fixtures.load("schedule");
    Fixtures.Failures failures = new Fixtures.Failures();

    List<JsObject> parse = Fixtures.objects(f, "parse");
    for (JsObject c : parse) {
      JsObject got = new JsObject().set("schedule", c.get("schedule"));
      if (c.has("timezone")) {
        got.set("timezone", c.get("timezone"));
      }
      try {
        got.set("parsed", json(Schedules.parse(Fixtures.string(c, "schedule"), zone(c))));
      } catch (IllegalArgumentException e) {
        got.set("error", e.getMessage());
      }
      failures.same("parse", got, c);
    }

    List<JsObject> fires = Fixtures.objects(f, "fires");
    for (JsObject c : fires) {
      ParsedSchedule p = Schedules.parse(Fixtures.string(c, "schedule"), zone(c));
      List<?> want = Fixtures.list(c, "fires");
      List<@Nullable Long> out = new ArrayList<>();
      long at = Fixtures.integer(c, "from");
      for (int i = 0; i < want.size(); i++) {
        Long next = Schedules.nextFire(p, at, null);
        out.add(next);
        if (next == null) {
          break;
        }
        at = next;
      }
      failures.same("fires of " + c.get("schedule") + " in " + zone(c), out, want);
    }

    List<JsObject> nextFire = Fixtures.objects(f, "nextFire");
    for (JsObject c : nextFire) {
      ParsedSchedule p = Schedules.parse(Fixtures.string(c, "schedule"), null);
      Long got =
          Schedules.nextFire(p, Fixtures.integer(c, "from"), Fixtures.optInteger(c, "lastRunAt"));
      failures.same("nextFire", got, c.get("expected"));
    }

    List<JsObject> expectation = Fixtures.objects(f, "expectation");
    for (JsObject c : expectation) {
      ParsedSchedule p = Schedules.parse(Fixtures.string(c, "schedule"), zone(c));
      Expectation e =
          Schedules.expectation(
              p,
              Fixtures.optInteger(c, "lastRunAt"),
              Fixtures.integer(c, "registeredAt"),
              DurationConformanceTest.number(c.get("graceMs")));
      Object got =
          e == null ? null : new JsObject().set("dueAt", e.dueAt()).set("deadline", e.deadline());
      failures.same(
          "expectation of "
              + c.get("schedule")
              + " in "
              + zone(c)
              + " after "
              + Json.stringify(c.get("lastRunAt")),
          got,
          c.get("expected"));
    }

    List<JsObject> runCovers = Fixtures.objects(f, "runCovers");
    for (JsObject c : runCovers) {
      boolean got =
          Schedules.runCovers(
              Fixtures.integer(c, "startedAt"),
              Fixtures.integer(c, "dueAt"),
              Fixtures.optInteger(c, "followingAt"));
      failures.same("runCovers", got, c.get("expected"));
    }

    List<JsObject> autumn = Fixtures.objects(f, "autumn");
    for (JsObject c : autumn) {
      ParsedSchedule p = Schedules.parse(Fixtures.string(c, "schedule"), zone(c));
      long from = Fixtures.integer(c, "from");
      long step = Fixtures.integer(c, "stepMs");
      List<@Nullable Long> out = new ArrayList<>();
      for (long at = from; at < from + 8 * 3_600_000L; at += step) {
        out.add(Schedules.nextFire(p, at, null));
      }
      failures.same("autumn " + c.get("schedule") + " in " + zone(c), out, c.get("next"));
    }

    failures.check("schedule");
    assertEquals(62, parse.size(), "parse cases");
    assertEquals(64, fires.size(), "fires cases");
    assertEquals(4, nextFire.size(), "nextFire cases");
    assertEquals(572, expectation.size(), "expectation cases");
    assertEquals(13, runCovers.size(), "runCovers cases");
    assertEquals(8, autumn.size(), "autumn cases");
    DurationConformanceTest.known(
        f, Set.of("parse", "fires", "nextFire", "expectation", "runCovers", "autumn"));
  }
}
