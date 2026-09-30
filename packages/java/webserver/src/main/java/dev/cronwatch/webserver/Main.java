package dev.cronwatch.webserver;

import com.sun.net.httpserver.HttpServer;
import dev.cronwatch.Alert;
import dev.cronwatch.Channel;
import dev.cronwatch.ChannelContext;
import dev.cronwatch.Cronwatch;
import dev.cronwatch.Job;
import dev.cronwatch.JobOptions;
import dev.cronwatch.web.RoutesOptions;
import dev.cronwatch.web.WebServer;
import java.io.IOException;
import java.net.InetAddress;
import java.net.InetSocketAddress;
import java.util.concurrent.Executors;
import java.util.concurrent.atomic.AtomicLong;

/**
 * Serves the dashboard over HTTP for {@code packages/mcp/test/java-web.test.ts}, which drives
 * {@code @cronwatch/mcp} against it. Seeded like the MCP tests' own end-to-end case: a {@code
 * nightly} job with one good run and one failed one, and a fixed clock. Mounted on the JDK's own
 * server at {@code /cronwatch}, so the routes find their base path from the context. Alerts are
 * printed as {@code alert <job> <type>} lines.
 *
 * <pre>
 * java -jar webserver/target/cronwatch-webserver.jar PORT
 * </pre>
 */
public final class Main {
  private Main() {}

  /** 2026-01-05 02:00:00 UTC. */
  private static final long START = 1_767_578_400_000L;

  /** Serves on the port given. */
  public static void main(String[] args) throws IOException {
    if (args.length != 1) {
      System.err.println("usage: cronwatch-webserver PORT");
      System.exit(2);
    }
    int port = Integer.parseInt(args[0]);
    AtomicLong now = new AtomicLong(START);
    Channel printer =
        new Channel() {
          @Override
          public String name() {
            return "test";
          }

          @Override
          public void send(Alert alert, ChannelContext context) {
            System.out.println("alert " + alert.job() + " " + alert.type().value());
          }
        };
    Cronwatch cw =
        Cronwatch.builder().alert(printer).noCronSecret().noShutdownHook().clock(now::get).build();
    Job nightly =
        cw.job("nightly", JobOptions.builder().schedule("0 2 * * *").timezone("UTC").grace("15m"));
    nightly.run(job -> job.log("step 1"));
    now.addAndGet(60_000);
    try {
      nightly.run(
          job -> {
            job.log("step 2");
            throw new IllegalStateException("db down");
          });
    } catch (IllegalStateException e) {
      // The failed run is the seed.
    }

    HttpServer server =
        HttpServer.create(new InetSocketAddress(InetAddress.getLoopbackAddress(), port), 0);
    server.setExecutor(Executors.newVirtualThreadPerTaskExecutor());
    WebServer.mount(server, "/cronwatch", cw.routes(RoutesOptions.builder().token("tok").build()));
    server.start();
    System.out.println("serving on " + port);
  }
}
