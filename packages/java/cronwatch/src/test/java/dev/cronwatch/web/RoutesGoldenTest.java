package dev.cronwatch.web;

import static org.junit.jupiter.api.Assertions.assertEquals;

import com.sun.net.httpserver.HttpServer;
import dev.cronwatch.webtest.Golden;
import java.net.InetAddress;
import java.net.InetSocketAddress;
import java.util.List;
import java.util.Set;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import org.junit.jupiter.api.Test;

/**
 * Replays {@code golden.json} against {@code cw.routes()} seeded as {@code golden.mjs} seeds the
 * SDK's: straight into {@link Routes#handle}, and through the JDK's own server with the dashboard
 * mounted at {@code /cronwatch}, its base path found from the context (which refuses the two
 * captures whose target is not a URI itself). The servlet filter and the Spring Boot starter replay
 * it through their own servers.
 */
class RoutesGoldenTest {
  @Test
  void theRoutesMatchTheSdkStraightIntoHandle() {
    Golden.Seeded seeded = Golden.seed();
    try (var cw = seeded.cw()) {
      Routes routes =
          cw.routes(RoutesOptions.builder().token("tok").basePath("/cronwatch").build());
      Golden.Ids ids = new Golden.Ids();
      for (Golden.Capture c : Golden.captures()) {
        Response r = routes.handle(Golden.request(c, Golden.resolve(cw, c.path())));
        Golden.compare(c, r.status(), r.headers(), r.body(), ids, Set.of());
      }
      // As golden.mjs: nothing in the seed or the requests reports an error, however far off a
      // run's start is.
      assertEquals(List.of(), seeded.errors());
    }
  }

  @Test
  void theRoutesMatchTheSdkThroughTheJdkServer() throws Exception {
    Golden.Seeded seeded = Golden.seed();
    HttpServer server =
        HttpServer.create(new InetSocketAddress(InetAddress.getLoopbackAddress(), 0), 0);
    try (var cw = seeded.cw();
        ExecutorService pool = Executors.newVirtualThreadPerTaskExecutor()) {
      server.setExecutor(pool);
      // No base path: it is found from the context the dashboard is mounted at.
      WebServer.mount(
          server, "/cronwatch", cw.routes(RoutesOptions.builder().token("tok").build()));
      server.start();
      // The JDK's server refuses a request target that is not a URI (the two %zz paths) before
      // any handler sees it, so those two are its own 400s.
      int matched =
          Golden.throughServer(
              seeded, server.getAddress().getPort(), Set.of("date"), Golden.MALFORMED_TARGETS);
      assertEquals(Golden.CAPTURES - 2, matched);
    } finally {
      server.stop(0);
    }
  }
}
