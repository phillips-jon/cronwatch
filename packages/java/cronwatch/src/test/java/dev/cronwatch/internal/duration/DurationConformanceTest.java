package dev.cronwatch.internal.duration;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertTrue;

import dev.cronwatch.Fixtures;
import dev.cronwatch.json.JsObject;
import java.util.List;
import java.util.Set;
import org.junit.jupiter.api.Test;

/**
 * Replays conformance/duration.json, the cases scripts/conformance.mjs writes by running the SDK,
 * comparing every answer as the JSON the SDK writes, byte for byte.
 */
class DurationConformanceTest {
  /** A number that may travel as {@code {"special": "NaN"}}. */
  static double number(Object v) {
    if (v instanceof JsObject o) {
      return switch (String.valueOf(o.get("special"))) {
        case "NaN" -> Double.NaN;
        case "Infinity" -> Double.POSITIVE_INFINITY;
        case "-Infinity" -> Double.NEGATIVE_INFINITY;
        default -> throw new IllegalArgumentException("not a number: " + o.toJson());
      };
    }
    return ((Number) v).doubleValue();
  }

  /** Fails when the SDK writes a section a replay does not know. */
  static void known(JsObject fixture, Set<String> sections) {
    for (String key : fixture.keys()) {
      assertTrue(
          key.equals("generatedBy") || key.equals("sdkVersion") || sections.contains(key),
          "the fixture has a section this port does not replay: " + key);
    }
  }

  @Test
  void everyCaseMatchesTheSdk() {
    JsObject f = Fixtures.load("duration");
    Fixtures.Failures failures = new Fixtures.Failures();
    List<JsObject> parse = Fixtures.objects(f, "parse");
    for (JsObject c : parse) {
      Object input = c.get("input");
      String label = c.has("label") ? Fixtures.string(c, "label") : "";
      JsObject got = new JsObject().set("input", input);
      if (c.has("label")) {
        got.set("label", label);
      }
      try {
        double ms =
            input instanceof String s
                ? Durations.parse(s, label)
                : Durations.parse(number(input), label);
        got.set("ms", ms);
      } catch (IllegalArgumentException e) {
        got.set("error", e.getMessage());
      }
      failures.same("parse", got, c);
    }
    List<JsObject> format = Fixtures.objects(f, "format");
    for (JsObject c : format) {
      JsObject got =
          new JsObject().set("ms", c.get("ms")).set("text", Durations.format(number(c.get("ms"))));
      failures.same("format", got, c);
    }
    List<JsObject> relative = Fixtures.objects(f, "relative");
    for (JsObject c : relative) {
      JsObject got =
          new JsObject()
              .set("at", c.get("at"))
              .set("now", c.get("now"))
              .set(
                  "text",
                  Durations.formatRelative(Fixtures.integer(c, "at"), Fixtures.integer(c, "now")));
      failures.same("relative", got, c);
    }
    failures.check("duration");
    assertEquals(68, parse.size(), "parse cases");
    assertEquals(26, format.size(), "format cases");
    assertEquals(9, relative.size(), "relative cases");
    known(f, Set.of("parse", "format", "relative"));
  }
}
