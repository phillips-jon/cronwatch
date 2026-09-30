package dev.cronwatch.internal.duration;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertTrue;
import static org.junit.jupiter.api.Assumptions.assumeTrue;

import dev.cronwatch.Fixtures;
import dev.cronwatch.internal.duration.Schedules.ParsedSchedule;
import dev.cronwatch.internal.js.Js;
import dev.cronwatch.json.JsObject;
import dev.cronwatch.json.Json;
import java.io.IOException;
import java.net.URISyntaxException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.List;
import java.util.Objects;
import java.util.concurrent.TimeUnit;
import org.jspecify.annotations.Nullable;
import org.junit.jupiter.api.Test;

/**
 * The croner port against croner itself: 3,000 generated cron expressions (see {@link CronFuzzer}),
 * in zones with and without daylight saving, from times around the clock changes, answered by the
 * SDK in Node (reading packages/sdk/dist) and by this port, which must agree on every error message
 * and every fire time. Skipped, with the reason, when node or the built SDK is missing.
 */
class CronerParityTest {
  private record Case(String schedule, String timezone, long from, long count) {}

  private static List<Case> cases(long seed, int count) {
    CronFuzzer f = new CronFuzzer(seed);
    // Around the nights clocks change in the zones, and ordinary days.
    long[] starts = {
      Js.dateUtc(2026, 2, 8, 6, 30, 0, 0),
      Js.dateUtc(2026, 10, 1, 5, 10, 0, 0),
      Js.dateUtc(2026, 2, 29, 0, 45, 0, 0),
      Js.dateUtc(2026, 9, 25, 0, 50, 0, 0),
      Js.dateUtc(2026, 9, 3, 15, 20, 0, 0),
      Js.dateUtc(2026, 3, 4, 14, 55, 0, 0),
      Js.dateUtc(2026, 0, 5, 9, 30, 0, 0),
      Js.dateUtc(2027, 1, 27, 23, 59, 59, 0),
      Js.dateUtc(2028, 1, 28, 12, 0, 0, 0),
    };
    List<Case> out = new ArrayList<>();
    for (int i = 0; i < count; i++) {
      long from = f.pick(starts);
      from += f.between(-3, 3) * 3_600_000L;
      from += f.between(0, 3_599) * 1000L;
      from += f.pick(new long[] {0, 0, 500, 999});
      String schedule = f.expression();
      long n = f.between(1, 6);
      String timezone = f.pick(CronFuzzer.ZONES);
      out.add(new Case(schedule, timezone, from, n));
    }
    return out;
  }

  /** This port's answer, as the helper writes the SDK's: {@code {error}} or {@code {fires}}. */
  private static JsObject answer(Case c) {
    ParsedSchedule p;
    try {
      p = Schedules.parse(c.schedule(), c.timezone());
    } catch (IllegalArgumentException e) {
      return new JsObject().set("error", e.getMessage());
    }
    List<@Nullable Long> fires = new ArrayList<>();
    long at = c.from();
    for (long i = 0; i < c.count(); i++) {
      Long next = Schedules.nextFire(p, at, null);
      fires.add(next);
      if (next == null) {
        break;
      }
      at = next;
    }
    return new JsObject().set("fires", fires);
  }

  private static String show(JsObject a) {
    if (a.has("error")) {
      return "error " + a.get("error");
    }
    List<String> parts = new ArrayList<>();
    for (Object t : Fixtures.list(a, "fires")) {
      parts.add(t instanceof Number n ? Js.isoString(n.longValue()) : "null");
    }
    return "[" + String.join(" ", parts) + "]";
  }

  private static boolean nodeRuns() {
    try {
      Process p = new ProcessBuilder("node", "--version").redirectErrorStream(true).start();
      p.getInputStream().readAllBytes();
      return p.waitFor(60, TimeUnit.SECONDS) && p.exitValue() == 0;
    } catch (IOException e) {
      return false;
    } catch (InterruptedException e) {
      Thread.currentThread().interrupt();
      return false;
    }
  }

  @Test
  void thePortAgreesWithCroner() throws Exception {
    Path dist = Fixtures.repo().resolve("packages/sdk/dist");
    assumeTrue(
        Files.exists(dist.resolve("index.js")),
        "croner parity: skipped, packages/sdk/dist is not built (npm run build --workspace"
            + " packages/sdk)");
    assumeTrue(nodeRuns(), "croner parity: skipped, node is not installed");
    Path helper = helper();
    for (long seed : new long[] {1, 2, 3}) {
      List<Case> generated = cases(seed, 1000);
      List<JsObject> input = new ArrayList<>();
      for (Case c : generated) {
        input.add(
            new JsObject()
                .set("schedule", c.schedule())
                .set("timezone", c.timezone().isEmpty() ? null : c.timezone())
                .set("from", c.from())
                .set("count", c.count()));
      }
      Path file = Files.createTempFile("cronwatch-schedule-parity-", ".json");
      Path out = Files.createTempFile("cronwatch-schedule-parity-", ".out");
      String expectedText;
      try {
        Files.writeString(file, Json.stringify(input), StandardCharsets.UTF_8);
        ProcessBuilder pb =
            new ProcessBuilder("node", helper.toString(), dist.toString(), file.toString())
                .redirectOutput(out.toFile())
                .redirectErrorStream(false);
        pb.environment().put("TZ", "UTC");
        Process node = pb.start();
        String err = new String(node.getErrorStream().readAllBytes(), StandardCharsets.UTF_8);
        assertTrue(node.waitFor(120, TimeUnit.SECONDS), "node took over 120 seconds");
        assertEquals(0, node.exitValue(), "node: " + err);
        expectedText = Files.readString(out, StandardCharsets.UTF_8);
      } finally {
        Files.deleteIfExists(file);
        Files.deleteIfExists(out);
      }
      List<?> expected = (List<?>) Objects.requireNonNull(Json.parse(expectedText));

      List<String> differences = new ArrayList<>();
      int valid = 0;
      int threw = 0;
      for (int i = 0; i < generated.size(); i++) {
        Case c = generated.get(i);
        JsObject want = (JsObject) Objects.requireNonNull(expected.get(i));
        JsObject got = answer(c);
        if (!want.has("error")) {
          valid++;
        }
        if (want.has("throws")) {
          threw++;
          // croner walks by recursion, a year at a time, so a date no month has (February 30)
          // runs out of stack before the year 3000. The port walks in a loop and finds
          // nothing: the schedule never fires.
          List<@Nullable Object> prefix = new ArrayList<>(Fixtures.list(want, "fires"));
          prefix.add(null);
          List<?> fires = Fixtures.list(got, "fires");
          if (fires.size() < prefix.size()
              || !Json.stringify(fires.subList(0, prefix.size())).equals(Json.stringify(prefix))) {
            differences.add(
                c.schedule()
                    + " in \""
                    + c.timezone()
                    + "\" from "
                    + c.from()
                    + "\n    croner threw "
                    + want.get("throws")
                    + " after "
                    + show(want)
                    + "\n    java "
                    + show(got));
          }
          continue;
        }
        if (!want.toJson().equals(got.toJson())) {
          differences.add(
              c.schedule()
                  + " in \""
                  + c.timezone()
                  + "\" from "
                  + c.from()
                  + "\n    croner "
                  + show(want)
                  + "\n    java   "
                  + show(got));
        }
      }
      differences.sort(null);
      assertTrue(
          differences.isEmpty(),
          "seed "
              + seed
              + ": "
              + differences.size()
              + " of "
              + generated.size()
              + " differ:\n"
              + String.join("\n", differences.subList(0, Math.min(10, differences.size()))));
      assertTrue(
          valid >= 300, "seed " + seed + ": only " + valid + " generated expressions were valid");
      System.out.println(
          "croner parity, seed "
              + seed
              + ": "
              + generated.size()
              + " cases, "
              + valid
              + " valid ("
              + threw
              + " where croner ran out of stack), "
              + (generated.size() - valid)
              + " refused with croner's message");
    }
  }

  private static Path helper() throws URISyntaxException {
    return Path.of(
        Objects.requireNonNull(CronerParityTest.class.getResource("schedule_parity.mjs")).toURI());
  }
}
