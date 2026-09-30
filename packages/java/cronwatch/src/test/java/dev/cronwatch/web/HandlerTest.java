package dev.cronwatch.web;

import static dev.cronwatch.web.WebKit.json;
import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;

import dev.cronwatch.Cronwatch;
import dev.cronwatch.Job;
import dev.cronwatch.JobOptions;
import dev.cronwatch.Run;
import dev.cronwatch.RunStatus;
import java.io.IOException;
import java.util.List;
import org.junit.jupiter.api.Test;

/**
 * {@code job.handler()}: the SDK's handler tests ({@code client.test.ts} and {@code
 * client-hardening.test.ts}), as the Go, Rust and Elixir ports have them, and the Java answers: a
 * {@link Response} the function returns, a throw answered 500, an {@link Error} recorded and thrown
 * again, and the JDK's server in front. Without a secret, and in development, it is tested in
 * {@link RoutesEnvTest}.
 */
class HandlerTest {
  private static String secret() {
    return "s3" + "cret";
  }

  private static List<Run> runs(Cronwatch cw, String job) {
    return cw.runs(job, 10);
  }

  private static Request get(String auth, boolean fail) {
    Request.Builder b = Request.builder("GET", "/api/cron/hourly");
    if (auth != null) {
      b.header("authorization", auth);
    }
    if (fail) {
      b.header("x-fail", "1");
    }
    return b.build();
  }

  @Test
  void theHandlerChecksTheBearerAndReportsTheRun() {
    String secret = secret();
    try (WebKit k = new WebKit(RoutesOptions.defaults(), b -> b.cronSecret(secret))) {
      Job job = k.cw.job("hourly", JobOptions.builder().schedule("@hourly"));
      Handler h =
          job.handler(
              (j, req) -> {
                j.log(req.target());
                if (req.header("x-fail") != null) {
                  throw new IOException("nope\nsecond line");
                }
                return null;
              });
      assertEquals(401, h.handle(get(null, false)).status(), "no auth");
      Response wrong = h.handle(get("Bearer wrong", false));
      assertEquals("{\"ok\":false,\"error\":\"Unauthorized\"}", wrong.text());
      assertEquals(401, h.handle(get("bearer " + secret, false)).status(), "a lowercase bearer");
      Response res = h.handle(get("Bearer " + secret, false));
      assertEquals(200, res.status());
      assertEquals("application/json; charset=utf-8", res.header("content-type"));
      assertEquals("no-store", res.header("cache-control"));
      List<Run> runs = runs(k.cw, "hourly");
      assertEquals(
          "{\"ok\":true,\"job\":\"hourly\",\"run\":\""
              + runs.get(0).id()
              + "\",\"status\":\"ok\",\"durationMs\":0}",
          res.text());
      k.advance(1000);
      Response failed = h.handle(get("Bearer " + secret, true));
      assertEquals(500, failed.status());
      assertEquals("IOException: nope", json(failed).get("error"), "the error's first line");
      runs = runs(k.cw, "hourly");
      assertEquals(2, runs.size());
      assertEquals("/api/cron/hourly", runs.get(1).output());
      assertEquals("handler", runs.get(0).trigger());
      assertTrue(runs.get(0).error().startsWith("IOException: nope\nsecond line\n"));
    }
  }

  @Test
  void aSecretOfItsOwnReplacesTheClients() {
    String clientSecret = "client-" + "secret";
    String own = "own-" + "secret";
    try (WebKit k = new WebKit(RoutesOptions.defaults(), b -> b.cronSecret(clientSecret))) {
      Job job = k.cw.job("own", JobOptions.builder());
      HandlerFunction ok = (j, r) -> null;
      Handler h = job.handler(ok, HandlerOptions.builder().secret(own).build());
      assertEquals(401, post(h, clientSecret).status(), "the client's");
      assertEquals(200, post(h, own).status(), "its own");
      Handler empty = job.handler(ok, HandlerOptions.builder().secret("").build());
      assertEquals(200, post(empty, clientSecret).status(), "an empty one is the client's");
      Handler open = job.handler(ok, HandlerOptions.builder().noSecret().build());
      assertEquals(200, open.handle(Request.of("POST", "/")).status(), "noSecret lets anyone in");
    }
  }

  private static Response post(Handler h, String secret) {
    return h.handle(
        Request.builder("POST", "/").header("authorization", "Bearer " + secret).build());
  }

  @Test
  void aResponseIsTheAnswerAndFailsTheRunAt400() {
    try (WebKit k = new WebKit()) {
      Job job = k.cw.job("h", JobOptions.builder());
      Handler returned =
          job.handler((j, r) -> Response.of(503).withHeader("x-upstream", "1").withBody("bad"));
      Response res = returned.handle(Request.of("GET", "/"));
      assertEquals(503, res.status(), "passed through");
      assertEquals("bad", res.text());
      assertEquals("1", res.header("x-upstream"));
      assertEquals("HTTP 503 Service Unavailable", runs(k.cw, "h").get(0).error());
      assertEquals(List.of("failed"), k.types());

      k.advance(1000);
      Handler fine =
          job.handler(
              (j, r) ->
                  Response.of(202).withHeader("content-type", "text/plain").withBody("queued"));
      res = fine.handle(Request.of("GET", "/"));
      assertEquals(202, res.status());
      assertEquals("queued", res.text());
      assertEquals("text/plain", res.header("content-type"));
      assertEquals(RunStatus.OK, runs(k.cw, "h").get(0).status(), "an ok run");

      k.advance(1000);
      Handler text = job.handler((j, r) -> "Report written");
      res = text.handle(Request.of("GET", "/"));
      assertEquals(200, res.status(), "a string");
      assertEquals("Report written", runs(k.cw, "h").get(0).output(), "its output");
    }
  }

  @Test
  void aThrowIsAFailedRunAnsweredWithTheRun() {
    String secret = secret();
    try (WebKit k = new WebKit(RoutesOptions.defaults(), b -> b.cronSecret(secret))) {
      Handler h =
          k.cw
              .job("p", JobOptions.builder())
              .handler(
                  (j, r) -> {
                    throw new IllegalStateException("boom");
                  });
      Response res =
          h.handle(Request.builder("GET", "/").header("authorization", "Bearer " + secret).build());
      assertEquals(500, res.status(), "answered");
      assertEquals("application/json; charset=utf-8", res.header("content-type"));
      List<Run> runs = runs(k.cw, "p");
      assertEquals(RunStatus.FAILED, runs.get(0).status());
      assertEquals(
          "{\"ok\":false,\"job\":\"p\",\"run\":\""
              + runs.get(0).id()
              + "\",\"status\":\"failed\",\"durationMs\":0,\"error\":\"IllegalStateException:"
              + " boom\"}",
          res.text());
      assertEquals(List.of("failed"), k.types());

      // A caller without the secret gets no error text, as for any failure.
      Handler open =
          k.cw
              .job("q", JobOptions.builder())
              .handler(
                  (j, r) -> {
                    throw new IllegalStateException("private detail");
                  },
                  HandlerOptions.builder().noSecret().build());
      Response anyone = open.handle(Request.of("GET", "/"));
      assertEquals(500, anyone.status());
      assertFalse(json(anyone).has("error"), "the error went to a caller who sent no secret");

      // A response returned is never the answer to a run that threw: there is none.
      Handler error =
          k.cw
              .job("e", JobOptions.builder())
              .handler(
                  (j, r) -> {
                    throw new AssertionError("an Error");
                  },
                  HandlerOptions.builder().noSecret().build());
      assertThrows(AssertionError.class, () -> error.handle(Request.of("GET", "/")));
      assertEquals(RunStatus.FAILED, runs(k.cw, "e").get(0).status(), "recorded all the same");
    }
  }

  @Test
  void anInterruptedHandlerRestoresTheInterruptStatus() throws Exception {
    try (WebKit k = new WebKit()) {
      Handler h =
          k.cw
              .job("i", JobOptions.builder())
              .handler(
                  (j, r) -> {
                    Thread.sleep(60_000);
                    return null;
                  });
      boolean[] interrupted = {false};
      Response[] res = new Response[1];
      Thread t =
          Thread.ofVirtual()
              .start(
                  () -> {
                    res[0] = h.handle(Request.of("GET", "/"));
                    interrupted[0] = Thread.currentThread().isInterrupted();
                  });
      // Interrupted as soon as it sleeps.
      while (t.getState() != Thread.State.WAITING && t.getState() != Thread.State.TIMED_WAITING) {
        Thread.onSpinWait();
      }
      t.interrupt();
      t.join();
      assertEquals(500, res[0].status());
      assertTrue(interrupted[0], "the interrupt status was lost");
      assertTrue(runs(k.cw, "i").get(0).error().startsWith("InterruptedException"));
    }
  }

  @Test
  void runFailsForAnHttpAnswerOf400OrMore() {
    try (WebKit k = new WebKit()) {
      Job job = k.cw.job("fetch", JobOptions.builder());
      Response res = job.call(j -> Response.of(502));
      assertEquals(502, res.status(), "handed back");
      assertEquals("HTTP 502 Bad Gateway", runs(k.cw, "fetch").get(0).error());
      k.advance(1000);
      Response unknown = job.call(j -> Response.of(599));
      assertEquals(599, unknown.status());
      assertEquals("HTTP 599", runs(k.cw, "fetch").get(0).error(), "a status with no reason");
      k.advance(1000);
      job.call(j -> Response.of(204));
      assertEquals(RunStatus.OK, runs(k.cw, "fetch").get(0).status());
    }
  }
}
