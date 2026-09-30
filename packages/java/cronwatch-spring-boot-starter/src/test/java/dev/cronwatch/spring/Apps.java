package dev.cronwatch.spring;

import static org.junit.jupiter.api.Assertions.assertNotNull;
import static org.junit.jupiter.api.Assertions.assertTrue;

import dev.cronwatch.Cronwatch;
import dev.cronwatch.ErrorHandler;
import dev.cronwatch.Run;
import dev.cronwatch.RunStatus;
import dev.cronwatch.StoredJob;
import dev.cronwatch.store.Store;
import java.util.ArrayList;
import java.util.List;
import java.util.concurrent.CopyOnWriteArrayList;
import java.util.function.BooleanSupplier;
import org.jspecify.annotations.Nullable;
import org.springframework.boot.WebApplicationType;
import org.springframework.boot.builder.SpringApplicationBuilder;
import org.springframework.context.ConfigurableApplicationContext;

/** What the starter's tests share: a Spring Boot app run with a store and errors of the test's. */
final class Apps {
  private Apps() {}

  /** The errors a client reported, as {@code where: message}. */
  static final class Errors implements ErrorHandler {
    final List<String> seen = new CopyOnWriteArrayList<>();

    @Override
    public void handle(String where, Throwable error) {
      seen.add(where + ": " + error.getMessage());
    }

    String joined() {
      return String.join("\n", seen);
    }
  }

  /**
   * Runs {@code config} as a Spring Boot app with no web server, {@code store} and {@code errors}
   * as beans, and the properties given ({@code key=value}).
   */
  static ConfigurableApplicationContext run(
      Class<?> config, @Nullable Store store, Errors errors, String... properties) {
    List<String> props = new ArrayList<>(List.of(properties));
    props.add("spring.main.banner-mode=off");
    props.add("cronwatch.shutdown-hook=false");
    return new SpringApplicationBuilder(config)
        .web(WebApplicationType.NONE)
        .properties(props.toArray(String[]::new))
        .initializers(
            ctx -> {
              if (store != null) {
                ctx.getBeanFactory().registerSingleton("testStore", store);
              }
              ctx.getBeanFactory().registerSingleton("testErrors", errors);
            })
        .run();
  }

  /** The definition {@code store} holds for {@code name}, as JSON. */
  static String stored(Store store, String name) throws Exception {
    StoredJob job = store.getJob(name);
    assertNotNull(job, name + " is not stored");
    return job.definition().toJson();
  }

  /** {@link #stored}, or {@code ""} while it is not there. */
  static String storedOrEmpty(Store store, String name) {
    try {
      StoredJob job = store.getJob(name);
      return job == null ? "" : job.definition().toJson();
    } catch (Exception e) {
      return "";
    }
  }

  /** The runs of {@code name} that have finished, newest first. */
  static List<Run> finished(Cronwatch cw, String name) {
    return cw.runs(name, 50).stream().filter(r -> !r.status().equals(RunStatus.RUNNING)).toList();
  }

  /** Waits up to twenty seconds for {@code condition}, polling, and fails with {@code what}. */
  static void await(String what, BooleanSupplier condition) throws InterruptedException {
    long deadline = System.nanoTime() + 20_000_000_000L;
    while (!condition.getAsBoolean()) {
      if (System.nanoTime() > deadline) {
        assertTrue(condition.getAsBoolean(), "waited twenty seconds for: " + what);
        return;
      }
      Thread.sleep(20);
    }
  }
}
