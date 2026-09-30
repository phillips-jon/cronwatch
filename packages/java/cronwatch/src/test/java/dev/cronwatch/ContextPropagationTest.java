package dev.cronwatch;

import static org.junit.jupiter.api.Assertions.assertNotNull;
import static org.junit.jupiter.api.Assertions.assertNull;
import static org.junit.jupiter.api.Assertions.assertSame;

import io.micrometer.context.ContextSnapshot;
import io.micrometer.context.ContextSnapshotFactory;
import java.util.List;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.TimeUnit;
import org.junit.jupiter.api.Test;

/**
 * Micrometer's context propagation carries the current run to another thread with no code of the
 * job's own, through the accessor the core registers, and leaves nothing behind on the thread.
 */
class ContextPropagationTest {
  @Test
  void aSnapshotCarriesTheRunToAPooledThread() throws Exception {
    ContextSnapshotFactory factory = ContextSnapshotFactory.builder().build();
    ExecutorService pool = Executors.newSingleThreadExecutor();
    try (Cronwatch cw = Cronwatch.builder().alerts(List.of()).noShutdownHook().build()) {
      JobContext[] seen = new JobContext[3];
      cw.run(
          "propagated",
          ctx -> {
            seen[0] = Cronwatch.current();
            ContextSnapshot snapshot = factory.captureAll();
            pool.submit(
                    snapshot.wrap(
                        () -> {
                          seen[1] = Cronwatch.current();
                        }))
                .get(30, TimeUnit.SECONDS);
          });
      pool.submit(
              () -> {
                seen[2] = Cronwatch.current();
              })
          .get(30, TimeUnit.SECONDS);
      assertNotNull(seen[0]);
      assertSame(seen[0], seen[1], "the run, carried by the snapshot");
      assertNull(seen[2], "nothing left on the pooled thread");
    } finally {
      pool.shutdownNow();
    }
  }
}
