package dev.cronwatch.internal.evaluate;

import static org.junit.jupiter.api.Assertions.assertEquals;

import dev.cronwatch.Fixtures;
import dev.cronwatch.internal.core.Recorder;
import dev.cronwatch.internal.output.Output;
import dev.cronwatch.json.JsObject;
import dev.cronwatch.json.Json;
import java.util.ArrayList;
import java.util.List;
import org.junit.jupiter.api.Test;

/**
 * {@code conformance/format.json}: alert titles and messages, numbers as {@code toLocaleString}
 * writes them, the output cap, stored definitions and expect rules; and {@code output.json}'s
 * {@code expectText} cases, which hold the run recorder to the SDK's.
 */
class FormatConformanceTest {
  @Test
  void alertsNumbersCapsDefinitionsAndRules() {
    JsObject f = Fixtures.load("format");
    Fixtures.Failures fails = new Fixtures.Failures();

    List<JsObject> alerts = Fixtures.objects(f, "alerts");
    assertEquals(35, alerts.size(), "alerts");
    int i = 0;
    for (JsObject c : alerts) {
      var got =
          Format.composeAlert(
              Cases.draft(c.get("draft")),
              Cases.definition(c.get("definition")),
              Fixtures.integer(c, "now"));
      fails.same("alert " + i++, got.toValue(), c.get("alert"));
    }

    List<JsObject> numbers = Fixtures.objects(f, "numbers");
    assertEquals(38, numbers.size(), "numbers");
    for (JsObject c : numbers) {
      double n = Fixtures.number(c, "n");
      fails.same("formatNumber(" + Json.stringify(n) + ")", Format.formatNumber(n), c.get("text"));
    }

    List<JsObject> caps = Fixtures.objects(f, "capOutput");
    assertEquals(14, caps.size(), "capOutput");
    for (JsObject c : caps) {
      String piece = Fixtures.string(c, "piece");
      long times = Fixtures.integer(c, "times");
      String out = Output.cap(Fixtures.string(c, "prefix") + piece.repeat((int) times));
      JsObject got =
          new JsObject().set("length", out.length()).set("sha256", Fixtures.sha256Hex(out));
      JsObject want = new JsObject().set("length", c.get("length")).set("sha256", c.get("sha256"));
      fails.same("capOutput(" + Json.stringify(piece) + " x " + times + ")", got, want);
    }

    List<JsObject> stored = Fixtures.objects(f, "toStored");
    assertEquals(7, stored.size(), "toStored");
    for (JsObject c : stored) {
      JsObject input = Fixtures.object(c, "definition");
      Expect rule = input.has("expect") ? Cases.rule(input.get("expect")) : null;
      fails.same("toStored", Expect.toStored(input, rule).toObject(), c.get("stored"));
    }

    List<JsObject> checks = Fixtures.objects(f, "checkExpectation");
    assertEquals(13, checks.size(), "checkExpectation");
    for (JsObject c : checks) {
      String got =
          Expect.checkExpectation(Cases.rule(c.get("expect")), Fixtures.string(c, "output"));
      fails.same("checkExpectation(" + Json.stringify(c.get("expect")) + ")", got, c.get("result"));
    }
    fails.check("format");
  }

  /**
   * A recorder case's lines: plain strings, recipes, and runs of numbered lines padded to a width.
   */
  private static List<String> lines(List<?> spec) {
    List<String> out = new ArrayList<>();
    for (Object line : spec) {
      if (line instanceof JsObject o && o.has("numbered")) {
        String prefix = Fixtures.string(o, "numbered");
        long count = Fixtures.integer(o, "count");
        long width = Fixtures.integer(o, "width");
        for (long i = 0; i < count; i++) {
          String head = prefix + i + " ";
          out.add(head + "x".repeat((int) Math.max(0, width - head.length())));
        }
        continue;
      }
      out.add(Fixtures.expand(line));
    }
    return out;
  }

  @Test
  void theRecorderKeepsWhatTheSdksKeeps() {
    JsObject o = Fixtures.load("output");
    Fixtures.Failures fails = new Fixtures.Failures();
    List<JsObject> cases = Fixtures.objects(o, "expectText");
    assertEquals(11, cases.size(), "expectText cases");
    for (JsObject c : cases) {
      String name = Fixtures.string(c, "name");
      Recorder rec = new Recorder();
      for (String line : lines(Fixtures.list(c, "lines"))) {
        rec.log(line);
      }
      String text = rec.expectText();
      fails.same(name + ": expectText", Fixtures.digest(text), c.get("expectText"));
      fails.same(name + ": output", Fixtures.digest(rec.output()), c.get("output"));
      for (JsObject ch : Fixtures.objects(c, "checks")) {
        String needle = Fixtures.string(ch, "expect");
        String result = Expect.checkExpectation(new Expect.Contains(needle), text);
        fails.same(name + ": expect " + needle, result, ch.get("result"));
      }
    }
    fails.check("output");
  }
}
