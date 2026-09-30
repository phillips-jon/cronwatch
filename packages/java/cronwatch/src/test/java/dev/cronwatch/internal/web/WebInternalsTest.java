package dev.cronwatch.internal.web;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertNull;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;

import java.nio.charset.StandardCharsets;
import java.util.List;
import java.util.Map;
import org.junit.jupiter.api.Test;

/**
 * The pieces the dashboard reads requests and writes pages with, as the Rust port's unit tests hold
 * them: origins read as {@code URL#origin} reads them, paths as the URL parser leaves them, forms,
 * JSON and multipart bodies as fetch reads them, and numbers as JavaScript writes them.
 */
class WebInternalsTest {
  private static byte[] b(String s) {
    return s.getBytes(StandardCharsets.UTF_8);
  }

  @Test
  void originsAreReadAsUrlOriginReadsThem() {
    String[][] cases = {
      {" HTTPS://App.Example.COM:443/x ", "https://app.example.com"},
      {"http:\\\\example.com:8080", "http://example.com:8080"},
      {"http://0x7f.1", "http://127.0.0.1"},
      {"http://[0:0::1]:80", "http://[::1]"},
      {"https://bücher.example", "https://xn--bcher-kva.example"},
      {"http://user:pw@example.com", "http://example.com"},
      {"http://[::ffff:1.2.3.4]", "http://[::ffff:102:304]"},
      {"http://1.2.3.4.", "http://1.2.3.4"},
      {"http://[2001:db8:0:0:1:0:0:1]", "http://[2001:db8::1:0:0:1]"},
      {"http://%6c%6f%63%61%6c%68%6f%73%74:3000", "http://localhost:3000"},
    };
    for (String[] c : cases) {
      assertEquals(c[1], Origins.configured(c[0]), c[0]);
    }
    assertEquals(
        "routes: origin must be an absolute URL such as \"https://app.example.com\", got"
            + " \"app.example.com\"",
        assertThrows(IllegalArgumentException.class, () -> Origins.configured("app.example.com"))
            .getMessage());
    assertEquals(
        "routes: origin must be http or https, got \"ftp://app.example.com\"",
        assertThrows(
                IllegalArgumentException.class, () -> Origins.configured("ftp://app.example.com"))
            .getMessage());
    assertNull(Origins.configured(""));
    assertThrows(IllegalArgumentException.class, () -> Origins.configured("http://256.1.1.1.1"));
    assertThrows(IllegalArgumentException.class, () -> Origins.configured("http://a b"));
    assertThrows(IllegalArgumentException.class, () -> Origins.configured("http://[::1%25eth0]"));
    assertThrows(IllegalArgumentException.class, () -> Origins.configured("http://x:65536"));
  }

  @Test
  void aBareOriginHasNothingPastItsHost() {
    assertEquals("https://evil.example", Origins.bare("https://evil.example"));
    assertEquals("https://evil.example", Origins.bare("https://evil.example/"));
    assertNull(Origins.bare("https://evil.example/path"));
    assertNull(Origins.bare("https://user@evil.example"));
    assertNull(Origins.bare("https://evil.example?q"));
    assertNull(Origins.bare("javascript://evil.example"));
  }

  // The Go port's second audit: a Host header outside ASCII is punycoded only up to 1024 bytes;
  // past that it is not read as a URL at all.
  @Test
  void aLongHostOutsideAsciiIsNotReadAsAUrl() {
    String long_ = "é".repeat(600);
    assertNull(Origins.bare("http://" + long_));
    // As a server hands the header over: each byte of its UTF-8 one character.
    String sent = new String(b(long_), StandardCharsets.ISO_8859_1);
    assertEquals("http://" + long_, Origins.ofRequest(false, sent));
    String short_ = "é".repeat(10);
    assertTrue(Origins.bare("http://" + short_).startsWith("http://xn--"));
    // A host as a server reads it, each byte a character, is read as the UTF-8 it was sent in.
    String wire = new String(b("bücher.example"), StandardCharsets.ISO_8859_1);
    assertEquals("http://xn--bcher-kva.example", Origins.ofRequest(false, wire));
    assertEquals("https://app.test", Origins.ofRequest(true, "APP.test:443"));
  }

  @Test
  void loopbackHosts() {
    for (String yes :
        List.of(
            "http://localhost:3000",
            "http://app.localhost",
            "http://127.0.0.1",
            "http://127.8.9.10",
            "http://[::1]:3000",
            "http://0x7f.1")) {
      assertTrue(Origins.isLoopback(yes), yes);
    }
    for (String no :
        List.of(
            "http://localhost.example",
            "http://128.0.0.1",
            "http://127.0.0.256",
            "http://10.0.0.5:8080",
            "http://[::2]",
            // A Host header that is not a host (the Rust audit).
            "http://evil.example/.localhost",
            "http://localhost:1@evil.example",
            "http://evil.example?.localhost",
            "http://evil.example#.localhost")) {
      assertFalse(Origins.isLoopback(no), no);
    }
  }

  @Test
  void pathsAreReadAsTheUrlParserLeavesThem() {
    String[][] cases = {
      {"/cronwatch/./jobs/x", "/cronwatch/jobs/x"},
      {"/cronwatch/nope/../jobs/x", "/cronwatch/jobs/x"},
      {"/cronwatch\\jobs\\x", "/cronwatch/jobs/x"},
      {"/cronwatch/%2e/jobs/x", "/cronwatch/jobs/x"},
      {"/a/..", "/"},
      {"/a/b/.", "/a/b/"},
      {"/a b/{c}", "/a%20b/%7Bc%7D"},
      {"/é", "/%C3%A9"},
      {"/../..", "/"},
    };
    for (String[] c : cases) {
      assertEquals(c[1], Requests.normalizePath(c[0]), c[0]);
    }
  }

  @Test
  void targets() {
    assertEquals(List.of("/a", "b=c"), List.of(Requests.target("/a?b=c#d")));
    assertEquals(List.of("/x", "y"), List.of(Requests.target("http://host:1/x?y")));
    assertEquals(List.of("/", ""), List.of(Requests.target("http://host")));
    assertEquals(List.of("/", ""), List.of(Requests.target("*")));
  }

  @Test
  void formsAndJson() {
    assertEquals(
        List.of(Map.entry("a", "b c"), Map.entry("d", "%zz"), Map.entry("e", "�")),
        Requests.parseForm(b("a=b+c&&d=%zz&e=%E9")));
    assertEquals("b+c%2F%C3%A9", Requests.formEncode("b c/é"));
    assertEquals("7200000", Requests.bodyField("application/json", b("{\"for\":7200000}"), "for"));
    assertEquals("true", Requests.bodyField("application/json", b("﻿{\"for\":true}"), "for"));
    assertEquals("null", Requests.bodyField("application/json", b("{\"for\":null}"), "for"));
    assertEquals("1,,2", Requests.bodyField("application/json", b("{\"for\":[1,null,2]}"), "for"));
    assertEquals(
        "[object Object]", Requests.bodyField("application/json", b("{\"for\":{}}"), "for"));
    assertEquals("2h", Requests.bodyField("application/json", b("[\"1h\",\"2h\"]"), "1"));
    assertNull(Requests.bodyField("application/json", b("{"), "for"));
    assertEquals(
        "2h", Requests.bodyField("application/x-www-form-urlencoded", b("for=1h&for=2h"), "for"));
    assertNull(Requests.bodyField("text/plain", b("for=1h"), "for"));
    String multipart = "--b\r\nContent-Disposition: form-data; name=\"for\"\r\n\r\n2h\r\n--b--\r\n";
    assertEquals("2h", Requests.bodyField("multipart/form-data; boundary=b", b(multipart), "for"));
    String disposition = "Content-Disposition: form-data; name=\"for\"; filename=\"x.txt\"";
    String file = "--b\r\n" + disposition + "\r\n\r\n2h\r\n--b--\r\n";
    assertEquals(
        "[object File]", Requests.bodyField("multipart/form-data; boundary=\"b\"", b(file), "for"));
    assertNull(
        Requests.bodyField(
            "multipart/form-data; boundary=b",
            b("--b\r\nContent-Disposition: form-data; name=\"for\"\r\n\r\n2h"),
            "for"));
    assertNull(Requests.bodyField("multipart/form-data", b(multipart), "for"));
  }

  @Test
  void decoding() {
    assertEquals("a/b", Requests.safeDecode("a%2Fb"));
    assertNull(Requests.safeDecode("%zz"));
    assertNull(Requests.safeDecode("%E9"));
    assertNull(Requests.safeDecode("%"));
  }

  @Test
  void headersJoinAsFetchJoinsThem() {
    List<Map.Entry<String, String>> hs =
        List.of(
            Map.entry("cookie", "a=1"),
            Map.entry("x-a", "1"),
            Map.entry("cookie", "b=2"),
            Map.entry("x-a", "2"));
    assertEquals("a=1; b=2", Requests.header(hs, "Cookie"));
    assertEquals("1, 2", Requests.header(hs, "x-a"));
    assertNull(Requests.header(hs, "x-b"));
  }

  @Test
  void toFixedRoundsAHalfAwayFromZeroOnTheExactValue() {
    Object[][] cases = {
      {0.25, 1, "0.3"},
      {0.35, 1, "0.3"},
      {1.005, 2, "1.00"},
      {2.5, 0, "3"},
      {-2.5, 0, "-3"},
      {-0.04, 1, "-0.0"},
      {0.0, 1, "0.0"},
      {123.456, 1, "123.5"},
      {0.123456, 4, "0.1235"},
      {1e20, 1, "100000000000000000000.0"},
      {Double.MIN_VALUE, 4, "0.0000"},
      {1000.0, 1, "1000.0"},
      {1e21, 1, "1e+21"},
    };
    for (Object[] c : cases) {
      assertEquals(c[2], Text.toFixed((double) c[0], (int) c[1]), c[0] + ".toFixed(" + c[1] + ")");
    }
  }

  @Test
  void namesBreakAfterRunsOfSeparators() {
    assertEquals(
        "wp:<wbr>store_<wbr>sync.<wbr>inventory--<wbr>eu",
        Text.escapeName("wp:store_sync.inventory--eu"));
    assertEquals("a-", Text.escapeName("a-"));
    assertEquals("&lt;a&gt;_<wbr>b", Text.escapeName("<a>_b"));
  }

  @Test
  void secretsCompareAsUtf16() {
    assertTrue(Text.constantTimeEquals("tok", "tok"));
    assertFalse(Text.constantTimeEquals("tok", "toK"));
    assertFalse(Text.constantTimeEquals("tok", "tok2"));
    assertFalse(Text.constantTimeEquals("é", new String(b("é"), StandardCharsets.ISO_8859_1)));
    assertTrue(Text.constantTimeEquals("é", "é"));
  }

  @Test
  void encodeUriComponent() {
    assertEquals(
        "wp%3Astore_sync.inventory--eu", Text.encodeUriComponent("wp:store_sync.inventory--eu"));
    assertEquals("a%2Fb%20c!~*'()%C3%A9", Text.encodeUriComponent("a/b c!~*'()é"));
  }
}
