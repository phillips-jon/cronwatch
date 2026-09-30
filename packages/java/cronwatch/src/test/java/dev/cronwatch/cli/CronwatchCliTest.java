package dev.cronwatch.cli;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertTrue;

import dev.cronwatch.Cronwatch;
import dev.cronwatch.CronwatchException;
import dev.cronwatch.JobOptions;
import dev.cronwatch.store.MemoryStore;
import dev.cronwatch.store.Store;
import java.io.ByteArrayOutputStream;
import java.io.PrintStream;
import java.lang.reflect.Proxy;
import java.nio.charset.StandardCharsets;
import java.util.List;
import org.junit.jupiter.api.Test;

/**
 * {@code CronwatchCli}: one check from a crontab line, which answers its status and never exits.
 */
class CronwatchCliTest {
  private final ByteArrayOutputStream out = new ByteArrayOutputStream();
  private final ByteArrayOutputStream err = new ByteArrayOutputStream();

  /** What a stream took, with Windows line ends read as the others. */
  private static String text(ByteArrayOutputStream stream) {
    return stream.toString(StandardCharsets.UTF_8).replace("\r\n", "\n");
  }

  private int run(java.util.function.Supplier<Cronwatch> factory, String... args) {
    return CronwatchCli.run(
        factory,
        args,
        new PrintStream(out, true, StandardCharsets.UTF_8),
        new PrintStream(err, true, StandardCharsets.UTF_8));
  }

  private static Cronwatch client(MemoryStore store) {
    return Cronwatch.builder().store(store).alerts(List.of()).noShutdownHook().build();
  }

  @Test
  void checkRunsOneCheck() throws Exception {
    MemoryStore store = new MemoryStore();
    int status =
        run(
            () -> {
              Cronwatch cw = client(store);
              cw.job("nightly", JobOptions.builder().schedule("0 2 * * *"));
              return cw;
            },
            "check");
    assertEquals(0, status, text(err));
    assertEquals("cronwatch: checked 1 job, sent 0 alerts\n", text(out));
    assertEquals("", text(err));
    assertEquals(1, store.listJobs().size(), "the check wrote the declaration");
  }

  /** A store whose every call fails. */
  private static Store down() {
    return (Store)
        Proxy.newProxyInstance(
            Store.class.getClassLoader(),
            new Class<?>[] {Store.class},
            (proxy, method, args) -> {
              if (method.getName().equals("toString")) {
                return "down";
              }
              throw new IllegalStateException("the database is down");
            });
  }

  @Test
  void aFailedCheckIsStatusOneOnStandardError() {
    int status =
        run(
            () -> Cronwatch.builder().store(down()).alerts(List.of()).noShutdownHook().build(),
            "check");
    assertEquals(1, status);
    assertTrue(text(err).startsWith("cronwatch: the check failed: "), text(err));
    assertTrue(text(err).contains("the database is down"));
  }

  @Test
  void aFactoryThatThrowsIsStatusOne() {
    int status =
        run(
            () -> {
              throw CronwatchException.invalid("no store configured");
            },
            "check");
    assertEquals(1, status);
    assertEquals("cronwatch: the client could not be made: no store configured\n", text(err));
  }

  @SuppressWarnings("unchecked")
  private static <E extends Exception> Cronwatch sneaky(Exception e) throws E {
    throw (E) e;
  }

  /**
   * A factory written in a language without checked exceptions (Kotlin, or Lombok's
   * {@code @SneakyThrows}) can throw one anyway: it escaped {@code run}, which promises a status.
   */
  @Test
  void aFactoryThatThrowsACheckedExceptionIsStatusOne() {
    int status = run(() -> sneaky(new java.io.IOException("config not found")), "check");
    assertEquals(1, status);
    assertEquals("cronwatch: the client could not be made: config not found\n", text(err));
  }

  @Test
  void anUnknownCommandIsStatusTwoWithTheUsage() {
    assertEquals(2, run(() -> client(new MemoryStore()), "run", "nightly"));
    assertTrue(text(err).startsWith("cronwatch: unknown command run nightly\n"));
    assertTrue(text(err).contains("usage: cronwatch check"));
    err.reset();
    assertEquals(2, run(() -> client(new MemoryStore())));
    assertTrue(text(err).startsWith("cronwatch: no command given\n"));
    assertEquals(0, run(() -> client(new MemoryStore()), "--help"));
    assertTrue(text(out).startsWith("usage: cronwatch check"));
  }
}
