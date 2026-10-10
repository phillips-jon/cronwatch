package dev.cronwatch.web;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertTrue;

import dev.cronwatch.Gen;
import dev.cronwatch.internal.web.Origins;
import java.util.List;
import org.junit.jupiter.api.Test;

/**
 * A request, the door the dashboard's untrusted input comes through: any method, target, headers,
 * and body, in five configurations of the routes, is answered without a throw and without a 500
 * (the routes catch a throw and answer 500, so a 500 here is a bug), and reports nothing. The
 * origin reader, which reads a {@code Host} and forwarded headers anyone can send, answers any
 * text.
 */
class RoutesProperties {
  private static final List<String> METHODS =
      List.of("GET", "POST", "DELETE", "HEAD", "PUT", "get", "OPTIONS");
  private static final List<String> PATHS =
      List.of(
          "/cronwatch",
          "/",
          "/cronwatch/",
          "/cronwatch/api/",
          "jobs/",
          "api/jobs/",
          "x",
          "%2F",
          "%zz",
          "%e9",
          "..",
          "./",
          "\\",
          "silence",
          "unsilence",
          "forget",
          "check",
          "runs/",
          "?",
          "&",
          "=",
          "token=tok",
          "runs=",
          "for=",
          "#",
          "é",
          "manifest.webmanifest",
          "icons/");
  private static final List<String> NAMES =
      List.of(
          "host",
          "authorization",
          "cookie",
          "origin",
          "referer",
          "content-type",
          "sec-fetch-site",
          "x-forwarded-proto",
          "x-forwarded-host");
  private static final List<String> VALUES =
      List.of(
          "Bearer tok",
          "bearer ",
          "cronwatch_token=",
          "http://app.test",
          "https://",
          "[::1]",
          "localhost:1@",
          "application/json",
          "application/x-www-form-urlencoded",
          "multipart/form-data; boundary=b",
          "same-origin",
          "none",
          ",",
          ";",
          "%",
          "é",
          "0x7f.1",
          "xn--",
          "evil.example/.localhost");
  private static final List<String> BODIES =
      List.of(
          "for=",
          "1h",
          "{\"for\":",
          "\"2h\"",
          "}",
          "[",
          "]",
          "--b\r\n",
          "Content-Disposition: form-data; name=\"for\"\r\n\r\n",
          "--b--",
          "&",
          "9".repeat(30),
          "e",
          "%");

  @Test
  void anyRequestIsAnsweredWithoutA500() {
    List<RoutesOptions> configurations =
        List.of(
            RoutesOptions.builder().token("tok").basePath("/cronwatch").build(),
            RoutesOptions.builder().noToken().build(),
            RoutesOptions.builder().token("tok").basePath("").trustProxy().build(),
            RoutesOptions.builder().token("tok").origin("https://app.example.com").build(),
            RoutesOptions.builder().noToken().basePath("/a/b/").trustProxy().build());
    for (int c = 0; c < configurations.size(); c++) {
      try (WebKit w = new WebKit(configurations.get(c), b -> {})) {
        w.ok("x");
        Gen.check(
            100 + c,
            150,
            g -> {
              Request.Builder b =
                  Request.builder(
                      g.oneOf(METHODS),
                      g.bool() ? g.joined(PATHS, 8) : "/cronwatch/" + g.anyString(30));
              long n = g.between(0, 6);
              for (int i = 0; i < n; i++) {
                b.header(g.oneOf(NAMES), g.bool() ? g.joined(VALUES, 4) : g.anyString(20));
              }
              if (g.bool()) {
                b.body(g.bool() ? g.joined(BODIES, 10) : g.anyString(60));
              }
              Response r = w.routes.handle(b.tls(g.bool()).build());
              assertTrue(r.status() != 500, "answered 500: " + r.text());
            });
        assertEquals(List.of(), w.wheres, "reported: " + w.messages);
      }
    }
  }

  @Test
  void anyOriginTextIsReadOrRefused() {
    Gen.check(
        7,
        2000,
        g -> {
          String text = g.bool() ? g.joined(VALUES, 6) : g.anyString(40);
          String read = Origins.bare(text);
          if (read != null) {
            assertEquals(read, Origins.bare(read), "an origin reads as itself: " + text);
          }
          Origins.isLoopback(text);
          Origins.ofRequest(g.bool(), text);
          try {
            Origins.configured(text);
          } catch (IllegalArgumentException e) {
            assertTrue(e.getMessage().startsWith("routes: origin must be "), e.getMessage());
          }
        });
  }
}
