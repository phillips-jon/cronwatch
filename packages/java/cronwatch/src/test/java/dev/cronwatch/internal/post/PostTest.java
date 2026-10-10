package dev.cronwatch.internal.post;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertInstanceOf;
import static org.junit.jupiter.api.Assertions.assertNull;
import static org.junit.jupiter.api.Assertions.assertThrows;

import dev.cronwatch.CronwatchException;
import java.io.IOException;
import java.net.ConnectException;
import java.util.List;
import java.util.Map;
import java.util.concurrent.ExecutionException;
import org.junit.jupiter.api.Test;

/** The URL read as fetch reads it, the headers checked as fetch checks them, and the cuts. */
class PostTest {
  private static String written(String raw) {
    WhatwgUrl.Parsed p = WhatwgUrl.parse(raw);
    return p instanceof WhatwgUrl.Special s ? s.url().toString() : p.toString();
  }

  @Test
  void urlsAreReadAsFetchReadsThem() {
    String[][] cases = {
      {"HTTPS://EXAMPLE.com:443/a/./b/../c?x y#f g", "https://example.com/a/c?x%20y#f%20g"},
      {"https:\\\\h.example\\a\\b", "https://h.example/a/b"},
      {"https:h.example/x", "https://h.example/x"},
      {"http://ex%41mple.com/", "http://example.com/"},
      {"http://h:80/", "http://h/"},
      {"http://h:0080/", "http://h/"},
      {"http://h:/p", "http://h/p"},
      {"http://h:8080", "http://h:8080/"},
      {"http://0x7f.1/", "http://127.0.0.1/"},
      {"http://2130706433/", "http://127.0.0.1/"},
      {"http://0177.0.0.1/", "http://127.0.0.1/"},
      {"http://127.1/", "http://127.0.0.1/"},
      {"http://1.2.3.4./", "http://1.2.3.4/"},
      {"http://[0:0:0:0:0:0:0:1]/", "http://[::1]/"},
      {"http://[2001:DB8::1:0:0:1]/", "http://[2001:db8::1:0:0:1]/"},
      {"http://[::ffff:192.168.0.1]/", "http://[::ffff:c0a8:1]/"},
      {"http://[1:0:0:2:0:0:0:3]/", "http://[1:0:0:2::3]/"},
      {"http://h/a/%2e%2E/b/.", "http://h/b/"},
      {"http://h/?q='\"<>", "http://h/?q=%27%22%3C%3E"},
      {"http://h/\u00e9?\u00e9#\u00e9", "http://h/%C3%A9?%C3%A9#%C3%A9"},
      {"  http://h/\t\n  ", "http://h/"},
    };
    for (String[] c : cases) {
      assertEquals(c[1], written(c[0]), c[0]);
    }
    for (String bad :
        List.of(
            "http://1.2.3.4.5/",
            "http://256.1.1.1/",
            "http://1.2.3.256/",
            "http://example.1/",
            "http://[::1::2]/",
            "http://[fe80::1%25eth0]/",
            "http://h:65536/",
            "http://h:8x/",
            "http://a b/",
            "http:///",
            "http://b\u00fccher.example/",
            "1http://h/",
            "no scheme")) {
      assertInstanceOf(WhatwgUrl.Invalid.class, WhatwgUrl.parse(bad), bad);
    }
    assertEquals(new WhatwgUrl.Other("mailto"), WhatwgUrl.parse("mailto:a@b.c"));
    WhatwgUrl u = ((WhatwgUrl.Special) WhatwgUrl.parse("https://us%65r:p@h/x")).url();
    assertEquals("us%65r", u.username());
    assertEquals("https://h/x", u.toString());
  }

  @Test
  void aUrlIsPostableOnlyWhenTheUriReadsTheSameHost() {
    assertEquals("https://h.example/a", Post.postable("https://h.example/a").toString());
    for (String raw :
        List.of("https://a_b.example/x", "https://u:p@h.example/x", "https://h.example:99999/")) {
      CronwatchException e = assertThrows(CronwatchException.class, () -> Post.postable(raw));
      assertEquals("only http and https URLs can be posted to, not this URL", e.getMessage());
    }
    assertEquals(
        "only http and https URLs can be posted to, not ws:",
        assertThrows(CronwatchException.class, () -> Post.postable("ws://h/")).getMessage());
    assertEquals("/a%5Bb%5D%7C?q=%7B%25zz%7D%5E%60", Post.uriSafe("/a[b]|?q={%zz}^`"));
    assertEquals("/a%20b?c=%41", Post.uriSafe("/a%20b?c=%41"));
    assertEquals("null", Post.origin("mailto:x"));
  }

  @Test
  void headersAreCheckedAsFetchChecksThemNamingTheHeaderAndNeverItsValue() {
    assertEquals(
        List.of(Map.entry("a", "b c"), Map.entry("X-Y", "")),
        Post.headers(List.of(Map.entry("a", " \t b c \r\n"), Map.entry("X-Y", "  "))));
    CronwatchException e =
        assertThrows(CronwatchException.class, () -> Post.headers(List.of(Map.entry("a b", "v"))));
    assertEquals(
        "a header name must be a token (letters, digits, and !#$%&'*+.^_`|~-)", e.getMessage());
    e =
        assertThrows(
            CronwatchException.class,
            () -> Post.headers(List.of(Map.entry("authorization", "secret\rX: y"))));
    assertEquals("the authorization header's value may not contain a line break", e.getMessage());
    assertThrows(CronwatchException.class, () -> Post.headers(List.of(Map.entry("", "v"))));
  }

  @Test
  void cutsAndBodiesAreTheSdks() {
    assertEquals("ab", Post.cut("ab\ud83d\ude00", 3));
    assertEquals("ab\ud83d\ude00", Post.cut("ab\ud83d\ude00", 4));
    assertEquals("", Post.cut("\ud83d\ude00", 1));
    assertEquals("[redacted]x", Post.errorBody("sekretx", List.of("sekret", "abc")));
    assertEquals("a\ufffdb", Post.text(new byte[] {'a', (byte) 0xff, 'b'}));
    assertEquals("x", Post.text(new byte[] {(byte) 0xef, (byte) 0xbb, (byte) 0xbf, 'x'}));
  }

  @Test
  void aTransportsErrorIsWrittenAsItsNameAndMessageWithItsCauses() {
    assertEquals("ConnectException", Post.describe(new ConnectException()));
    assertEquals(
        "IOException: boom: ConnectException: refused",
        Post.describe(
            new ExecutionException(new IOException("boom", new ConnectException("refused")))));
    // A cause whose text the message already carries adds nothing.
    assertEquals(
        "IOException: java.net.ConnectException: refused",
        Post.describe(new IOException(new ConnectException("refused"))));
    assertNull(WhatwgUrl.ipv6("1:2:3:4:5:6:7:8:9"));
    assertEquals("::", WhatwgUrl.ipv6Text(new int[8]));
  }
}
