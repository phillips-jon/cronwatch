package dev.cronwatch.internal.js;

import static org.junit.jupiter.api.Assertions.assertEquals;

import dev.cronwatch.json.JsObject;
import dev.cronwatch.json.Json;
import java.util.List;
import net.jqwik.api.ForAll;
import net.jqwik.api.Property;

/**
 * The JSON reader, a door untrusted input comes through (a stored row, a request body): any text is
 * read or refused with a {@link Json.JsonException}, never another throw, and what is read writes
 * back as text that reads the same.
 */
class JsonProperties {
  @Property(tries = 500)
  void anyTextIsReadOrRefused(@ForAll String text) {
    Object v;
    try {
      v = Json.parse(text);
    } catch (Json.JsonException e) {
      return;
    }
    String once = Json.stringify(v);
    assertEquals(once, Json.stringify(Json.parse(once)));
  }

  @Property(tries = 500)
  void numbersRoundTrip(@ForAll double n) {
    String text = Json.stringify(n);
    if (!Double.isFinite(n)) {
      assertEquals("null", text);
      return;
    }
    assertEquals(n == 0 ? 0.0 : n, Json.parse(text));
  }

  @Property(tries = 300)
  void stringsRoundTrip(@ForAll String s) {
    JsObject o = new JsObject().set(s, List.of(s));
    assertEquals(o.toJson(), Json.stringify(Json.parse(o.toJson())));
    assertEquals(s, Json.parse(Json.quote(s)));
  }
}
