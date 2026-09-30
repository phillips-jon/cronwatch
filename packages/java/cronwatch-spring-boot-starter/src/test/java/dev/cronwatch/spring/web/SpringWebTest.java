package dev.cronwatch.spring.web;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertTrue;

import dev.cronwatch.Cronwatch;
import dev.cronwatch.web.Request;
import dev.cronwatch.webtest.Golden;
import dev.cronwatch.webtest.RawHttp;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.List;
import java.util.Map;
import java.util.Objects;
import java.util.Set;
import java.util.concurrent.atomic.AtomicLong;
import org.junit.jupiter.api.Test;
import org.springframework.boot.SpringBootConfiguration;
import org.springframework.boot.autoconfigure.EnableAutoConfiguration;
import org.springframework.boot.builder.SpringApplicationBuilder;
import org.springframework.context.ConfigurableApplicationContext;
import org.springframework.context.support.GenericApplicationContext;

/**
 * The dashboard through the starter, in a real Spring Boot app: the golden replay on Spring MVC
 * under Tomcat (behind Spring's {@code HiddenHttpMethodFilter}, which reads a form post's body
 * before the dashboard does) and on WebFlux under Netty, each with its base path found from where
 * the filter is; a context path and another dashboard path; and the settings.
 */
class SpringWebTest {
  /** The app: nothing but auto-configuration, and the client the test registers. */
  @SpringBootConfiguration
  @EnableAutoConfiguration
  static class App {}

  private static ConfigurableApplicationContext start(Cronwatch cw, String type, String... more) {
    List<String> properties = new ArrayList<>();
    properties.add("server.port=0");
    properties.add("server.address=127.0.0.1");
    properties.add("spring.main.web-application-type=" + type);
    properties.add("spring.main.banner-mode=off");
    properties.add("logging.level.root=warn");
    properties.addAll(List.of(more));
    return new SpringApplicationBuilder(App.class)
        .initializers(
            c -> {
              c.getBeanFactory().registerSingleton("cronwatch", cw);
              if (type.equals("reactive")) {
                ((GenericApplicationContext) c).registerBean(nettyFactory());
              }
            })
        .properties(properties.toArray(String[]::new))
        .run();
  }

  /**
   * Reactor Netty's server factory. With Tomcat on the class path too (the MVC tests need it),
   * Spring Boot 3.5 serves a reactive app on Tomcat, which writes a content-type back its own way;
   * Boot 4 has each server in a module of its own, where the factory's package moved.
   */
  private static Class<?> nettyFactory() {
    for (String name :
        List.of(
            "org.springframework.boot.reactor.netty.NettyReactiveWebServerFactory",
            "org.springframework.boot.web.embedded.netty.NettyReactiveWebServerFactory")) {
      try {
        return Class.forName(name);
      } catch (ClassNotFoundException e) {
        // The other Boot line's.
      }
    }
    throw new IllegalStateException("no NettyReactiveWebServerFactory");
  }

  private static int port(ConfigurableApplicationContext context) {
    return Integer.parseInt(
        Objects.requireNonNull(context.getEnvironment().getProperty("local.server.port")));
  }

  @Test
  void theRoutesMatchTheSdkOnSpringMvcUnderTomcat() throws Exception {
    Golden.Seeded seeded = Golden.seed();
    try (Cronwatch cw = seeded.cw();
        ConfigurableApplicationContext context =
            start(
                cw,
                "servlet",
                "cronwatch.web.token=tok",
                "spring.mvc.hiddenmethod.filter.enabled=true")) {
      // Tomcat refuses a request target that is not a URI (the two %zz paths) itself, and writes a
      // content-type back without the space after its ";".
      int matched =
          Golden.throughServer(
              seeded,
              port(context),
              Set.of("date", "connection", "keep-alive"),
              Golden.MALFORMED_TARGETS,
              true);
      assertEquals(Golden.CAPTURES - 2, matched);
    }
  }

  @Test
  void theRoutesMatchTheSdkOnWebFluxUnderNetty() throws Exception {
    Golden.Seeded seeded = Golden.seed();
    try (Cronwatch cw = seeded.cw();
        ConfigurableApplicationContext context = start(cw, "reactive", "cronwatch.web.token=tok")) {
      int matched =
          Golden.throughServer(
              seeded, port(context), Set.of("date", "connection"), Golden.MALFORMED_TARGETS);
      assertEquals(Golden.CAPTURES - 2, matched);
    }
  }

  private static RawHttp.Answer get(int port, String path) throws Exception {
    return RawHttp.send(port, "GET", path, List.of(), null);
  }

  @Test
  void theBaseIsTheContextPathAndTheDashboardsPath() throws Exception {
    for (String type : List.of("servlet", "reactive")) {
      String contextPath =
          type.equals("servlet")
              ? "server.servlet.context-path=/app"
              : "spring.webflux.base-path=/app";
      try (Cronwatch cw = Cronwatch.builder().noCronSecret().noShutdownHook().build()) {
        cw.run("x", job -> {});
        try (ConfigurableApplicationContext context =
            start(
                cw, type, contextPath, "cronwatch.web.path=/ops/cron", "cronwatch.web.open=true")) {
          int port = port(context);
          RawHttp.Answer manifest = get(port, "/app/ops/cron/manifest.webmanifest");
          assertEquals(200, manifest.status(), type);
          assertTrue(manifest.text().contains("\"id\":\"/app/ops/cron/\""), type + manifest.text());
          assertTrue(
              get(port, "/app/ops/cron/").text().contains("href=\"/app/ops/cron/jobs/x\""), type);
          assertEquals(200, get(port, "/app/ops/cron/jobs/x").status(), type + ": the job page");
          assertEquals(200, get(port, "/app/ops/cron/api/jobs").status(), type + ": open");
          assertEquals(404, get(port, "/app/cronwatch/").status(), type + ": not at the default");
        }
      }
    }
  }

  @Test
  void theBodyCapThroughEach() throws Exception {
    for (String type : List.of("servlet", "reactive")) {
      AtomicLong clock = new AtomicLong(Golden.T0);
      try (Cronwatch cw =
          Cronwatch.builder().clock(clock::get).noCronSecret().noShutdownHook().build()) {
        cw.run("s", job -> {});
        try (ConfigurableApplicationContext context = start(cw, type, "cronwatch.web.token=tok")) {
          List<Map.Entry<String, String>> form =
              List.of(
                  Map.entry("authorization", "Bearer tok"),
                  Map.entry("content-type", "application/x-www-form-urlencoded"));
          String exact = "for=2h&pad=";
          exact += "x".repeat(Request.MAX_BODY - exact.length());
          RawHttp.Answer atTheCap =
              RawHttp.send(
                  port(context),
                  "POST",
                  "/cronwatch/api/jobs/s/silence",
                  form,
                  exact.getBytes(StandardCharsets.UTF_8));
          assertEquals(200, atTheCap.status(), type + ": a body of exactly 1 MiB is read");
          assertEquals(Golden.T0 + 2 * 3_600_000, cw.jobSummary("s").silencedUntil(), type);
        }
      }
    }
  }

  @Test
  void theSettingsNeverPrintTheToken() {
    CronwatchWebProperties p = new CronwatchWebProperties();
    String token = "t0k" + "-value";
    p.setToken(token);
    assertFalse(p.toString().contains(token), p.toString());
    assertEquals(-110, p.getOrder());
  }
}
