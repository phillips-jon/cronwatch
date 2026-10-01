package dev.cronwatch.internal.js;

import static org.junit.jupiter.api.Assertions.assertEquals;

import dev.cronwatch.Gen;
import dev.cronwatch.json.JsObject;
import dev.cronwatch.json.Json;
import java.util.List;
import org.junit.jupiter.api.Test;

/**
 * The JSON reader, a door untrusted input comes through (a stored row, a request body): any text is
 * read or refused with a {@link Json.JsonException}, never another throw, and what is read writes
 * back as text that reads the same.
 */
class JsonProperties {
  private static final List<String> PIECES =
      List.of(
          "{",
          "}",
          "[",
          "]",
          ",",
          ":",
          "\"",
          "\"k\"",
          "\"\\u00e9\"",
          "\"\\ud83d\"",
          "1",
          "-0",
          "2.5e3",
          "1e400",
          "true",
          "false",
          "null",
          " ",
          "\n",
          "\\",
          "x");

  @Test
  void anyTextIsReadOrRefused() {
    Gen.check(
        1,
        1000,
        g -> {
          String text = g.bool() ? g.anyString(80) : g.joined(PIECES, 30);
          Object v;
          try {
            v = Json.parse(text);
          } catch (Json.JsonException e) {
            return;
          }
          String once = Json.stringify(v);
          assertEquals(once, Json.stringify(Json.parse(once)));
        });
  }

  @Test
  void numbersRoundTrip() {
    Gen.check(
        2,
        1000,
        g -> {
          double n = g.anyDouble();
          String text = Json.stringify(n);
          if (!Double.isFinite(n)) {
            assertEquals("null", text);
            return;
          }
          assertEquals(n == 0 ? 0.0 : n, Json.parse(text), text);
        });
  }

  @Test
  void stringsRoundTrip() {
    Gen.check(
        3,
        500,
        g -> {
          String s = g.anyString(60);
          JsObject o = new JsObject().set(s, List.of(s));
          assertEquals(o.toJson(), Json.stringify(Json.parse(o.toJson())));
          assertEquals(s, Json.parse(Json.stringify(s)));
        });
  }
}
