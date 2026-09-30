package dev.cronwatch.webtest;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertTrue;

import com.sun.net.httpserver.HttpServer;
import dev.cronwatch.Cronwatch;
import dev.cronwatch.Definition;
import dev.cronwatch.JobContext;
import dev.cronwatch.JobOptions;
import dev.cronwatch.JobState;
import dev.cronwatch.Run;
import dev.cronwatch.StoredJob;
import dev.cronwatch.json.JsObject;
import dev.cronwatch.json.Json;
import dev.cronwatch.store.MemoryStore;
import dev.cronwatch.store.Store;
import dev.cronwatch.web.Handler;
import dev.cronwatch.web.Request;
import dev.cronwatch.web.Routes;
import dev.cronwatch.web.RoutesOptions;
import dev.cronwatch.web.WebServer;
import java.net.InetAddress;
import java.net.InetSocketAddress;
import java.net.Socket;
import java.nio.charset.StandardCharsets;
import java.util.List;
import java.util.Map;
import java.util.concurrent.CopyOnWriteArrayList;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import org.jspecify.annotations.Nullable;
import org.junit.jupiter.api.Test;

/**
 * The dashboard and a job's handler behind the JDK's own server ({@link WebServer}): the base path
 * found from the context, an encoded slash and a {@code HEAD} passed through, a request that ended
 * before its answer not reported, and a handler reading its body over the wire.
 */
class JdkServerTest {
  private static final List<Map.Entry<String, String>> NONE = List.of();

  /** A server on a free loopback port, answering on virtual threads. */
  private static HttpServer server(ExecutorService pool) throws Exception {
    HttpServer server =
        HttpServer.create(new InetSocketAddress(InetAddress.getLoopbackAddress(), 0), 0);
    server.setExecutor(pool);
    return server;
  }

  private static RawHttp.Answer get(HttpServer server, String path) throws Exception {
    return RawHttp.send(server.getAddress().getPort(), "GET", path, NONE, null);
  }

  private static Object id(RawHttp.Answer answer) {
    return ((JsObject) Json.parse(answer.text())).get("id");
  }

  @Test
  void theBaseIsTheContexts() throws Exception {
    try (Cronwatch cw = Cronwatch.builder().noCronSecret().noShutdownHook().build();
        ExecutorService pool = Executors.newVirtualThreadPerTaskExecutor()) {
      cw.run("x", job -> {});
      HttpServer server = server(pool);
      WebServer.mount(server, "/ops/cron", cw.routes(RoutesOptions.builder().noToken().build()));
      WebServer.mount(server, "/", cw.routes(RoutesOptions.builder().noToken().build()));
      server.start();
      try {
        assertEquals("/ops/cron/", id(get(server, "/ops/cron/manifest.webmanifest")));
        RawHttp.Answer board = get(server, "/ops/cron/");
        assertEquals(200, board.status());
        assertTrue(board.text().contains("href=\"/ops/cron/jobs/x\""), "the job's link");
        assertEquals(200, get(server, "/ops/cron/jobs/x").status(), "the job page");
        assertEquals(200, get(server, "/ops/cron").status(), "the mount itself");
        assertEquals("/", id(get(server, "/manifest.webmanifest")), "at the root");
        // An encoded slash reaches the routes as sent, which read it as part of one name.
        assertEquals(404, get(server, "/ops/cron/api/jobs/a%2Fb").status());
        // A HEAD is answered without a body.
        RawHttp.Answer head =
            RawHttp.send(server.getAddress().getPort(), "HEAD", "/ops/cron/app.js", NONE, null);
        assertEquals(200, head.status());
        assertEquals(0, head.body().length);
      } finally {
        server.stop(0);
      }
    }
  }

  /** A memory store whose job list, while {@link #entered} is set, waits to be released. */
  static final class GateStore implements Store {
    final Store inner = new MemoryStore();
    volatile @Nullable CountDownLatch entered;
    final CountDownLatch release = new CountDownLatch(1);

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
      CountDownLatch e = entered;
      if (e != null) {
        e.countDown();
        release.await();
      }
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

  // The Go audit: a request that ended before its answer (a platform cron that timed out, a
  // browser gone elsewhere) was reported as a failure. Here the client goes away while the store is
  // read; the answer is written to nobody and nothing is reported.
  @Test
  void aRequestThatEndedIsNotReported() throws Exception {
    GateStore store = new GateStore();
    List<String> reported = new CopyOnWriteArrayList<>();
    try (Cronwatch cw =
            Cronwatch.builder()
                .store(store)
                .noCronSecret()
                .noShutdownHook()
                .onError((where, e) -> reported.add(where + ": " + e))
                .build();
        ExecutorService pool = Executors.newVirtualThreadPerTaskExecutor()) {
      cw.run("x", job -> {});
      Routes routes = cw.routes(RoutesOptions.builder().token("tok").build());
      HttpServer server = server(pool);
      WebServer.mount(server, "/cronwatch", routes);
      server.start();
      try {
        CountDownLatch entered = new CountDownLatch(1);
        store.entered = entered;
        try (Socket socket =
            new Socket(InetAddress.getLoopbackAddress(), server.getAddress().getPort())) {
          socket
              .getOutputStream()
              .write(
                  String.join(
                          "\r\n",
                          "GET /cronwatch/api/jobs HTTP/1.1",
                          "host: app.test",
                          "authorization: Bearer tok",
                          "",
                          "")
                      .getBytes(StandardCharsets.ISO_8859_1));
          socket.getOutputStream().flush();
          entered.await();
        }
        // The client is gone; the store answers and the routes write to nobody.
        store.entered = null;
        store.release.countDown();
        RawHttp.Answer next =
            RawHttp.send(
                server.getAddress().getPort(),
                "GET",
                "/cronwatch/api/jobs",
                List.of(Map.entry("authorization", "Bearer tok")),
                null);
        assertEquals(200, next.status(), "a request still open");
        assertEquals(List.of(), reported);
      } finally {
        server.stop(0);
      }
    }
  }

  @Test
  void aHandlerBehindTheServer() throws Exception {
    String secret = "s3" + "cret";
    try (Cronwatch cw = Cronwatch.builder().cronSecret(secret).noShutdownHook().build();
        ExecutorService pool = Executors.newVirtualThreadPerTaskExecutor()) {
      Handler h =
          cw.job("served", JobOptions.builder())
              .handler(
                  (JobContext j, Request req) -> {
                    JobContext current = Cronwatch.current();
                    assertEquals(j.runId(), current.runId(), "current() is the run's context");
                    byte[] body = req.readBody(1024);
                    j.log(
                        req.method()
                            + " "
                            + req.target()
                            + " "
                            + new String(body, StandardCharsets.UTF_8));
                    return null;
                  });
      HttpServer server = server(pool);
      WebServer.mount(server, "/api/cron/served", h);
      server.start();
      try {
        int port = server.getAddress().getPort();
        RawHttp.Answer res =
            RawHttp.send(
                port,
                "POST",
                "/api/cron/served?x=1",
                List.of(Map.entry("authorization", "Bearer " + secret)),
                "over the wire".getBytes(StandardCharsets.UTF_8));
        assertEquals(200, res.status());
        assertTrue(res.text().startsWith("{\"ok\":true,\"job\":\"served\",\"run\":\""), res.text());
        assertEquals(
            "POST /api/cron/served?x=1 over the wire", cw.runs("served", 1).get(0).output());
        assertEquals(401, RawHttp.send(port, "POST", "/api/cron/served", NONE, null).status());
      } finally {
        server.stop(0);
      }
    }
  }
}
