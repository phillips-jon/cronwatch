package dev.cronwatch.pgcron;

import static org.junit.jupiter.api.Assertions.assertEquals;

import dev.cronwatch.Fixtures;
import dev.cronwatch.Run;
import dev.cronwatch.json.JsObject;
import java.time.Instant;
import org.jspecify.annotations.Nullable;
import org.junit.jupiter.api.Test;

/**
 * Replays {@code conformance/pgcron.json}: the SDK's {@code pgCronSchedule}, {@code pgCronJobName},
 * and {@code pgCronRun} over every case, and its hold.
 */
class PgCronConformanceTest {
  private static @Nullable Long time(JsObject row, String key) {
    return row.get(key) instanceof String s ? Instant.parse(s).toEpochMilli() : null;
  }

  @Test
  void everyCaseOfPgcronJson() {
    JsObject f = Fixtures.load("pgcron");
    Fixtures.Failures failures = new Fixtures.Failures();
    int count = 0;
    for (JsObject c : Fixtures.objects(f, "schedules")) {
      String schedule = Fixtures.string(c, "schedule");
      failures.same(
          "schedule " + schedule, PgCron.schedule(String.valueOf(schedule)), c.get("result"));
      count++;
    }
    for (JsObject c : Fixtures.objects(f, "names")) {
      JsObject j = Fixtures.object(c, "job");
      PgCronJob job =
          new PgCronJob(
              Fixtures.integer(j, "jobid"), Fixtures.string(j, "jobname"), "", "", "", true);
      failures.same("name of " + j.toJson(), PgCron.jobName(job), c.get("name"));
      count++;
    }
    for (JsObject c : Fixtures.objects(f, "runs")) {
      JsObject r = Fixtures.object(c, "row");
      PgCronRow row =
          new PgCronRow(
              Fixtures.integer(r, "runid"),
              Fixtures.integer(r, "jobid"),
              Fixtures.string(r, "status"),
              Fixtures.string(r, "return_message"),
              time(r, "start_time"),
              time(r, "end_time"));
      Long fallback = Fixtures.optInteger(c, "fallbackAt");
      Run run = PgCron.run(row, "db:j", "pgcron:db:", fallback == null ? PgCronTest.T0 : fallback);
      failures.same("run of " + r.toJson(), run == null ? null : run.toValue(), c.get("run"));
      count++;
    }
    failures.same("holdMs", (double) PgCron.HOLD_MS, f.get("holdMs"));
    count++;
    failures.check("pgcron");
    assertEquals(30, count, "every case: schedules 14, names 6, runs 9, and the hold");
  }
}
