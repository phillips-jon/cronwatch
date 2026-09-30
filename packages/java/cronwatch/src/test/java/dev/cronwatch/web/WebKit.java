package dev.cronwatch.web;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertTrue;

import dev.cronwatch.Alert;
import dev.cronwatch.Channel;
import dev.cronwatch.ChannelContext;
import dev.cronwatch.Cronwatch;
import dev.cronwatch.JobSummary;
import dev.cronwatch.json.JsObject;
import dev.cronwatch.json.Json;
import dev.cronwatch.webtest.Golden;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.util.ArrayList;
import java.util.HexFormat;
import java.util.List;
import java.util.Map;
import java.util.concurrent.CopyOnWriteArrayList;
import java.util.concurrent.atomic.AtomicLong;
import java.util.function.Consumer;
import org.jspecify.annotations.Nullable;

/**
 * What the dashboard and handler tests share: a client on a clock the test drives, whose alerts and
 * errors are kept (the SDK tests' {@code make()}), its routes, and a way to send them a request for
 * a full URL as a server would hand it over.
 */
final class WebKit implements AutoCloseable {
  static final long T0 = Golden.T0;
  static final long MIN = 60_000;
  static final long HOUR = 3_600_000;

  static final Map.Entry<String, String> AUTH = Map.entry("authorization", "Bearer tok");
  static final Map.Entry<String, String> FORM =
      Map.entry("content-type", "application/x-www-form-urlencoded");
  static final Map.Entry<String, String> JSON = Map.entry("content-type", "application/json");

  final Cronwatch cw;
  final AtomicLong clock = new AtomicLong(T0);
  final List<Alert> alerts = new CopyOnWriteArrayList<>();
  final List<String> wheres = new CopyOnWriteArrayList<>();
  final List<String> messages = new CopyOnWriteArrayList<>();
  final Routes routes;

  WebKit() {
    this(RoutesOptions.builder().token("tok").basePath("/cronwatch").build(), b -> {});
  }

  WebKit(RoutesOptions options, Consumer<Cronwatch.Builder> more) {
    Cronwatch.Builder b =
        Cronwatch.builder()
            .clock(clock::get)
            .alert(
                new Channel() {
                  @Override
                  public String name() {
                    return "capture";
                  }

                  @Override
                  public void send(Alert alert, ChannelContext context) {
                    alerts.add(alert);
                  }
                })
            .noCronSecret()
            .noShutdownHook()
            .onError(
                (where, error) -> {
                  wheres.add(where);
                  messages.add(String.valueOf(error.getMessage()));
                });
    more.accept(b);
    cw = b.build();
    routes = cw.routes(options);
  }

  @Override
  public void close() {
    cw.close();
  }

  void advance(long ms) {
    clock.addAndGet(ms);
  }

  /** Runs a job that succeeds. */
  void ok(String name) {
    cw.run(name, job -> {});
  }

  @Nullable JobSummary summary(String name) {
    return cw.jobSummary(name);
  }

  List<String> types() {
    List<String> out = new ArrayList<>();
    for (Alert a : alerts) {
      out.add(a.type().value());
    }
    return out;
  }

  /** A request for a full URL, as a server would hand it over. */
  static Request request(
      String method, String url, List<Map.Entry<String, String>> headers, String body) {
    boolean tls = url.startsWith("https://");
    String rest = url.substring(url.indexOf("://") + 3);
    int slash = rest.indexOf('/');
    String host = slash < 0 ? rest : rest.substring(0, slash);
    String path = slash < 0 ? "/" : rest.substring(slash);
    Request.Builder b = Request.builder(method, path).header("host", host).tls(tls);
    for (Map.Entry<String, String> h : headers) {
      b.header(h.getKey(), h.getValue());
    }
    if (!body.isEmpty()) {
      b.body(body);
    }
    return b.build();
  }

  static Response serve(
      Endpoint routes,
      String method,
      String url,
      List<Map.Entry<String, String>> headers,
      String body) {
    return routes.handle(request(method, url, headers, body));
  }

  Response send(String method, String path, List<Map.Entry<String, String>> headers, String body) {
    return serve(routes, method, "http://app.test" + path, headers, body);
  }

  Response get(String path, List<Map.Entry<String, String>> headers) {
    return send("GET", path, headers, "");
  }

  @SafeVarargs
  static List<Map.Entry<String, String>> headers(Map.Entry<String, String>... pairs) {
    List<Map.Entry<String, String>> out = new ArrayList<>();
    for (Map.Entry<String, String> p : pairs) {
      out.add(p);
    }
    return out;
  }

  static Map.Entry<String, String> h(String name, String value) {
    return Map.entry(name, value);
  }

  @SafeVarargs
  static List<Map.Entry<String, String>> with(List<Map.Entry<String, String>>... sets) {
    List<Map.Entry<String, String>> out = new ArrayList<>();
    for (List<Map.Entry<String, String>> s : sets) {
      out.addAll(s);
    }
    return out;
  }

  static JsObject json(Response r) {
    Object v = Json.parse(r.text());
    assertTrue(v instanceof JsObject, "not a JSON object: " + r.text());
    return (JsObject) v;
  }

  static @Nullable Object field(JsObject o, String... path) {
    Object v = o;
    for (String key : path) {
      assertTrue(v instanceof JsObject, "no " + key + " in " + o.toJson());
      JsObject x = (JsObject) v;
      assertTrue(x.has(key), "no " + key + " in " + o.toJson());
      v = x.get(key);
    }
    return v;
  }

  static void status(String what, Response r, int want) {
    String text = r.text();
    assertEquals(want, r.status(), what + ": " + text.substring(0, Math.min(300, text.length())));
  }

  static void contains(String what, String text, String want) {
    assertTrue(
        text.contains(want),
        what + ": " + want + " is not in " + text.substring(0, Math.min(600, text.length())));
  }

  /** The cookie the routes set for the token {@code tok}. */
  static String tokenCookie() throws Exception {
    MessageDigest sha = MessageDigest.getInstance("SHA-256");
    return "cronwatch_token="
        + HexFormat.of()
            .formatHex(sha.digest("cronwatch-cookie:tok".getBytes(StandardCharsets.UTF_8)));
  }
}
