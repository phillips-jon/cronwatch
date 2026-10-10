package dev.cronwatch.webtest;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.fail;

import dev.cronwatch.Alert;
import dev.cronwatch.Channel;
import dev.cronwatch.ChannelContext;
import dev.cronwatch.Cronwatch;
import dev.cronwatch.Job;
import dev.cronwatch.JobOptions;
import dev.cronwatch.Run;
import dev.cronwatch.json.JsObject;
import dev.cronwatch.json.Json;
import dev.cronwatch.web.Request;
import java.io.IOException;
import java.io.UncheckedIOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.Base64;
import java.util.HashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.Set;
import java.util.concurrent.CopyOnWriteArrayList;
import java.util.concurrent.atomic.AtomicLong;
import java.util.regex.Matcher;
import java.util.regex.Pattern;
import org.jspecify.annotations.Nullable;

/**
 * The replay of {@code packages/ruby/test/web/golden.json}, the SDK routes' answers to a fixed seed
 * (written by {@code golden.mjs}), shared by every adapter's test: the seed step for step, the
 * captures, and the comparison of status, headers, and body byte for byte. Run ids are random on
 * both sides, so each becomes {@code <id:N>} in order of first appearance. The gem and the Python,
 * PHP, Go, Rust, and Elixir ports replay the same file.
 */
public final class Golden {
  private Golden() {}

  /** 2026-01-05 09:30:00 UTC, a Monday: golden.json's t0. */
  public static final long T0 = 1_767_605_400_000L;

  private static final long MIN = 60_000;
  private static final long HOUR = 3_600_000;
  private static final long DAY = 24 * HOUR;

  /** How many captures golden.json holds. */
  public static final int CAPTURES = 82;

  /** One capture: the request sent and the SDK's answer. */
  public record Capture(
      String method,
      String path,
      List<Map.Entry<String, String>> headers,
      @Nullable String body,
      int status,
      List<Map.Entry<String, String>> responseHeaders,
      String responseBody) {
    /** The capture's name in a failure. */
    public String label() {
      return method + " " + path;
    }
  }

  /** A seeded client, its clock, and what it reported. */
  public record Seeded(Cronwatch cw, AtomicLong clock, List<String> errors) {}

  private static List<Map.Entry<String, String>> pairs(@Nullable Object v) {
    List<Map.Entry<String, String>> out = new ArrayList<>();
    if (v instanceof JsObject o) {
      for (Map.Entry<String, @Nullable Object> e : o.entries()) {
        out.add(Map.entry(e.getKey(), String.valueOf(e.getValue())));
      }
    }
    return out;
  }

  /** The repository's root, which Surefire passes as {@code cronwatch.repo}. */
  public static Path repo() {
    String dir = System.getProperty("cronwatch.repo");
    return (dir == null ? Path.of("../../..") : Path.of(dir)).toAbsolutePath().normalize();
  }

  /** The captures, in order. */
  public static List<Capture> captures() {
    Path path = repo().resolve("packages/ruby/test/web/golden.json");
    JsObject golden;
    try {
      golden = Json.parseObject(Files.readString(path, StandardCharsets.UTF_8));
    } catch (IOException e) {
      throw new UncheckedIOException(path.toString(), e);
    }
    assertEquals((double) T0, ((Number) golden.get("t0")).doubleValue(), "golden.json's t0");
    List<Capture> out = new ArrayList<>();
    for (Object c : (List<?>) golden.get("captures")) {
      JsObject o = (JsObject) c;
      out.add(
          new Capture(
              (String) o.get("method"),
              (String) o.get("path"),
              pairs(o.get("headers")),
              o.get("body") instanceof String s ? s : null,
              ((Number) o.get("status")).intValue(),
              pairs(o.get("responseHeaders")),
              ours((String) o.get("responseBody"))));
    }
    assertEquals(CAPTURES, out.size(), "golden.json's captures");
    return out;
  }

  /**
   * A captured body with the fixture's placeholders for what {@code GET <base>/api} names filled in
   * with this port's: its library, its language, and its version.
   */
  static String ours(String body) {
    return body.replace("<library>", "dev.cronwatch:cronwatch")
        .replace("<language>", "java")
        .replace("<version>", Cronwatch.VERSION);
  }

  /** A body's function that may throw anything, as the seed's runs do. */
  @FunctionalInterface
  private interface Step {
    void run() throws Exception;
  }

  private static void quietly(Step step) {
    try {
      step.run();
    } catch (Exception e) {
      // A failed run is part of the seed.
    }
  }

  /** The seed in golden.mjs, step for step. */
  public static Seeded seed() {
    AtomicLong now = new AtomicLong(T0);
    List<String> errors = new CopyOnWriteArrayList<>();
    Channel capture =
        new Channel() {
          @Override
          public String name() {
            return "capture";
          }

          @Override
          public void send(Alert alert, ChannelContext context) {}
        };
    Cronwatch cw =
        Cronwatch.builder()
            .clock(now::get)
            .alert(capture)
            .noCronSecret()
            .noShutdownHook()
            .onError((where, error) -> errors.add(where + ": " + error.getMessage()))
            .build();
    Job nightly =
        cw.job(
            "nightly-report",
            JobOptions.builder()
                .schedule("0 2 * * *")
                .timezone("UTC")
                .grace("15m")
                .maxDuration("10m")
                .budget("cost", 2)
                .floor("rows", 40)
                .expect("Report written")
                .failuresBeforeAlert(2)
                .description("Builds the <b>PDF</b>")
                .tags("reports", "<t>"));
    long[] durations = {2000, 2500, 90_000, 3100, 1800};
    for (int i = 0; i < durations.length; i++) {
      int n = i;
      now.set(T0 - (5 - i) * DAY - 7 * HOUR - 30 * MIN);
      quietly(
          () ->
              nightly.run(
                  job -> {
                    job.log(
                        (n == 3 ? "Wrote nothing" : "Report written:") + " report-" + n + ".pdf");
                    job.metric("cost", n == 4 ? 2.5 : 1.2);
                    job.metric("rows", 40 + n);
                    job.metric("2", 0.123456);
                    now.addAndGet(durations[n]);
                  }));
    }

    // Five runs that wrote rows, then one that wrote none: under its floor.
    Job importer = cw.job("import", JobOptions.builder().schedule("0 * * * *"));
    for (int i = 0; i < 6; i++) {
      int n = i;
      now.set(T0 - (6 - i) * HOUR - 30 * MIN);
      quietly(
          () ->
              importer.run(
                  job -> {
                    job.metric("rows", n == 5 ? 0 : 120 + n);
                    now.addAndGet(800);
                  }));
    }

    Job broken = cw.job("broken", JobOptions.builder().expect("done"));
    now.set(T0 - 2 * HOUR);
    quietly(
        () ->
            broken.run(
                job -> {
                  job.log("half way <script>alert(1)</script>");
                  now.addAndGet(450);
                }));

    Job sync =
        cw.job(
            "sync-users",
            JobOptions.builder().schedule("*/15 * * * *").grace(60_000).timeout("5m"));
    now.set(T0 - 3 * HOUR);
    quietly(() -> sync.run(job -> now.addAndGet(12_345)));

    cw.job("never-ran", JobOptions.builder().schedule("0 * * * *"));

    // A run as a foreign or damaged row could hold it: started before the year 1, so the pages
    // write it in words rather than as a date.
    Job farBack = cw.job("far-back", JobOptions.builder().timeout("5m").expect("far"));
    now.set(-62_135_596_800_001L);
    quietly(() -> farBack.run(job -> now.addAndGet(1000)));

    // Cron jobs whose last run is as far off: counted from the first millisecond of the year 1, the
    // first is due then (and is missed at the check); after 9999 the other is never due again.
    Job farCronBack =
        cw.job(
            "far-cron-back",
            JobOptions.builder().schedule("0 2 * * *").timezone("UTC").grace("10m"));
    now.set(-62_135_596_800_001L);
    farCronBack.run(job -> now.addAndGet(1000));
    Job farCronAhead =
        cw.job(
            "far-cron-ahead",
            JobOptions.builder().schedule("0 2 * * *").timezone("UTC").grace("10m"));
    now.set(253_402_300_800_000L);
    farCronAhead.run(job -> now.addAndGet(1000));
    now.set(T0);
    return new Seeded(cw, now, errors);
  }

  private static final Pattern RUN = Pattern.compile("\\{run:([^:}]+):(\\d+)}");

  /** The path with the id of the Nth newest run of a job where it says {@code {run:JOB:N}}. */
  public static String resolve(Cronwatch cw, String path) {
    Matcher m = RUN.matcher(path);
    if (!m.find()) {
      return path;
    }
    List<Run> runs = cw.runs(m.group(1), 50);
    return path.substring(0, m.start())
        + runs.get(Integer.parseInt(m.group(2))).id()
        + path.substring(m.end());
  }

  private static final Pattern UUID =
      Pattern.compile("[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}");

  /** Numbers run ids in order of first appearance, as golden.mjs does. */
  public static final class Ids {
    private final Map<String, String> seen = new HashMap<>();

    /** No ids seen yet. */
    public Ids() {}

    /** The text with each id replaced. */
    public String replace(String text) {
      Matcher m = UUID.matcher(text);
      StringBuilder out = new StringBuilder();
      while (m.find()) {
        String id = m.group();
        String n = seen.computeIfAbsent(id, k -> "<id:" + seen.size() + ">");
        m.appendReplacement(out, Matcher.quoteReplacement(n));
      }
      m.appendTail(out);
      return out.toString();
    }
  }

  /** Headers every server adds of its own, left out of the comparison through one. */
  public static final Set<String> SERVER_HEADERS =
      Set.of("content-length", "date", "transfer-encoding", "keep-alive", "connection");

  /**
   * Checks one answer against its capture: the status, every header but those in {@code ignored}
   * and {@code content-length} (the SDK leaves it to the server in front), and the body byte for
   * byte.
   */
  public static void compare(
      Capture c,
      int status,
      List<Map.Entry<String, String>> headers,
      byte[] body,
      Ids ids,
      Set<String> ignored) {
    compare(c, status, headers, body, ids, ignored, false);
  }

  /** A media type as a servlet container writes it back: no space after its {@code ;}. */
  private static String packed(String type) {
    return type.replace("; ", ";");
  }

  /**
   * {@link #compare}, with {@code packedTypes} for a servlet container, which writes {@code
   * content-type} back without the space after its {@code ;} ({@code text/html;charset=utf-8}, the
   * same media type), as Tomcat and Jetty both do.
   */
  public static void compare(
      Capture c,
      int status,
      List<Map.Entry<String, String>> headers,
      byte[] body,
      Ids ids,
      Set<String> ignored,
      boolean packedTypes) {
    String label = c.label();
    Map<String, String> got = new HashMap<>();
    for (Map.Entry<String, String> h : headers) {
      String name = h.getKey().toLowerCase(Locale.ROOT);
      if (name.equals("content-length") || ignored.contains(name)) {
        continue;
      }
      got.merge(name, h.getValue(), (a, b) -> a + ", " + b);
    }
    String text =
        "image/png".equals(got.get("content-type"))
            ? "base64:" + Base64.getEncoder().encodeToString(body)
            : ids.replace(new String(body, StandardCharsets.UTF_8));
    assertEquals(c.status(), status, label + ": status");
    Map<String, String> want = new HashMap<>();
    for (Map.Entry<String, String> h : c.responseHeaders()) {
      want.put(h.getKey(), h.getValue());
    }
    if (packedTypes) {
      want.computeIfPresent("content-type", (k, v) -> packed(v));
      got.computeIfPresent("content-type", (k, v) -> packed(v));
    }
    assertEquals(want, got, label + ": headers");
    if (!text.equals(c.responseBody())) {
      String w = c.responseBody();
      int at = 0;
      while (at < text.length() && at < w.length() && text.charAt(at) == w.charAt(at)) {
        at++;
      }
      int from = Math.max(0, at - 120);
      fail(
          label
              + ": the body differs at "
              + at
              + ":\n got "
              + text.substring(from, Math.min(text.length(), at + 200))
              + "\nwant "
              + w.substring(from, Math.min(w.length(), at + 200)));
    }
  }

  /** The capture as a {@link Request} for {@code path}, from {@code app.test}. */
  public static Request request(Capture c, String path) {
    Request.Builder b = Request.builder(c.method(), path).header("host", "app.test");
    for (Map.Entry<String, String> h : c.headers()) {
      b.header(h.getKey(), h.getValue());
    }
    if (c.body() != null) {
      b.body(c.body());
    }
    return b.build();
  }

  /** The capture's body as bytes, or null. */
  public static byte @Nullable [] body(Capture c) {
    return c.body() == null ? null : c.body().getBytes(StandardCharsets.UTF_8);
  }

  /** The captures whose request target is not a valid URI, which a strict server refuses. */
  public static final Set<String> MALFORMED_TARGETS =
      Set.of("/cronwatch/jobs/%zz", "/cronwatch/api/jobs/%zz");

  /**
   * Replays every capture through a server on {@code port} with the dashboard at {@code
   * /cronwatch}, ignoring what that server adds of its own. A capture whose path is in {@code
   * refused} must be refused by the server itself with a 400, since it never reaches the routes;
   * answers how many captures matched.
   */
  public static int throughServer(Seeded seeded, int port, Set<String> ignored, Set<String> refused)
      throws IOException {
    return throughServer(seeded, port, ignored, refused, false);
  }

  /** {@link #throughServer}, with {@code packedTypes} for a servlet container (see compare). */
  public static int throughServer(
      Seeded seeded, int port, Set<String> ignored, Set<String> refused, boolean packedTypes)
      throws IOException {
    Ids ids = new Ids();
    int matched = 0;
    for (Capture c : captures()) {
      String path = resolve(seeded.cw(), c.path());
      RawHttp.Answer a = RawHttp.send(port, c.method(), path, c.headers(), body(c));
      if (refused.contains(c.path())) {
        assertEquals(400, a.status(), c.label() + ": refused by the server");
        continue;
      }
      compare(c, a.status(), a.headers(), a.body(), ids, ignored, packedTypes);
      matched++;
    }
    assertEquals(List.of(), seeded.errors(), "errors reported");
    return matched;
  }
}
