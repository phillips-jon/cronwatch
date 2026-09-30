package dev.cronwatch.web;

import static dev.cronwatch.web.WebKit.h;
import static dev.cronwatch.web.WebKit.headers;
import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertNull;
import static org.junit.jupiter.api.Assertions.assertTrue;

import dev.cronwatch.Cronwatch;
import dev.cronwatch.JobOptions;
import java.util.List;
import java.util.Map;
import java.util.concurrent.atomic.AtomicInteger;

/**
 * The cases of {@link RoutesEnvTest}, each run in a child JVM with the variables it needs, since a
 * JVM cannot change its own environment. A case that fails exits 1 with its stack trace; the parent
 * reads what it printed, as the sign-in line goes to standard output.
 */
public final class EnvChild {
  private EnvChild() {}

  private static final List<Map.Entry<String, String>> NONE = List.of();

  /** Runs the case named by the first argument. */
  public static void main(String[] args) {
    try {
      switch (args[0]) {
        case "locked" -> locked();
        case "developmentToken" -> developmentToken();
        case "emptyToken" -> emptyToken();
        case "openInDevelopment" -> openInDevelopment();
        case "configuredInDevelopment" -> configuredInDevelopment();
        case "signInLines" -> signInLines();
        case "handlerClosed" -> handlerClosed();
        case "handlerDevelopment" -> handlerDevelopment();
        case "profileFallback" -> profileFallback();
        default -> throw new IllegalArgumentException(args[0]);
      }
      System.out.println("CHILD OK");
      System.exit(0);
    } catch (Throwable t) {
      t.printStackTrace(System.out);
      System.exit(1);
    }
  }

  private static Cronwatch client() {
    return Cronwatch.builder().noCronSecret().noShutdownHook().build();
  }

  private static Response serve(Routes routes, String url, List<Map.Entry<String, String>> hs) {
    return WebKit.serve(routes, "GET", url, hs, "");
  }

  private static void locked() {
    try (Cronwatch cw = client()) {
      Routes routes = cw.routes();
      assertNull(routes.token());
      Response api = serve(routes, "http://localhost/cronwatch/api/jobs", NONE);
      assertEquals(503, api.status());
      assertEquals("{\"ok\":false,\"error\":\"CRONWATCH_TOKEN is not set\"}", api.text());
      Response page = serve(routes, "http://localhost/cronwatch", NONE);
      assertEquals(503, page.status());
      assertTrue(page.text().contains("CronWatch routes are locked"));
      assertTrue(page.text().contains("RoutesOptions.noToken()"));
      // The app shell is public even so.
      for (String path :
          List.of("/manifest.webmanifest", "/sw.js", "/app.js", "/offline", "/icons/icon.svg")) {
        assertEquals(200, serve(routes, "http://localhost/cronwatch" + path, NONE).status(), path);
      }
    }
  }

  private static void developmentToken() {
    try (Cronwatch cw = client()) {
      Routes routes = cw.routes(RoutesOptions.builder().basePath("/cronwatch/").build());
      String[][] urls = {
        {"http://localhost:3000/cronwatch/api/jobs"},
        {"http://localhost:3000/cronwatch/api/jobs", "x-forwarded-for", "127.0.0.1"},
        {"http://127.0.0.1:3000/cronwatch/"},
        {"http://192.168.1.20:3000/cronwatch/api/jobs"},
        {"http://[::1]:3000/cronwatch/api/jobs", "x-real-ip", "127.0.0.1"},
      };
      for (String[] u : urls) {
        var hs = u.length == 3 ? headers(h(u[1], u[2])) : NONE;
        assertEquals(401, serve(routes, u[0], hs).status(), u[0]);
      }
      String token = routes.token();
      System.out.println("TOKEN " + token);
      Response page = serve(routes, "http://localhost:3000/cronwatch/", NONE);
      assertTrue(page.text().contains("sign-in link is in the server log"));
      Response api = serve(routes, "http://localhost:3000/cronwatch/api/jobs", NONE);
      assertTrue(api.text().contains("in the server log"));
      Response signIn = serve(routes, "http://localhost:3000/cronwatch/?token=" + token, NONE);
      assertEquals(303, signIn.status());
      assertEquals("/cronwatch/", signIn.header("location"));
      String setCookie = signIn.header("set-cookie");
      String cookie = setCookie.substring(0, setCookie.indexOf(';'));
      assertEquals(
          200,
          serve(routes, "http://localhost:3000/cronwatch/", headers(h("cookie", cookie))).status());
      assertEquals(
          200,
          serve(
                  routes,
                  "http://localhost:3000/cronwatch/api/jobs",
                  headers(h("authorization", "Bearer " + token)))
              .status());

      Routes other = cw.routes(RoutesOptions.builder().basePath("/").build());
      serve(other, "https://dev.example:8443/api/jobs", NONE);
    }
  }

  private static void emptyToken() {
    try (Cronwatch cw = client()) {
      assertEquals(503, jobs(cw, RoutesOptions.defaults()), "unset");
      assertEquals(503, jobs(cw, RoutesOptions.builder().token("").build()), "empty");
      assertEquals(200, jobs(cw, RoutesOptions.builder().noToken().build()), "open");
    }
  }

  private static int jobs(Cronwatch cw, RoutesOptions options) {
    return serve(cw.routes(options), "http://app.test/cronwatch/api/jobs", NONE).status();
  }

  private static void openInDevelopment() {
    try (Cronwatch cw = client()) {
      assertEquals(200, jobs(cw, RoutesOptions.builder().noToken().build()));
    }
  }

  private static void configuredInDevelopment() {
    try (Cronwatch cw = client()) {
      assertEquals(401, jobs(cw, RoutesOptions.defaults()));
      Routes routes = cw.routes(RoutesOptions.builder().token("").build());
      Response res =
          serve(
              routes,
              "http://app.test/cronwatch/api/jobs",
              headers(h("authorization", "Bearer envtok")));
      assertEquals(200, res.status(), "the environment's token");
    }
  }

  private static void signInLines() {
    String internal = "http://10.0.0.5:8080";
    var spoofed =
        headers(h("x-forwarded-proto", "https"), h("x-forwarded-host", "attacker.example"));
    try (Cronwatch cw = client()) {
      Object[][] cases = {
        {RoutesOptions.builder().origin("https://app.example.com"), internal + "/cronwatch/", NONE},
        {
          RoutesOptions.builder().origin("https://app.example.com").trustProxy(),
          internal + "/cronwatch/",
          spoofed
        },
        {RoutesOptions.builder(), "http://localhost:3000/cronwatch/", NONE},
        {RoutesOptions.builder(), "http://app.localhost:3000/cronwatch/", NONE},
        {RoutesOptions.builder(), "http://127.0.0.1:3000/cronwatch/", NONE},
        {RoutesOptions.builder(), "http://127.8.9.10/cronwatch/", NONE},
        {RoutesOptions.builder(), "http://[::1]:3000/cronwatch/", NONE},
        {
          RoutesOptions.builder().trustProxy(),
          internal + "/cronwatch/",
          headers(h("x-forwarded-host", "localhost:5173"))
        },
        {RoutesOptions.builder(), internal + "/cronwatch/", NONE},
        {RoutesOptions.builder(), "https://app.example.com/cronwatch/", NONE},
        {RoutesOptions.builder().trustProxy(), "http://localhost:3000/cronwatch/", spoofed},
        {RoutesOptions.builder(), "http://localhost.example/cronwatch/", NONE},
        {RoutesOptions.builder(), "http://128.0.0.1/cronwatch/", NONE},
        {RoutesOptions.builder().basePath("/"), "http://attacker.example/", NONE},
      };
      for (Object[] c : cases) {
        Routes routes = cw.routes(((RoutesOptions.Builder) c[0]).build());
        @SuppressWarnings("unchecked")
        List<Map.Entry<String, String>> hs = (List<Map.Entry<String, String>>) c[2];
        serve(routes, (String) c[1], hs);
        // Printed once per routes value, however many requests it answers.
        serve(routes, (String) c[1], hs);
      }
      // A Host header that is not a host is not loopback, however it ends (the Rust audit): the
      // link leaves it out.
      for (String host : List.of("evil.example/.localhost", "localhost:1@evil.example")) {
        Routes routes = cw.routes();
        routes.handle(Request.builder("GET", "/cronwatch/").header("host", host).build());
      }
    }
  }

  private static void handlerClosed() {
    AtomicInteger ran = new AtomicInteger();
    java.util.List<String> wheres = new java.util.concurrent.CopyOnWriteArrayList<>();
    java.util.List<String> messages = new java.util.concurrent.CopyOnWriteArrayList<>();
    try (Cronwatch cw =
        Cronwatch.builder()
            .cronSecret("")
            .noShutdownHook()
            .onError(
                (where, e) -> {
                  wheres.add(where);
                  messages.add(e.getMessage());
                })
            .build()) {
      Handler h =
          cw.job("closed", JobOptions.builder())
              .handler(
                  (j, r) -> {
                    ran.incrementAndGet();
                    return null;
                  });
      Response res = h.handle(Request.of("GET", "/"));
      assertEquals(503, res.status());
      assertTrue(res.text().contains("CRON_SECRET is not set"), res.text());
      assertTrue(res.text().contains("HandlerOptions.noSecret()"), res.text());
      assertEquals("application/json; charset=utf-8", res.header("content-type"));
      h.handle(Request.of("GET", "/"));
      assertEquals(0, ran.get(), "ran");
      assertEquals(List.of("handler"), wheres, "reported once");
      assertTrue(messages.get(0).contains("HandlerOptions.noSecret()"));

      // Opting out runs the job, and does not show the error to the caller.
      Handler open =
          cw.job("open", JobOptions.builder())
              .handler(
                  (j, r) -> {
                    throw new IllegalStateException("private detail");
                  },
                  HandlerOptions.builder().noSecret().build());
      Response failed = open.handle(Request.of("GET", "/"));
      assertEquals(500, failed.status());
      assertTrue(!failed.text().contains("error"), failed.text());
    }
    // A client made with noCronSecret lets anyone in.
    try (Cronwatch anyone = client()) {
      Handler h = anyone.job("any", JobOptions.builder()).handler((j, r) -> null);
      assertEquals(200, h.handle(Request.of("GET", "/")).status());
    }
  }

  private static void handlerDevelopment() {
    java.util.List<String> wheres = new java.util.concurrent.CopyOnWriteArrayList<>();
    try (Cronwatch cw =
        Cronwatch.builder()
            .cronSecret("")
            .noShutdownHook()
            .onError((where, e) -> wheres.add(where))
            .build()) {
      Handler h = cw.job("dev", JobOptions.builder()).handler((j, r) -> null);
      assertEquals(200, h.handle(Request.of("GET", "/")).status(), "development lets it run");
      assertEquals(List.of(), wheres);
    }
  }

  /**
   * The Spring starter's fallback: an environment from the app's profiles, when no variable says.
   */
  private static void profileFallback() {
    try (Cronwatch cw =
        Cronwatch.builder().noCronSecret().noShutdownHook().environment("dev").build()) {
      assertTrue(cw.routes().token() != null, "a development token from the fallback");
    }
    try (Cronwatch cw =
        Cronwatch.builder().noCronSecret().noShutdownHook().environment("prod").build()) {
      assertNull(cw.routes().token(), "locked in production");
    }
  }
}
