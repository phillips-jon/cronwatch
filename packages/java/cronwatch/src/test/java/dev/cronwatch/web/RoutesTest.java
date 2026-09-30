package dev.cronwatch.web;

import static dev.cronwatch.web.WebKit.AUTH;
import static dev.cronwatch.web.WebKit.FORM;
import static dev.cronwatch.web.WebKit.HOUR;
import static dev.cronwatch.web.WebKit.JSON;
import static dev.cronwatch.web.WebKit.MIN;
import static dev.cronwatch.web.WebKit.T0;
import static dev.cronwatch.web.WebKit.contains;
import static dev.cronwatch.web.WebKit.field;
import static dev.cronwatch.web.WebKit.h;
import static dev.cronwatch.web.WebKit.headers;
import static dev.cronwatch.web.WebKit.json;
import static dev.cronwatch.web.WebKit.serve;
import static dev.cronwatch.web.WebKit.status;
import static dev.cronwatch.web.WebKit.tokenCookie;
import static dev.cronwatch.web.WebKit.with;
import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertNotNull;
import static org.junit.jupiter.api.Assertions.assertNull;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;

import dev.cronwatch.Cronwatch;
import dev.cronwatch.CronwatchException;
import dev.cronwatch.Definition;
import dev.cronwatch.Job;
import dev.cronwatch.JobHealth;
import dev.cronwatch.JobOptions;
import dev.cronwatch.JobState;
import dev.cronwatch.Run;
import dev.cronwatch.StoredJob;
import dev.cronwatch.json.JsObject;
import dev.cronwatch.store.MemoryStore;
import dev.cronwatch.store.Store;
import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.atomic.AtomicInteger;
import org.jspecify.annotations.Nullable;
import org.junit.jupiter.api.Test;

/**
 * The SDK's routes tests ({@code routes.test.ts}, {@code routes-security.test.ts}, {@code
 * routes-origin.test.ts}, {@code routes-pwa.test.ts} in part), as the Go, Rust and Elixir ports
 * have them, with their audits' cases: the body cap, a body cut short, a body nested deeply, a long
 * host outside ASCII, huge durations, and the base path from the mount. What needs an environment
 * of its own (locked, the development token) is in {@link RoutesEnvTest}.
 */
class RoutesTest {
  private static final List<Map.Entry<String, String>> NONE = List.of();

  @Test
  void everythingNeedsTheToken() {
    try (WebKit w = new WebKit()) {
      status("page", w.get("/cronwatch", NONE), 401);
      status("api", w.get("/cronwatch/api/jobs", NONE), 401);
      status(
          "wrong", w.get("/cronwatch/api/jobs", headers(h("authorization", "Bearer wrong"))), 401);
      status("right", w.get("/cronwatch/api/jobs", headers(AUTH)), 200);
      status(
          "any case and spaces",
          w.get("/cronwatch/api/jobs", headers(h("authorization", "bEaReR \t tok"))),
          200);
      assertEquals("tok", w.routes.token());
    }
  }

  @Test
  void checkAcceptsTheCronSecretAndNothingElseDoes() {
    String secret = "cron-" + "s3cret";
    try (WebKit w =
        new WebKit(RoutesOptions.builder().token("tok").build(), b -> b.cronSecret(secret))) {
      var bearer = headers(h("authorization", "Bearer " + secret));
      status("check", w.get("/cronwatch/api/check", bearer), 200);
      status("jobs", w.get("/cronwatch/api/jobs", bearer), 401);
      status("only as a bearer", w.get("/cronwatch/api/check?token=" + secret, NONE), 401);
    }
  }

  @Test
  void signInSetsACookieAndRedirectsToACleanUrl() throws Exception {
    try (WebKit w = new WebKit()) {
      String cookie = tokenCookie();
      Response res = w.get("/cronwatch/?token=tok", NONE);
      status("sign-in", res, 303);
      assertEquals("/cronwatch/", res.header("location"));
      String set = res.header("set-cookie");
      assertNotNull(set);
      assertEquals(cookie, set.substring(0, set.indexOf(";")), "a digest, not the token");
      contains("cookie", set, "; Path=/cronwatch; HttpOnly; SameSite=Lax; Max-Age=2592000");
      Response page = w.get("/cronwatch/", headers(h("cookie", "other=1; " + cookie)));
      status("with the cookie", page, 200);
      contains("type", page.header("content-type"), "text/html");
      status(
          "the raw token is not a cookie",
          w.get("/cronwatch/", headers(h("cookie", "cronwatch_token=tok"))),
          401);
      // HTTP/2 may send each cookie as a header of its own.
      status(
          "split cookies",
          w.get("/cronwatch/", headers(h("cookie", "other=1"), h("cookie", cookie))),
          200);
      Response other = w.get("/cronwatch/jobs/x?view=all&token=tok&a=b+c", NONE);
      assertEquals(
          "/cronwatch/jobs/x?view=all&a=b+c",
          other.header("location"),
          "the rest of the query is kept");
    }
  }

  @Test
  void pagesRenderAndTheApiAnswers() {
    try (WebKit w = new WebKit()) {
      Job job =
          w.cw.job(
              "nightly-report",
              JobOptions.builder().schedule("0 2 * * *").description("Builds the PDF"));
      job.run(
          j -> {
            j.log("built");
            w.advance(2000);
          });
      assertThrows(
          IllegalStateException.class,
          () ->
              w.cw.run(
                  "broken",
                  j -> {
                    throw new IllegalStateException("kaboom <script>");
                  }));

      String dash = w.get("/cronwatch", headers(AUTH)).text();
      for (String want :
          List.of(
              "nightly-report",
              "Builds the PDF",
              "healthy",
              "failing",
              "<p class=\"headline\">2 jobs, <b>1 needing attention</b>.</p>",
              "<div class=\"bad\"><dt><i class=\"sq bad\""
                  + " aria-hidden=\"true\"></i>failing</dt><dd>1</dd></div>",
              "<figure class=\"timeline day\">",
              "<table class=\"board\">",
              "<form class=\"inline\" method=\"post\" action=\"/cronwatch/check\"><button"
                  + " class=\"primary\" type=\"submit\">Run check now</button></form>")) {
        contains("dashboard", dash, want);
      }
      Response page = w.get("/cronwatch/jobs/broken", headers(AUTH));
      status("job page", page, 200);
      String html = page.text();
      contains("escaped", html, "kaboom &lt;script&gt;");
      assertFalse(html.contains("<script>"), "an unescaped <script>");
      contains("heading", html, "<h1 class=\"jobname\">broken</h1>");
      contains("week", html, "<figure class=\"timeline week\">");
      contains(
          "error",
          html,
          "<details class=\"out error\" open><summary>error</summary><pre>IllegalStateException:"
              + " kaboom &lt;script&gt;");

      JsObject list = json(w.get("/cronwatch/api/jobs", headers(AUTH)));
      assertEquals(2, ((List<?>) field(list, "jobs")).size());
      JsObject one = json(w.get("/cronwatch/api/jobs/nightly-report?runs=5", headers(AUTH)));
      assertEquals("healthy", field(one, "job", "health"));
      List<?> runs = (List<?>) field(one, "runs");
      assertEquals(1, runs.size());
      assertEquals("built", ((JsObject) runs.get(0)).get("output"));
      status("api missing", w.get("/cronwatch/api/jobs/missing", headers(AUTH)), 404);
      status("page missing", w.get("/cronwatch/jobs/missing", headers(AUTH)), 404);
      status("nope", w.get("/cronwatch/nope", headers(AUTH)), 404);
      String runId = (String) ((JsObject) runs.get(0)).get("id");
      JsObject run = json(w.get("/cronwatch/api/runs/" + runId, headers(AUTH)));
      assertEquals("nightly-report", field(run, "run", "job"));
    }
  }

  @Test
  void namesBreakAfterTheirSeparatorsOnlyAsText() {
    try (WebKit w = new WebKit()) {
      String name = "wp:store_sync.inventory--eu";
      w.ok(name);
      String shown = "wp:<wbr>store_<wbr>sync.<wbr>inventory--<wbr>eu";
      String href = "/cronwatch/jobs/wp%3Astore_sync.inventory--eu";
      String dash = w.get("/cronwatch", headers(AUTH)).text();
      contains(
          "the lane",
          dash,
          "<a class=\"name\" href=\"" + href + "\">" + shown + "</a><span class=\"sched\">");
      contains(
          "the board",
          dash,
          "<td class=\"job\"><a class=\"name\" href=\"" + href + "\">" + shown + "</a></td>");
      contains("the words", dash, "<li>wp:store_sync.inventory--eu (");
      String page = w.get(href, headers(AUTH)).text();
      contains("crumb", page, "<span class=\"crumb\">" + shown + "</span>");
      contains("heading", page, "<h1 class=\"jobname\">" + shown + "</h1>");
      contains("title", page, "<title>wp:store_sync.inventory--eu: CronWatch</title>");
      contains("marks", page, "<title>wp:store_sync.inventory--eu, ");
      assertEquals(8, page.split("<wbr>", -1).length - 1, "only in the crumb and the heading");
    }
  }

  @Test
  void apiWrites() {
    try (WebKit w = new WebKit()) {
      w.ok("s");
      JsObject result = json(w.send("POST", "/cronwatch/api/check", headers(AUTH, JSON), ""));
      assertEquals(true, field(result, "ok"));
      assertEquals(1, ((List<?>) field(result, "jobs")).size());
      JsObject silenced =
          json(
              w.send(
                  "POST",
                  "/cronwatch/api/jobs/s/silence",
                  headers(AUTH, JSON),
                  "{\"for\":\"2h\"}"));
      assertEquals((double) (T0 + 2 * HOUR), field(silenced, "state", "silencedUntil"));
      assertEquals(JobHealth.SILENCED, w.summary("s").health());
      JsObject un =
          json(w.send("POST", "/cronwatch/api/jobs/s/unsilence", headers(AUTH, JSON), ""));
      assertNull(field(un, "state", "silencedUntil"));
      status(
          "ghost",
          w.send(
              "POST", "/cronwatch/api/jobs/nope/silence", headers(AUTH, JSON), "{\"for\":\"1h\"}"),
          404);
      status("delete", w.send("DELETE", "/cronwatch/api/jobs/s", headers(AUTH), ""), 200);
      assertNull(w.summary("s"), "the job was not forgotten");
      status("delete again", w.send("DELETE", "/cronwatch/api/jobs/s", headers(AUTH), ""), 404);
    }
  }

  @Test
  void formsPostAndRedirectBack() {
    try (WebKit w = new WebKit()) {
      w.ok("f");
      Response res =
          w.send(
              "POST",
              "/cronwatch/jobs/f/silence",
              headers(AUTH, FORM, h("referer", "http://app.test/cronwatch/jobs/f")),
              "for=4h");
      status("silence", res, 303);
      assertEquals("http://app.test/cronwatch/jobs/f", res.header("location"));
      assertEquals(JobHealth.SILENCED, w.summary("f").health());
      Response elsewhere =
          w.send(
              "POST",
              "/cronwatch/jobs/f/unsilence",
              headers(AUTH, h("referer", "https://evil.example/phish")),
              "");
      assertEquals(
          "/cronwatch/", elsewhere.header("location"), "a foreign referer is not followed");
      String multipart =
          "--b\r\nContent-Disposition: form-data; name=\"for\"\r\n\r\n2h\r\n--b--\r\n";
      res =
          w.send(
              "POST",
              "/cronwatch/jobs/f/silence",
              headers(AUTH, h("content-type", "multipart/form-data; boundary=b")),
              multipart);
      status("multipart", res, 303);
      assertEquals(T0 + 2 * HOUR, w.summary("f").silencedUntil(), "silenced for two hours");
      status("forget", w.send("POST", "/cronwatch/jobs/f/forget", headers(AUTH), ""), 303);
      assertNull(w.summary("f"), "the job was not forgotten");
    }
  }

  @Test
  void crossSiteWritesAreRefused() throws Exception {
    try (WebKit w = new WebKit()) {
      w.ok("x");
      var cookie = h("cookie", tokenCookie());
      for (var hs :
          List.of(
              headers(h("origin", "https://evil.example")),
              headers(h("origin", "null")),
              headers(h("sec-fetch-site", "cross-site")),
              headers(h("sec-fetch-site", "same-site")),
              headers(h("origin", "http://app.test"), h("sec-fetch-site", "cross-site")))) {
        status(
            "form",
            w.send("POST", "/cronwatch/jobs/x/silence", with(headers(cookie, FORM), hs), "for=1h"),
            403);
        status("check", w.send("POST", "/cronwatch/api/check", with(headers(AUTH), hs), ""), 403);
        status(
            "delete",
            w.send("DELETE", "/cronwatch/api/jobs/x", with(headers(cookie), hs), ""),
            403);
      }
      assertNull(w.summary("x").silencedUntil(), "a cross-site write went through");
      var same =
          headers(
              h("origin", "http://app.test"),
              h("sec-fetch-site", "same-origin"),
              h("referer", "http://app.test/cronwatch/jobs/x"));
      status(
          "run check now",
          w.send("POST", "/cronwatch/check", with(headers(cookie), same), ""),
          303);
      status(
          "api client", w.send("POST", "/cronwatch/api/jobs/x/unsilence", headers(AUTH), ""), 200);
      status(
          "none",
          w.send("POST", "/cronwatch/api/check", headers(AUTH, h("sec-fetch-site", "none")), ""),
          200);
      Response refused =
          w.send(
              "POST",
              "/cronwatch/api/check",
              headers(AUTH, h("origin", "https://evil.example")),
              "");
      assertEquals("{\"ok\":false,\"error\":\"Cross-site request refused\"}", refused.text());
    }
  }

  @Test
  void getCheckNeedsABearerAndQueryTokensOnlySignIn() throws Exception {
    try (WebKit w = new WebKit()) {
      w.ok("x");
      var cookie = h("cookie", tokenCookie());
      Response viaCookie = w.get("/cronwatch/api/check", headers(cookie));
      status("cookie GET", viaCookie, 405);
      assertEquals("POST", viaCookie.header("allow"));
      status("cookie POST", w.send("POST", "/cronwatch/api/check", headers(cookie), ""), 200);
      status("bearer GET", w.get("/cronwatch/api/check", headers(AUTH)), 200);
      status("api", w.get("/cronwatch/api/jobs?token=tok", NONE), 401);
      status("api job", w.get("/cronwatch/api/jobs/x?token=tok", NONE), 401);
      status("api check", w.send("POST", "/cronwatch/api/check?token=tok", NONE, ""), 401);
      status("check", w.send("POST", "/cronwatch/check?token=tok", NONE, ""), 401);
      status("forget", w.send("POST", "/cronwatch/jobs/x/forget?token=tok", NONE, ""), 401);
      assertNotNull(w.summary("x"), "forgotten by a query token");
      status("page", w.get("/cronwatch/jobs/x?token=tok", NONE), 303);
    }
  }

  @Test
  void malformedCookiesAndPathsAreAnswered() {
    try (WebKit w = new WebKit()) {
      status("cookie", w.get("/cronwatch/", headers(h("cookie", "cronwatch_token=%E0%A4%A"))), 401);
      status(
          "cookie %", w.get("/cronwatch/api/jobs", headers(h("cookie", "cronwatch_token=%"))), 401);
      status("path", w.get("/cronwatch/jobs/%E0%A4%A", headers(AUTH)), 400);
      Response api = w.get("/cronwatch/api/jobs/%zz", headers(AUTH));
      status("api path", api, 400);
      assertEquals(false, json(api).get("ok"));
      status(
          "api silence", w.send("POST", "/cronwatch/api/jobs/%zz/silence", headers(AUTH), ""), 400);
      status("not UTF-8", w.get("/cronwatch/jobs/%E9", headers(AUTH)), 400);
    }
  }

  @Test
  void runsIsClamped() {
    try (WebKit w = new WebKit()) {
      for (int i = 0; i < 3; i++) {
        w.ok("r");
        w.advance(1000);
      }
      Object[][] cases = {
        {"0", 1},
        {"-5", 1},
        {"2.7", 2},
        {"abc", 3},
        {"", 3},
        {"1e9", 3},
        {"Infinity", 3},
        {"0x2", 2},
        {"%202%20", 2}
      };
      for (Object[] c : cases) {
        JsObject res = json(w.get("/cronwatch/api/jobs/r?runs=" + c[0], headers(AUTH)));
        assertEquals(c[1], ((List<?>) field(res, "runs")).size(), "runs=" + c[0]);
      }
    }
  }

  /** A memory store whose named methods throw. */
  static final class Breakable implements Store {
    final Store inner = new MemoryStore();
    final Set<String> broken = ConcurrentHashMap.newKeySet();
    final AtomicInteger listJobsCalls = new AtomicInteger();

    private void check(String method) {
      if (broken.contains(method)) {
        throw new IllegalStateException(method + " failed");
      }
    }

    @Override
    public void init() throws Exception {
      inner.init();
    }

    @Override
    public void upsertJob(Definition definition, long now) throws Exception {
      inner.upsertJob(definition, now);
    }

    @Override
    public @Nullable StoredJob getJob(String name) throws Exception {
      return inner.getJob(name);
    }

    @Override
    public List<StoredJob> listJobs() throws Exception {
      listJobsCalls.incrementAndGet();
      check("listJobs");
      return inner.listJobs();
    }

    @Override
    public void deleteJob(String name) throws Exception {
      inner.deleteJob(name);
    }

    @Override
    public void insertRun(Run run) throws Exception {
      inner.insertRun(run);
    }

    @Override
    public void updateRun(Run run) throws Exception {
      inner.updateRun(run);
    }

    @Override
    public @Nullable Run getRun(String id) throws Exception {
      return inner.getRun(id);
    }

    @Override
    public List<Run> listRuns(String job, int limit) throws Exception {
      return inner.listRuns(job, limit);
    }

    @Override
    public List<Run> runningRuns() throws Exception {
      return inner.runningRuns();
    }

    @Override
    public @Nullable JobState getState(String job) throws Exception {
      return inner.getState(job);
    }

    @Override
    public void setState(JobState state) throws Exception {
      inner.setState(state);
    }

    @Override
    public long prune(long before) throws Exception {
      return inner.prune(before);
    }
  }

  @Test
  void anUnexpectedErrorIsAGeneric500() {
    Breakable store = new Breakable();
    try (WebKit w = new WebKit(RoutesOptions.builder().token("tok").build(), b -> b.store(store))) {
      store.broken.add("listJobs");
      Response api = w.get("/cronwatch/api/jobs", headers(AUTH));
      status("api", api, 500);
      assertEquals("{\"ok\":false,\"error\":\"Internal error\"}", api.text());
      Response page = w.get("/cronwatch/", headers(AUTH));
      status("page", page, 500);
      contains("type", page.header("content-type"), "text/html");
      assertFalse(page.text().contains("listJobs failed"), "the error reached the page");
      assertEquals(List.of("routes", "routes"), w.wheres);
      assertEquals(List.of("listJobs failed", "listJobs failed"), w.messages);
    }
    try (Cronwatch throwing =
        Cronwatch.builder()
            .store(store)
            .noCronSecret()
            .noShutdownHook()
            .onError(
                (where, error) -> {
                  throw new IllegalStateException("logger down");
                })
            .build()) {
      Routes routes = throwing.routes(RoutesOptions.builder().token("tok").build());
      status(
          "a throwing error handler",
          serve(routes, "GET", "http://app.test/cronwatch/api/jobs", headers(AUTH), ""),
          500);
    }
  }

  // The Rust audit: a body nested a few thousand arrays deep overflowed a thread's stack. The JSON
  // reader refuses nesting past 256, so the body reads as none and the silence is the default hour.
  @Test
  void aBodyNestedDeeplyIsReadAsNone() throws Exception {
    try (WebKit w = new WebKit()) {
      w.ok("s");
      String body = "[".repeat(100_000) + "]".repeat(100_000);
      // On a virtual thread, whose stack is small until it grows.
      Response[] res = new Response[1];
      Thread t =
          Thread.ofVirtual()
              .start(
                  () ->
                      res[0] =
                          w.send(
                              "POST", "/cronwatch/api/jobs/s/silence", headers(AUTH, JSON), body));
      t.join();
      status("deep", res[0], 200);
      assertEquals(T0 + HOUR, w.summary("s").silencedUntil(), "the default hour");
    }
  }

  @Test
  void silenceDurations() {
    try (WebKit w = new WebKit()) {
      w.ok("s");
      for (String bad :
          List.of("\"forever\"", "\"2 hours\"", "\"\"", "\"-5\"", "\"1h then some\"", "true")) {
        Response res =
            w.send(
                "POST",
                "/cronwatch/api/jobs/s/silence",
                headers(AUTH, JSON),
                "{\"for\":" + bad + "}");
        status(bad, res, 400);
        contains(bad, (String) field(json(res), "error"), "silence duration");
      }
      assertNull(w.summary("s").silencedUntil(), "a bad duration silenced the job");
      assertEquals(7_200_000, until(w, "{\"for\":7200000}"), "a number");
      assertEquals(60_000, until(w, "{\"for\":\"60000\"}"), "a numeric string");
      assertEquals(90 * MIN, until(w, "{\"for\":\"90m\"}"), "text");
      assertEquals(HOUR, until(w, "{}"), "absent");
      assertEquals(2 * HOUR, until(w, "﻿{\"for\":\"2h\"}"), "a byte order mark");
      // The SDK's 64-character cap: longer text is refused before it is read, quoting its start.
      Response longText =
          w.send(
              "POST",
              "/cronwatch/api/jobs/s/silence",
              headers(AUTH, JSON),
              "{\"for\":\"" + "1".repeat(65) + "h\"}");
      status("65 characters", longText, 400);
      contains("65 characters", (String) field(json(longText), "error"), "silence duration");
      status(
          "query",
          w.send("POST", "/cronwatch/api/jobs/s/silence?for=forever", headers(AUTH), ""),
          400);
      JsObject query =
          json(w.send("POST", "/cronwatch/api/jobs/s/silence?for=3h", headers(AUTH), ""));
      assertEquals(
          (double) (T0 + 3 * HOUR),
          field(query, "state", "silencedUntil"),
          "the query when the body has none");
    }
  }

  private static long until(WebKit w, String body) {
    JsObject r = json(w.send("POST", "/cronwatch/api/jobs/s/silence", headers(AUTH, JSON), body));
    return ((Number) field(r, "state", "silencedUntil")).longValue() - T0;
  }

  // The Go audit: a body cut short was read as far as it came, so "for=7d" silenced the job for
  // 7 ms. The SDK reads a body it cannot read as none.
  @Test
  void aBodyCutShortIsNone() {
    try (WebKit w = new WebKit()) {
      w.ok("s");
      Request req =
          Request.builder("POST", "/cronwatch/api/jobs/s/silence")
              .header("host", "app.test")
              .header("authorization", "Bearer tok")
              .header("content-type", "application/x-www-form-urlencoded")
              .body(
                  6,
                  limit -> {
                    throw new IOException("the client went away after for=7");
                  })
              .build();
      status("silenced", w.routes.handle(req), 200);
      assertEquals(T0 + HOUR, w.summary("s").silencedUntil(), "the default hour");
      assertEquals(List.of(), w.wheres, "nothing reported");
    }
  }

  @Test
  void theSilenceFormShowsAnError() throws Exception {
    try (WebKit w = new WebKit()) {
      w.ok("s");
      var f = headers(h("cookie", tokenCookie()), FORM);
      Response bad = w.send("POST", "/cronwatch/jobs/s/silence", f, "for=forever");
      status("bad", bad, 400);
      contains("type", bad.header("content-type"), "text/html");
      contains("message", bad.text(), "silence duration &quot;forever&quot;");
      status("ghost", w.send("POST", "/cronwatch/jobs/ghost/silence", f, "for=1h"), 404);
      status("ghost unsilence", w.send("POST", "/cronwatch/jobs/ghost/unsilence", f, ""), 404);
      status("explode", w.send("POST", "/cronwatch/jobs/s/explode", f, ""), 404);
    }
  }

  @Test
  void aBodyPastTheCapIs413() {
    try (WebKit w = new WebKit()) {
      w.ok("s");
      String big = "{\"for\":\"2h\",\"pad\":\"" + "x".repeat(Request.MAX_BODY) + "\"}";
      Response api = w.send("POST", "/cronwatch/api/jobs/s/silence", headers(AUTH, JSON), big);
      status("api", api, 413);
      assertEquals("{\"ok\":false,\"error\":\"Request body too large\"}", api.text());
      Response page =
          w.send(
              "POST",
              "/cronwatch/jobs/s/silence",
              headers(AUTH, FORM),
              "for=2h&pad=" + "x".repeat(Request.MAX_BODY));
      status("form", page, 413);
      contains("form body", page.text(), "The request was too large.");
      // Without a length, by reading one byte past the cap.
      byte[] data = big.getBytes(StandardCharsets.UTF_8);
      Request chunked =
          Request.builder("POST", "/cronwatch/api/jobs/s/silence")
              .header("host", "app.test")
              .header("authorization", "Bearer tok")
              .header("content-type", "application/json")
              .body(-1, limit -> java.util.Arrays.copyOf(data, Math.min(data.length, limit + 1)))
              .build();
      status("chunked", w.routes.handle(chunked), 413);
      // A body of exactly the cap is read.
      String exact = "for=2h&pad=";
      exact += "x".repeat(Request.MAX_BODY - exact.length());
      status(
          "exactly the cap",
          w.send("POST", "/cronwatch/api/jobs/s/silence", headers(AUTH, FORM), exact),
          200);
      w.cw.unsilence("s");
      // Refused before the body is read: no token, no read.
      AtomicInteger read = new AtomicInteger();
      Request noToken =
          Request.builder("POST", "/cronwatch/api/jobs/s/silence")
              .header("host", "app.test")
              .header("content-type", "application/json")
              .body(
                  -1,
                  limit -> {
                    read.incrementAndGet();
                    return new byte[0];
                  })
              .build();
      status("no token", w.routes.handle(noToken), 401);
      assertEquals(0, read.get(), "a body was read without the token");
    }
  }

  @Test
  void securityHeaders() {
    try (WebKit w = new WebKit()) {
      w.ok("h");
      for (String path : List.of("/cronwatch/", "/cronwatch/jobs/h", "/cronwatch/nope")) {
        Response res = w.get(path, headers(AUTH));
        assertEquals(
            "default-src 'none'; script-src 'self'; style-src 'unsafe-inline'; img-src 'self'"
                + " data:; manifest-src 'self'; worker-src 'self'; form-action 'self';"
                + " frame-ancestors 'none'; base-uri 'none'",
            res.header("content-security-policy"));
        assertEquals("DENY", res.header("x-frame-options"));
        assertEquals("nosniff", res.header("x-content-type-options"));
        assertEquals("same-origin", res.header("referrer-policy"));
        assertEquals("no-store", res.header("cache-control"));
        String text = res.text();
        int scripts = text.split("<script", -1).length - 1;
        assertEquals(1, scripts, path + ": one script");
        contains(path, text, "<script src=\"/cronwatch/app.js\" defer></script>");
      }
      Response api = w.get("/cronwatch/api/jobs", headers(AUTH));
      assertEquals("nosniff", api.header("x-content-type-options"));
      assertEquals("no-store", api.header("cache-control"));
    }
  }

  @Test
  void markupStaysEscaped() {
    try (WebKit w = new WebKit()) {
      Job job =
          w.cw.job(
              "m",
              JobOptions.builder()
                  .schedule("0 2 * * *")
                  .description("<img src=x>")
                  .tags("<t>")
                  .expect("<e>"));
      try {
        job.run(
            j -> {
              j.log("<o>");
              j.metric("<k>", 1);
            });
      } catch (RuntimeException e) {
        // The expect rule fails it; that is not what this test is about.
      }
      for (String path : List.of("/cronwatch/", "/cronwatch/jobs/m", "/cronwatch/jobs/%3Cx%3E")) {
        String text = w.get(path, headers(AUTH)).text();
        for (String bad : List.of("<img", "<t>", "<e>", "<o>", "<k>", "<x>")) {
          assertFalse(text.contains(bad), path + ": " + bad + " unescaped");
        }
      }
    }
  }

  private static final String INTERNAL = "http://10.0.0.5:8080";

  private static Response send(
      WebKit w, String method, String path, List<Map.Entry<String, String>> hs, String body)
      throws Exception {
    return serve(
        w.routes, method, INTERNAL + path, with(hs, headers(h("cookie", tokenCookie()))), body);
  }

  private static WebKit app(RoutesOptions.Builder options) {
    WebKit w = new WebKit(options.token("tok").basePath("/cronwatch").build(), b -> {});
    w.ok("x");
    return w;
  }

  @Test
  void origins() throws Exception {
    // The request's own origin by default.
    try (WebKit w = app(RoutesOptions.builder())) {
      status(
          "foreign",
          send(
              w,
              "POST",
              "/cronwatch/jobs/x/silence",
              headers(FORM, h("origin", "https://app.example.com")),
              "for=1h"),
          403);
      assertNull(w.summary("x").silencedUntil());
      status(
          "own",
          send(
              w,
              "POST",
              "/cronwatch/jobs/x/silence",
              headers(FORM, h("origin", INTERNAL)),
              "for=1h"),
          303);
      Response set = send(w, "GET", "/cronwatch/?token=tok", NONE, "");
      assertFalse(set.header("set-cookie").contains("Secure"), "Secure over http");
    }

    // The origin option replaces it.
    try (WebKit w = app(RoutesOptions.builder().origin("https://app.example.com/ignored/path"))) {
      status(
          "internal",
          send(
              w,
              "POST",
              "/cronwatch/jobs/x/silence",
              headers(FORM, h("origin", INTERNAL)),
              "for=1h"),
          403);
      assertNull(w.summary("x").silencedUntil());
      String referer = "https://app.example.com/cronwatch/jobs/x";
      Response res =
          send(
              w,
              "POST",
              "/cronwatch/jobs/x/silence",
              headers(FORM, h("origin", "https://app.example.com"), h("referer", referer)),
              "for=2h");
      status("public", res, 303);
      assertEquals(referer, res.header("location"));
      assertEquals(T0 + 2 * HOUR, w.summary("x").silencedUntil());
      Response signIn = send(w, "GET", "/cronwatch/jobs/x?token=tok", NONE, "");
      assertEquals("/cronwatch/jobs/x", signIn.header("location"));
      assertTrue(signIn.header("set-cookie").endsWith("; Secure"), "not Secure over https");
    }

    // The origin option wins over trustProxy.
    try (WebKit w = app(RoutesOptions.builder().origin("https://app.example.com").trustProxy())) {
      var fwd = headers(h("x-forwarded-proto", "https"), h("x-forwarded-host", "other.example"));
      status(
          "forwarded",
          send(
              w,
              "POST",
              "/cronwatch/check",
              with(fwd, headers(h("origin", "https://other.example"))),
              ""),
          403);
      status(
          "configured",
          send(
              w,
              "POST",
              "/cronwatch/check",
              with(fwd, headers(h("origin", "https://app.example.com"))),
              ""),
          303);
    }

    // trustProxy takes the first forwarded values.
    try (WebKit w = app(RoutesOptions.builder().trustProxy())) {
      var fwd =
          headers(
              h("x-forwarded-proto", "https, http"),
              h("x-forwarded-host", "app.example.com, 10.0.0.5:8080"));
      status(
          "internal",
          send(
              w,
              "POST",
              "/cronwatch/jobs/x/silence",
              with(fwd, headers(FORM, h("origin", INTERNAL))),
              "for=1h"),
          403);
      status(
          "public",
          send(
              w,
              "POST",
              "/cronwatch/jobs/x/silence",
              with(fwd, headers(FORM, h("origin", "https://app.example.com"))),
              "for=1h"),
          303);
      assertTrue(
          send(w, "GET", "/cronwatch/?token=tok", fwd, "")
              .header("set-cookie")
              .endsWith("; Secure"));
      status(
          "proto only",
          send(
              w,
              "POST",
              "/cronwatch/check",
              headers(h("x-forwarded-proto", "https"), h("origin", "https://10.0.0.5:8080")),
              ""),
          303);
      status(
          "neither", send(w, "POST", "/cronwatch/check", headers(h("origin", INTERNAL)), ""), 303);
      String[][] cases = {
        {"javascript", "evil.example", "javascript://evil.example"},
        {"https", "evil.example/path", "https://evil.example"},
        {"https", "user@evil.example", "https://evil.example"},
      };
      for (String[] c : cases) {
        var hs = headers(h("x-forwarded-proto", c[0]), h("x-forwarded-host", c[1]));
        status(
            c[2],
            send(w, "POST", "/cronwatch/check", with(hs, headers(h("origin", c[2]))), ""),
            403);
        status(
            c[2],
            send(w, "POST", "/cronwatch/check", with(hs, headers(h("origin", INTERNAL))), ""),
            303);
      }
    }

    // Without trustProxy forwarded headers change nothing.
    try (WebKit w = new WebKit()) {
      w.ok("x");
      var cookie = h("cookie", tokenCookie());
      var spoofed = headers(h("x-forwarded-host", "evil.example"), h("x-forwarded-proto", "https"));
      status(
          "foreign",
          w.send(
              "POST",
              "/cronwatch/jobs/x/silence",
              with(headers(cookie, FORM), spoofed, headers(h("origin", "https://evil.example"))),
              "for=1h"),
          403);
      Response back =
          w.send(
              "POST",
              "/cronwatch/check",
              with(
                  headers(cookie),
                  spoofed,
                  headers(
                      h("origin", "http://app.test"),
                      h("referer", "https://evil.example/cronwatch/jobs/x"))),
              "");
      assertEquals("/cronwatch/", back.header("location"));
      assertFalse(
          w.get("/cronwatch/?token=tok", spoofed).header("set-cookie").contains("Secure"),
          "Secure from a spoofed header");
      // TLS makes the request's own origin https.
      Response tls = serve(w.routes, "GET", "https://app.test/cronwatch/?token=tok", NONE, "");
      assertTrue(tls.header("set-cookie").endsWith("; Secure"), "not Secure over TLS");

      // A bad origin is refused when the routes are made.
      CronwatchException e =
          assertThrows(
              CronwatchException.class,
              () ->
                  w.cw.routes(
                      RoutesOptions.builder().token("tok").origin("app.example.com").build()));
      assertEquals(
          "routes: origin must be an absolute URL such as \"https://app.example.com\", got"
              + " \"app.example.com\"",
          e.getMessage());
      assertEquals(CronwatchException.Kind.INVALID, e.kind());
      e =
          assertThrows(
              CronwatchException.class,
              () ->
                  w.cw.routes(
                      RoutesOptions.builder()
                          .token("tok")
                          .origin("ftp://app.example.com")
                          .build()));
      assertEquals(
          "routes: origin must be http or https, got \"ftp://app.example.com\"", e.getMessage());
      assertNotNull(w.cw.routes(RoutesOptions.builder().token("tok").origin("").build()));

      // Origins are read as URL#origin reads them.
      String[][] read = {
        {" HTTPS://App.Example.COM:443/x ", "https://app.example.com"},
        {"http:\\\\example.com:8080", "http://example.com:8080"},
        {"http://0x7f.1", "http://127.0.0.1"},
        {"http://[0:0::1]:80", "http://[::1]"},
        {"https://bücher.example", "https://xn--bcher-kva.example"},
        {"http://user:pw@example.com", "http://example.com"},
      };
      for (String[] c : read) {
        Routes routes = w.cw.routes(RoutesOptions.builder().token("tok").origin(c[0]).build());
        status(
            c[0],
            serve(
                routes,
                "POST",
                "http://10.0.0.5/cronwatch/api/check",
                headers(AUTH, h("origin", c[1])),
                ""),
            200);
      }
    }
  }

  // The Go audit: a Host header outside ASCII over 1024 bytes is not punycoded (which takes time
  // in its length times its distinct characters) or read as a URL; the request is answered all the
  // same.
  @Test
  void aLongHostOutsideAsciiIsNotReadAsAUrl() {
    try (WebKit w = new WebKit()) {
      w.ok("x");
      StringBuilder chars = new StringBuilder();
      for (int i = 0; i < 2000; i++) {
        chars.appendCodePoint(0x4e00 + i);
      }
      // As a server reads it: each byte of its UTF-8 one character.
      String host =
          new String(
              chars.toString().getBytes(StandardCharsets.UTF_8), StandardCharsets.ISO_8859_1);
      Request req =
          Request.builder("POST", "/cronwatch/api/check")
              .header("host", host)
              .header("authorization", "Bearer tok")
              .build();
      status("answered", w.routes.handle(req), 200);
      Request own =
          Request.builder("POST", "/cronwatch/api/check")
              .header("host", host)
              .header("authorization", "Bearer tok")
              .header("origin", "http://" + host)
              .build();
      // The origin a browser sends is the host's own bytes, which the routes read as UTF-8.
      Request asSent =
          Request.builder("POST", "/cronwatch/api/check")
              .header("host", host)
              .header("authorization", "Bearer tok")
              .header("origin", "http://" + chars)
              .build();
      status("its own origin", w.routes.handle(asSent), 200);
      status("the bytes as characters are another origin", w.routes.handle(own), 403);
    }
  }

  @Test
  void theAppShellIsPublicAndOnlyForReads() {
    for (RoutesOptions options :
        List.of(
            RoutesOptions.builder().token("tok").build(),
            RoutesOptions.builder().noToken().build())) {
      try (WebKit k = new WebKit(options, b -> {})) {
        for (String path :
            List.of(
                "/manifest.webmanifest",
                "/sw.js",
                "/app.js",
                "/offline",
                "/icons/icon.svg",
                "/icons/icon-192.png")) {
          String url = "http://app.test/cronwatch" + path;
          status(path, serve(k.routes, "GET", url, NONE, ""), 200);
          status(path, serve(k.routes, "HEAD", url, NONE, ""), 200);
        }
        Response sw = serve(k.routes, "GET", "http://app.test/cronwatch/sw.js", NONE, "");
        assertEquals("/cronwatch/", sw.header("service-worker-allowed"));
        Response svg = serve(k.routes, "GET", "http://app.test/cronwatch/icons/icon.svg", NONE, "");
        assertEquals(
            "default-src 'none'; style-src 'unsafe-inline'; frame-ancestors 'none'",
            svg.header("content-security-policy"));
        assertEquals("public, max-age=31536000, immutable", svg.header("cache-control"));
      }
    }
    try (WebKit w = new WebKit()) {
      status("a write to the shell", w.send("POST", "/cronwatch/sw.js", NONE, ""), 401);
      status("HEAD elsewhere", w.send("HEAD", "/cronwatch/", headers(AUTH), ""), 404);
    }
    try (WebKit open = new WebKit(RoutesOptions.builder().noToken().build(), b -> {})) {
      assertNull(open.routes.token());
      status(
          "open", serve(open.routes, "GET", "http://app.test/cronwatch/api/jobs", NONE, ""), 200);
    }
  }

  private static String manifestId(Endpoint routes, Request req) {
    Response res = routes.handle(req);
    if (res.status() != 200) {
      return Integer.toString(res.status());
    }
    return (String) field(json(res), "id");
  }

  @Test
  void theBasePath() throws Exception {
    try (WebKit k = new WebKit(RoutesOptions.builder().noToken().build(), b -> {})) {
      k.ok("x");
      Routes open = k.routes;
      assertEquals(
          "/cronwatch/",
          manifestId(open, Request.of("GET", "/cronwatch/manifest.webmanifest")),
          "the default");
      Routes root = k.cw.routes(RoutesOptions.builder().noToken().basePath("").build());
      assertEquals(
          "/", manifestId(root, Request.of("GET", "/manifest.webmanifest")), "at the root");
      Routes deep = k.cw.routes(RoutesOptions.builder().noToken().basePath("/a/b/").build());
      assertEquals(
          "/a/b/",
          manifestId(deep, Request.of("GET", "/a/b/manifest.webmanifest")),
          "a base with its slash");
      assertEquals(
          "/x/y/",
          manifestId(
              open, Request.builder("GET", "/x/y/manifest.webmanifest").mount("/x/y/").build()),
          "an adapter's mount");
      assertEquals(
          "/a/b/",
          manifestId(deep, Request.builder("GET", "/a/b/manifest.webmanifest").mount("/x").build()),
          "the option wins");
    }
  }

  @Test
  void pathsAreReadAsTheUrlParserLeavesThem() {
    try (WebKit w = new WebKit()) {
      w.ok("x");
      for (String path :
          List.of(
              "/cronwatch/./jobs/x",
              "/cronwatch/nope/../jobs/x",
              "/cronwatch\\jobs\\x",
              "/cronwatch/%2e/jobs/x",
              "/cronwatch/jobs/%78")) {
        Response res = w.get(path, headers(AUTH));
        status(path, res, 200);
        contains(path, res.text(), "<h1 class=\"jobname\">x</h1>");
      }
      status("a slash inside a name", w.get("/cronwatch/api/jobs/a%2Fb", headers(AUTH)), 404);
    }
  }

  // The Go audit: an interval past what a long of milliseconds holds wrapped round, and drawing
  // the board's timeline never ended; a silence for longer than that ended at once.
  @Test
  void hugeDurationsNeitherHangNorWrap() {
    try (WebKit w = new WebKit()) {
      Job job = w.cw.job("rare", JobOptions.builder().schedule("every 20000000000w"));
      job.run(j -> {});
      w.advance(10 * 24 * HOUR);
      w.cw.check();
      for (String path :
          List.of("/cronwatch/", "/cronwatch/jobs/rare", "/cronwatch/api/jobs/rare")) {
        status(path, w.get(path, headers(AUTH)), 200);
      }
      JsObject silenced =
          json(
              w.send(
                  "POST",
                  "/cronwatch/api/jobs/rare/silence",
                  headers(AUTH, JSON),
                  "{\"for\":\"99999999999999999999999\"}"));
      double until = ((Number) field(silenced, "state", "silencedUntil")).doubleValue();
      assertTrue(until > w.clock.get(), "a long silence ended at once: " + until);
    }
  }

  // A foreign row's far times on the pages: the seed of golden.mjs holds them; here a run that
  // started at the lowest long is drawn and answered.
  @Test
  void farTimesAreAnswered() throws Exception {
    Breakable store = new Breakable();
    try (WebKit w = new WebKit(RoutesOptions.builder().token("tok").build(), b -> b.store(store))) {
      w.ok("far");
      store.inner.insertRun(Run.running("far-run", "far", Long.MIN_VALUE, "run"));
      for (String path : List.of("/cronwatch/", "/cronwatch/jobs/far", "/cronwatch/api/jobs/far")) {
        status(path, w.get(path, headers(AUTH)), 200);
      }
      assertEquals(List.of(), w.wheres);
    }
  }

  @Test
  void nothingPrintsASecret() {
    String token = "t0k" + "-value";
    assertFalse(RoutesOptions.builder().token(token).build().toString().contains(token));
    assertFalse(RoutesOptions.builder().token(token).toString().contains(token));
    assertFalse(HandlerOptions.builder().secret(token).build().toString().contains(token));
    assertFalse(HandlerOptions.builder().secret(token).toString().contains(token));
    Request req =
        Request.builder("GET", "/cronwatch/?token=" + token)
            .header("authorization", "Bearer " + token)
            .header("cookie", "cronwatch_token=" + token)
            .body(token)
            .build();
    assertFalse(req.toString().contains(token), req.toString());
    assertFalse(
        Request.builder("GET", "/?token=" + token)
            .header("authorization", token)
            .toString()
            .contains(token));
    try (WebKit w = new WebKit(RoutesOptions.builder().token(token).build(), b -> {})) {
      assertFalse(w.routes.toString().contains(token));
      Handler handler =
          w.cw
              .job("h", JobOptions.builder())
              .handler((j, r) -> null, HandlerOptions.builder().secret(token).build());
      assertFalse(handler.toString().contains(token));
    }
    Response r =
        Response.of(200).withHeader("set-cookie", "cronwatch_token=" + token).withBody(token);
    assertFalse(r.toString().contains(token));
  }
}
