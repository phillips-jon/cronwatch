package dev.cronwatch.internal.js;

import static org.junit.jupiter.api.Assertions.assertArrayEquals;
import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertNull;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;

import dev.cronwatch.json.JsObject;
import dev.cronwatch.json.Json;
import java.nio.charset.StandardCharsets;
import java.util.List;
import org.junit.jupiter.api.Test;

class JsTest {
  @Test
  void numbersPrintAsJavaScriptPrintsThem() {
    Object[][] cases = {
      {2.0, "2"},
      {-2.5, "-2.5"},
      {0.1, "0.1"},
      {1e-7, "1e-7"},
      {1.5e-7, "1.5e-7"},
      {0.000001, "0.000001"},
      {1e21, "1e+21"},
      {1e20, "100000000000000000000"},
      {1.2345678901234568e20, "123456789012345680000"},
      {Double.NaN, "NaN"},
      {Double.POSITIVE_INFINITY, "Infinity"},
      {Double.NEGATIVE_INFINITY, "-Infinity"},
      {-0.0, "0"},
      {1.7976931348623157e308, "1.7976931348623157e+308"},
      {Double.MIN_VALUE, "5e-324"},
      {1234.56785, "1234.56785"},
      {0.1 + 0.2, "0.30000000000000004"},
      {100.0, "100"},
      {1e23, "1e+23"},
      {2e-7, "2e-7"},
      {123e-20, "1.23e-18"},
    };
    for (Object[] c : cases) {
      assertEquals(c[1], Js.formatNumber((double) c[0]), String.valueOf(c[0]));
    }
    assertEquals("9007199254740991", Js.formatLong(Js.MAX_SAFE_INTEGER));
    assertEquals("9223372036854776000", Js.formatLong(Long.MAX_VALUE));
    assertEquals("-9223372036854776000", Js.formatLong(Long.MIN_VALUE));
  }

  @Test
  void integersAndRounding() {
    assertTrue(Js.isInteger(3.0));
    assertFalse(Js.isInteger(3.5));
    assertFalse(Js.isInteger(Double.POSITIVE_INFINITY));
    assertEquals(0L, Js.toLong(Double.NaN));
    assertEquals(Long.MAX_VALUE, Js.toLong(1e300));
    assertEquals(3.0, Js.round(2.5));
    assertEquals(-2.0, Js.round(-2.5));
  }

  @Test
  void textIsCountedAndTrimmedAsJavaScriptDoes() {
    assertEquals("a", Js.trim("\ufeff a \u3000"));
    assertEquals(" a", Js.trimEnd(" a \n"));
    assertEquals("bc", Js.slice("abc", -2, 3));
    assertEquals("", Js.slice("abc", 2, 1));
    assertEquals("ef", Js.tail("abcdef", 2));
    assertArrayEquals(
        "a\ufffdb".getBytes(StandardCharsets.UTF_8), Js.utf8("a\ud83db"), "lone surrogate");
    assertEquals("x\ufffd", Js.wellFormed("x\ud83d"));
    assertEquals("x\ud83d\ude00", Js.wellFormed("x\ud83d\ude00"));
  }

  @Test
  void datesAsJavaScriptWritesThem() {
    assertEquals("1970-01-01T00:00:00.000Z", Js.isoString(0));
    assertEquals("2026-01-05T09:30:00.000Z", Js.isoString(1_767_605_400_000L));
    assertEquals("1969-12-31T23:59:59.999Z", Js.isoString(-1));
    assertEquals("+010000-01-01T00:00:00.000Z", Js.isoString(253_402_300_800_000L));
    assertEquals("0001-01-01T00:00:00.000Z", Js.isoTime(Js.FIRST_DATE_MS));
    assertEquals("9999-12-31T23:59:59.999Z", Js.isoTime(Js.LAST_DATE_MS));
    assertNull(Js.isoTime(Js.FIRST_DATE_MS - 1));
    assertNull(Js.isoTime(Js.LAST_DATE_MS + 1));
    assertEquals("before 0001-01-01 00:00:00 UTC", Js.isoOrWords(Long.MIN_VALUE));
    assertEquals("after 9999-12-31 23:59:59 UTC", Js.isoOrWords(Long.MAX_VALUE));
    assertEquals(1_767_605_400_000L, Js.dateUtc(2026, 0, 5, 9, 30, 0, 0));
    assertEquals(1_767_605_400_000L, Js.dateUtc(2025, 12, 5, 9, 30, 0, 0));
    long[] ymd = Js.civilFromDays(Js.daysFromCivil(2024, 2, 29));
    assertArrayEquals(new long[] {2024, 2, 29}, ymd);
  }

  @Test
  void keysKeepJavaScriptsOrder() {
    JsObject o = new JsObject().set("b", 1).set("10", 2).set("a", 3).set("2", 4).set("b", 5);
    assertEquals("{\"2\":4,\"10\":2,\"b\":5,\"a\":3}", o.toJson());
    Object parsed = Json.parse("{\"z\":1,\"1\":2,\"z\":3,\"4294967295\":4}");
    assertEquals("{\"1\":2,\"z\":3,\"4294967295\":4}", Json.stringify(parsed));
  }

  @Test
  void stringsEscapeAsJsonStringifyDoes() {
    assertEquals("\"a\\\"b\\\\c\\n\\u0001<>&\u2028\"", Json.quote("a\"b\\c\n\u0001<>&\u2028"));
    assertEquals("\"a\\ud83d\"", Json.quote("a\ud83d"));
    assertEquals("\"\\ude00b\"", Json.quote("\ude00b"));
    assertEquals("\"\ud83d\ude00\"", Json.quote("\ud83d\ude00"));
    assertEquals("\ud83d\ude00 \ud83d x \u00e9", Json.parse("\"\ud83d\ude00 \\ud83d x \u00e9\""));
    assertEquals("\ud83d\ude00", Json.parse("\"\\ud83d\\ude00\""));
  }

  @Test
  void numbersAndErrors() {
    assertEquals("[null,0,2.5]", Json.stringify(Json.parse("[1e400,-0,2.50]")));
    assertEquals(
        "Expected property name at position 1",
        assertThrows(Json.JsonException.class, () -> Json.parse("{")).getMessage());
    assertEquals(
        "Unexpected non-whitespace character after JSON at position 2",
        assertThrows(Json.JsonException.class, () -> Json.parse("1 2")).getMessage());
    assertThrows(Json.JsonException.class, () -> Json.parse("-"));
    assertThrows(Json.JsonException.class, () -> Json.parse("\"\u0001\""));
    assertEquals(
        "[1,9007199254740992,\"x\"]", Json.stringify(List.of(1, 9_007_199_254_740_993L, "x")));
  }

  @Test
  void nestingIsHeldToMaxDepth() {
    assertEquals(
        List.of(), unwrap(Json.parse("[".repeat(Json.MAX_DEPTH) + "]".repeat(Json.MAX_DEPTH))));
    assertEquals(
        "JSON nested too deeply",
        assertThrows(
                Json.JsonException.class,
                () -> Json.parse("[".repeat(Json.MAX_DEPTH + 1) + "]".repeat(Json.MAX_DEPTH + 1)))
            .getMessage());
    assertThrows(
        Json.JsonException.class, () -> Json.parse("[".repeat(1_000_000) + "]".repeat(1_000_000)));
    assertThrows(
        Json.JsonException.class,
        () -> Json.parse("{\"a\":".repeat(200_000) + "}".repeat(200_000)));
  }

  @Test
  void manyKeysAreReadInLinearTime() {
    // The Elixir audit: an object of many keys was quadratic to read.
    StringBuilder b = new StringBuilder("{");
    for (int i = 0; i < 200_000; i++) {
      if (i > 0) {
        b.append(',');
      }
      b.append("\"k").append(i).append("\":").append(i);
    }
    b.append('}');
    long started = System.nanoTime();
    JsObject o = Json.parseObject(b.toString());
    assertEquals(200_000, o.size());
    assertTrue(System.nanoTime() - started < 30_000_000_000L, "read in under 30 seconds");
  }

  private static Object unwrap(Object v) {
    Object x = v;
    while (x instanceof List<?> list && list.size() == 1) {
      x = list.get(0);
    }
    return x;
  }
}
