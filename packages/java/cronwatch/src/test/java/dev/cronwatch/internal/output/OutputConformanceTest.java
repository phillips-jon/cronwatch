package dev.cronwatch.internal.output;

import static org.junit.jupiter.api.Assertions.assertEquals;

import dev.cronwatch.Fixtures;
import dev.cronwatch.json.JsObject;
import java.util.ArrayList;
import java.util.List;
import org.junit.jupiter.api.Test;

/**
 * {@code conformance/output.json}: the output cap, every redaction case and every error message,
 * byte for byte. The recorder's {@code expectText} cases are replayed beside the recorder.
 */
class OutputConformanceTest {
  private static final JsObject FIXTURE = Fixtures.load("output");

  @Test
  void outputCap() {
    assertEquals(Output.OUTPUT_CAP, Fixtures.integer(FIXTURE, "outputCap"));
  }

  @Test
  void redact() {
    List<JsObject> cases = Fixtures.objects(FIXTURE, "redact");
    assertEquals(204, cases.size(), "redact cases");
    Fixtures.Failures failures = new Fixtures.Failures();
    for (int i = 0; i < cases.size(); i++) {
      JsObject c = cases.get(i);
      String input = Fixtures.expand(c.get("input"));
      String got = Output.redactSecrets(input);
      failures.same(
          "redact case " + i + " " + input.substring(0, Math.min(60, input.length())),
          Fixtures.digest(got),
          c.get("result"));
    }
    failures.check("output");
  }

  @Test
  void redactAndCap() {
    assertEquals(Output.REDACT_EDGE, Fixtures.integer(FIXTURE, "redactEdge"));
    List<JsObject> cases = Fixtures.objects(FIXTURE, "redactAndCap");
    assertEquals(15, cases.size(), "redactAndCap cases");
    Fixtures.Failures failures = new Fixtures.Failures();
    for (int i = 0; i < cases.size(); i++) {
      JsObject c = cases.get(i);
      String got = Output.redactAndCap(Fixtures.expand(c.get("input")), Output::redactSecrets);
      failures.same("redactAndCap case " + i, Fixtures.digest(got), c.get("result"));
    }
    failures.check("output");
  }

  @Test
  void errorMessage() {
    List<JsObject> cases = Fixtures.objects(FIXTURE, "errorMessage");
    assertEquals(16, cases.size(), "errorMessage cases");
    Fixtures.Failures failures = new Fixtures.Failures();
    for (int i = 0; i < cases.size(); i++) {
      JsObject c = cases.get(i);
      String text;
      if (c.has("value")) {
        Object v = c.get("value");
        boolean recipe = v instanceof JsObject o && o.has("parts");
        text = Output.errorMessage(recipe ? Fixtures.expand(v) : v);
      } else {
        List<String> frames = new ArrayList<>();
        for (Object f : Fixtures.list(c, "frames")) {
          frames.add((String) f);
        }
        text =
            Output.errorMessage(
                String.valueOf(Fixtures.string(c, "name")),
                Fixtures.expand(c.get("message")),
                frames);
      }
      failures.same("errorMessage case " + i, Fixtures.digest(text), c.get("result"));
    }
    failures.check("output");
  }
}
