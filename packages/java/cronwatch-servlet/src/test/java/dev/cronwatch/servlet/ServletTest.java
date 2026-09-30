package dev.cronwatch.servlet;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertNull;
import static org.junit.jupiter.api.Assertions.assertTrue;

import dev.cronwatch.Cronwatch;
import dev.cronwatch.JobOptions;
import dev.cronwatch.web.HandlerOptions;
import dev.cronwatch.web.Request;
import dev.cronwatch.web.RoutesOptions;
import dev.cronwatch.webtest.Golden;
import dev.cronwatch.webtest.RawHttp;
import jakarta.servlet.DispatcherType;
import jakarta.servlet.Filter;
import jakarta.servlet.http.HttpServlet;
import jakarta.servlet.http.HttpServletRequest;
import jakarta.servlet.http.HttpServletResponse;
import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.net.InetAddress;
import java.net.Socket;
import java.net.SocketException;
import java.nio.charset.StandardCharsets;
import java.util.EnumSet;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.concurrent.atomic.AtomicLong;
import org.eclipse.jetty.ee10.servlet.FilterHolder;
import org.eclipse.jetty.ee10.servlet.ServletContextHandler;
import org.eclipse.jetty.ee10.servlet.ServletHolder;
import org.eclipse.jetty.server.Server;
import org.eclipse.jetty.server.ServerConnector;
import org.junit.jupiter.api.Test;

/**
 * The servlet adapter under a real Jetty 12: the golden replay through {@link CronwatchFilter}, its
 * base path found from the context and the filter's path, and what only a servlet container has: a
 * context path, a form a filter ahead already read, the body cap and a body cut short over the
 * wire, and a job's handler as {@link CronwatchServlet}.
 */
class ServletTest {
  private static final long T0 = Golden.T0;
  private static final long HOUR = 3_600_000;

  /** A Jetty server on a free port, with the app's own servlet answering what the filter passes. */
  private static Server jetty(String contextPath, String filterPath, Filter filter, Filter... ahead)
      throws Exception {
    Server server = new Server();
    ServerConnector connector = new ServerConnector(server);
    connector.setHost(InetAddress.getLoopbackAddress().getHostAddress());
    connector.setPort(0);
    server.addConnector(connector);
    ServletContextHandler context = new ServletContextHandler(contextPath);
    for (Filter f : ahead) {
      context.addFilter(new FilterHolder(f), "/*", EnumSet.of(DispatcherType.REQUEST));
    }
    context.addFilter(
        new FilterHolder(filter), filterPath + "/*", EnumSet.of(DispatcherType.REQUEST));
    context.addServlet(
        new ServletHolder(
            new HttpServlet() {
              private static final long serialVersionUID = 1L;

              @Override
              protected void service(HttpServletRequest req, HttpServletResponse res)
                  throws IOException {
                res.setStatus(404);
                res.getWriter().write("the app");
              }
            }),
        "/");
    server.setHandler(context);
    server.start();
    return server;
  }

  private static int port(Server server) {
    return ((ServerConnector) server.getConnectors()[0]).getLocalPort();
  }

  @Test
  void theRoutesMatchTheSdkThroughTheFilterUnderJetty() throws Exception {
    Golden.Seeded seeded = Golden.seed();
    try (Cronwatch cw = seeded.cw()) {
      // No base path: it is found from the context and the filter's path.
      Server server =
          jetty(
              "/",
              "/cronwatch",
              new CronwatchFilter(cw.routes(RoutesOptions.builder().token("tok").build())));
      try {
        // Jetty refuses a request target that is not a URI (the two %zz paths) itself, and writes
        // a content-type back without the space after its ";".
        int matched =
            Golden.throughServer(
                seeded,
                port(server),
                Set.of("date", "server", "connection"),
                Golden.MALFORMED_TARGETS,
                true);
        assertEquals(Golden.CAPTURES - 2, matched);
      } finally {
        server.stop();
      }
    }
  }

  private static RawHttp.Answer get(int port, String path) throws IOException {
    return RawHttp.send(port, "GET", path, List.of(), null);
  }

  @Test
  void theBaseIsTheContextAndTheFiltersPath() throws Exception {
    try (Cronwatch cw = Cronwatch.builder().noCronSecret().noShutdownHook().build()) {
      cw.run("x", job -> {});
      Server server =
          jetty(
              "/app",
              "/ops/cron",
              new CronwatchFilter(
                  cw.routes(RoutesOptions.builder().noToken().build()), "/ops/cron"));
      try {
        int port = port(server);
        RawHttp.Answer manifest = get(port, "/app/ops/cron/manifest.webmanifest");
        assertEquals(200, manifest.status());
        assertTrue(manifest.text().contains("\"id\":\"/app/ops/cron/\""), manifest.text());
        RawHttp.Answer board = get(port, "/app/ops/cron/");
        assertTrue(board.text().contains("href=\"/app/ops/cron/jobs/x\""), "the job's link");
        assertEquals(200, get(port, "/app/ops/cron/jobs/x").status(), "the job page");
        assertEquals(200, get(port, "/app/ops/cron").status(), "the mount itself");
        RawHttp.Answer other = get(port, "/app/elsewhere");
        assertEquals(404, other.status());
        assertEquals("the app", other.text(), "passed down the chain");
        assertEquals("the app", get(port, "/app/ops/cronx").text(), "not under the path");
      } finally {
        server.stop();
      }
    }
  }

  /** A filter ahead of the dashboard that reads the form, as HiddenHttpMethodFilter does. */
  private static final Filter READS_THE_FORM =
      (request, response, chain) -> {
        request.getParameter("_method");
        chain.doFilter(request, response);
      };

  private static List<Map.Entry<String, String>> form() {
    return List.of(
        Map.entry("authorization", "Bearer tok"),
        Map.entry("content-type", "application/x-www-form-urlencoded"));
  }

  @Test
  void aFormAFilterAheadAlreadyReadIsTakenFromTheParameters() throws Exception {
    AtomicLong clock = new AtomicLong(T0);
    try (Cronwatch cw =
        Cronwatch.builder().clock(clock::get).noCronSecret().noShutdownHook().build()) {
      cw.run("f", job -> {});
      Server server =
          jetty(
              "/",
              "/cronwatch",
              new CronwatchFilter(cw.routes(RoutesOptions.builder().token("tok").build())),
              READS_THE_FORM);
      try {
        int port = port(server);
        RawHttp.Answer res =
            RawHttp.send(
                port,
                "POST",
                "/cronwatch/api/jobs/f/silence?for=1h",
                form(),
                "for=4h".getBytes(StandardCharsets.UTF_8));
        assertEquals(200, res.status(), res.text());
        assertEquals(
            T0 + 4 * HOUR, cw.jobSummary("f").silencedUntil(), "the body's, not the query's");
        RawHttp.Answer page =
            RawHttp.send(
                port,
                "POST",
                "/cronwatch/jobs/f/silence",
                form(),
                "for=2h".getBytes(StandardCharsets.UTF_8));
        assertEquals(303, page.status());
        assertEquals(T0 + 2 * HOUR, cw.jobSummary("f").silencedUntil());
      } finally {
        server.stop();
      }
    }
  }

  @Test
  void theBodyCapAndABodyCutShortOverTheWire() throws Exception {
    AtomicLong clock = new AtomicLong(T0);
    try (Cronwatch cw =
        Cronwatch.builder().clock(clock::get).noCronSecret().noShutdownHook().build()) {
      cw.run("s", job -> {});
      Server server =
          jetty(
              "/",
              "/cronwatch",
              new CronwatchFilter(cw.routes(RoutesOptions.builder().token("tok").build())));
      try {
        int port = port(server);
        byte[] big =
            ("for=2h&pad=" + "x".repeat(Request.MAX_BODY)).getBytes(StandardCharsets.UTF_8);
        try {
          RawHttp.Answer tooLarge =
              RawHttp.send(port, "POST", "/cronwatch/api/jobs/s/silence", form(), big);
          assertEquals(413, tooLarge.status());
        } catch (SocketException e) {
          // The server answered by the declared length and closed with the body unread, which
          // some network stacks turn into a reset before the answer is read.
        }
        assertNull(cw.jobSummary("s").silencedUntil(), "a body past the cap silenced the job");
        String exact = "for=2h&pad=";
        exact += "x".repeat(Request.MAX_BODY - exact.length());
        RawHttp.Answer atTheCap =
            RawHttp.send(
                port,
                "POST",
                "/cronwatch/api/jobs/s/silence",
                form(),
                exact.getBytes(StandardCharsets.UTF_8));
        assertEquals(200, atTheCap.status(), "a body of exactly 1 MiB is read");
        cw.unsilence("s");

        // "for=7d" cut short at "for=7" is none, never a silence of 7 ms.
        String head =
            String.join(
                "\r\n",
                "POST /cronwatch/api/jobs/s/silence HTTP/1.1",
                "host: app.test",
                "authorization: Bearer tok",
                "content-type: application/x-www-form-urlencoded",
                "content-length: 50",
                "",
                "for=7");
        try (Socket socket = new Socket(InetAddress.getLoopbackAddress(), port)) {
          socket.setSoTimeout(30_000);
          OutputStream out = socket.getOutputStream();
          out.write(head.getBytes(StandardCharsets.ISO_8859_1));
          out.flush();
          socket.shutdownOutput();
          InputStream in = socket.getInputStream();
          ByteArrayOutputStream answer = new ByteArrayOutputStream();
          in.transferTo(answer);
        }
        // The answer may or may not reach a client that closed its side; the store says.
        Long until = cw.jobSummary("s").silencedUntil();
        assertTrue(until == null || until == T0 + HOUR, "silenced until " + until);
      } finally {
        server.stop();
      }
    }
  }

  @Test
  void aJobsHandlerAsAServlet() throws Exception {
    String secret = "s3" + "cret";
    try (Cronwatch cw = Cronwatch.builder().cronSecret(secret).noShutdownHook().build()) {
      var handler =
          cw.job("served", JobOptions.builder())
              .handler(
                  (job, req) -> {
                    job.log(
                        req.method()
                            + " "
                            + req.target()
                            + " "
                            + new String(req.readBody(1024), StandardCharsets.UTF_8));
                    return null;
                  },
                  HandlerOptions.defaults());
      Server server = new Server();
      ServerConnector connector = new ServerConnector(server);
      connector.setHost(InetAddress.getLoopbackAddress().getHostAddress());
      server.addConnector(connector);
      ServletContextHandler context = new ServletContextHandler("/");
      context.addServlet(new ServletHolder(new CronwatchServlet(handler)), "/api/cron/served");
      server.setHandler(context);
      server.start();
      try {
        int port = port(server);
        RawHttp.Answer ok =
            RawHttp.send(
                port,
                "POST",
                "/api/cron/served?x=1",
                List.of(Map.entry("authorization", "Bearer " + secret)),
                "over the wire".getBytes(StandardCharsets.UTF_8));
        assertEquals(200, ok.status(), ok.text());
        assertTrue(ok.text().startsWith("{\"ok\":true,\"job\":\"served\",\"run\":\""), ok.text());
        assertEquals(
            "POST /api/cron/served?x=1 over the wire", cw.runs("served", 1).get(0).output());
        assertEquals(401, RawHttp.send(port, "POST", "/api/cron/served", List.of(), null).status());
      } finally {
        server.stop();
      }
    }
  }

  @Test
  void nothingPrintsASecret() {
    try (Cronwatch cw = Cronwatch.builder().noCronSecret().noShutdownHook().build()) {
      String token = "t0k" + "-value";
      CronwatchFilter filter =
          new CronwatchFilter(cw.routes(RoutesOptions.builder().token(token).build()));
      assertTrue(!filter.toString().contains(token), filter.toString());
      assertEquals("/cronwatch", filter.path());
    }
  }
}
