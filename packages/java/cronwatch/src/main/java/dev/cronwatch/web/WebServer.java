package dev.cronwatch.web;

import com.sun.net.httpserver.HttpContext;
import com.sun.net.httpserver.HttpExchange;
import com.sun.net.httpserver.HttpHandler;
import com.sun.net.httpserver.HttpServer;
import com.sun.net.httpserver.HttpsExchange;
import dev.cronwatch.internal.web.Text;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.net.URI;
import java.util.List;
import java.util.Map;
import java.util.Objects;
import org.jspecify.annotations.Nullable;

/**
 * The dashboard or a job's handler on the JDK's own HTTP server ({@code com.sun.net.httpserver}),
 * for a program with no framework:
 *
 * <pre>{@code
 * HttpServer server = HttpServer.create(new InetSocketAddress(8080), 0);
 * server.setExecutor(Executors.newVirtualThreadPerTaskExecutor());
 * WebServer.mount(server, "/cronwatch", cw.routes(RoutesOptions.defaults()));
 * WebServer.mount(server, "/cron/nightly", nightly.handler((job, request) -> build(job)));
 * server.start();
 * }</pre>
 *
 * <p>The routes read the store, so give the server an executor of virtual threads (the JDK's
 * default runs every exchange on its one dispatcher thread). The request target is the exchange's
 * raw path and query, so a {@code %2F} in a job name stays one, and the dashboard's base path is
 * the context's. A client that goes away before its answer is written is not reported.
 */
public final class WebServer {
  private WebServer() {}

  /**
   * Adds a context at {@code path} that {@code endpoint} answers, the dashboard's base path being
   * the context's.
   */
  public static HttpContext mount(HttpServer server, String path, Endpoint endpoint) {
    Objects.requireNonNull(endpoint, "endpoint");
    return server.createContext(path, handler(endpoint));
  }

  /** {@code endpoint} as an {@link HttpHandler}, for a context the app creates itself. */
  public static HttpHandler handler(Endpoint endpoint) {
    Objects.requireNonNull(endpoint, "endpoint");
    return exchange -> serve(endpoint, exchange);
  }

  private static void serve(Endpoint endpoint, HttpExchange exchange) throws IOException {
    try (exchange) {
      Response answer = endpoint.handle(request(exchange));
      for (Map.Entry<String, String> h : answer.headers()) {
        exchange.getResponseHeaders().add(h.getKey(), h.getValue());
      }
      boolean head = exchange.getRequestMethod().equalsIgnoreCase("HEAD");
      int length = answer.bodyLength();
      try {
        exchange.sendResponseHeaders(answer.status(), head || length == 0 ? -1 : length);
        if (!head && length > 0) {
          OutputStream out = exchange.getResponseBody();
          answer.writeBody(out);
          out.flush();
        }
      } catch (IOException e) {
        // The client went away before its answer was written: nothing to report.
      }
    }
  }

  /** The exchange as a {@link Request}, its body read only when a route wants it. */
  static Request request(HttpExchange exchange) {
    URI uri = exchange.getRequestURI();
    String raw = uri.getRawPath() == null ? "/" : uri.getRawPath();
    String query = uri.getRawQuery();
    String target = Text.utf8OrAsIs(query == null ? raw : raw + "?" + query);
    Request.Builder b =
        Request.builder(exchange.getRequestMethod(), target).tls(exchange instanceof HttpsExchange);
    String context = exchange.getHttpContext().getPath();
    b.mount(context);
    for (Map.Entry<String, List<String>> h : exchange.getRequestHeaders().entrySet()) {
      for (String v : h.getValue()) {
        b.header(h.getKey(), v);
      }
    }
    long length = declaredLength(exchange.getRequestHeaders().getFirst("content-length"));
    InputStream in = exchange.getRequestBody();
    b.body(length, limit -> in.readNBytes(limit + 1));
    return b.build();
  }

  static long declaredLength(@Nullable String value) {
    if (value == null) {
      return -1;
    }
    try {
      return Long.parseLong(value.trim());
    } catch (NumberFormatException e) {
      return -1;
    }
  }
}
