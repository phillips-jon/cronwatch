package dev.cronwatch;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertNotNull;
import static org.junit.jupiter.api.Assertions.assertNull;
import static org.junit.jupiter.api.Assertions.assertSame;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;

import java.io.IOException;
import java.util.List;
import java.util.concurrent.CopyOnWriteArrayList;
import java.util.concurrent.atomic.AtomicLong;
import org.junit.jupiter.api.Test;

/** A client end to end over the memory store: a run, a failure and its alert, a check, a handle. */
class SmokeTest {
  @Test
  void aJobRunsFailsAlertsAndRecovers() throws Exception {
    AtomicLong clock = new AtomicLong(1_767_605_400_000L);
    List<Alert> sent = new CopyOnWriteArrayList<>();
    List<String> errors = new CopyOnWriteArrayList<>();
    try (Cronwatch cw =
        Cronwatch.builder()
            .alert(Channel.of("test", (alert, ctx) -> sent.add(alert)))
            .onError((where, e) -> errors.add(where + ": " + e.getMessage()))
            .clock(clock::get)
            .noShutdownHook()
            .build()) {
      Job job = cw.job("nightly", JobOptions.builder().schedule("0 2 * * *").timezone("UTC"));
      String out = job.call(ctx -> "done");
      assertEquals("done", out);
      IOException thrown =
          assertThrows(
              IOException.class,
              () ->
                  job.run(
                      ctx -> {
                        ctx.log("before");
                        throw new IOException("disk full");
                      }));
      assertEquals("disk full", thrown.getMessage());
      assertEquals(1, sent.size(), () -> "alerts: " + sent);
      Alert alert = sent.get(0);
      assertEquals(AlertType.FAILED, alert.type());
      assertEquals("nightly failed", alert.title());
      assertTrue(alert.message().contains("IOException: disk full"), alert.message());

      job.run(ctx -> ctx.log("fine"));
      assertEquals(2, sent.size());
      assertEquals(AlertType.RECOVERED, sent.get(1).type());

      List<Run> runs = cw.runs("nightly", 10);
      assertEquals(3, runs.size());
      assertEquals(RunStatus.OK, runs.get(0).status());
      assertEquals("fine", runs.get(0).output());

      CheckResult result = cw.check();
      assertEquals(1, result.jobs().size());
      assertEquals(JobHealth.HEALTHY, result.jobs().get(0).health());

      RunHandle handle = job.start();
      assertTrue(handle.isActive());
      handle.log("half way");
      handle.flush();
      handle.log("the rest");
      Run finished = handle.finish();
      assertNotNull(finished);
      assertEquals("half way\nthe rest", finished.output());
      assertNull(handle.finish());
      assertTrue(errors.stream().anyMatch(e -> e.contains("was already finished by this handle")));
    }
  }

  @Test
  void aRunAfterCloseStillRunsAndIsRecorded() {
    Cronwatch cw = Cronwatch.builder().alerts(List.of()).noShutdownHook().build();
    Job job = cw.job("late");
    cw.close();
    job.run(ctx -> ctx.log("after close"));
    cw.start();
    assertEquals("after close", cw.runs("late", 1).get(0).output());
  }

  @Test
  void theRunIsCurrentInItsThread() throws Exception {
    try (Cronwatch cw = Cronwatch.builder().alerts(List.of()).noShutdownHook().build()) {
      assertNull(Cronwatch.current());
      JobContext[] seen = new JobContext[2];
      cw.run(
          "current",
          ctx -> {
            seen[0] = Cronwatch.current();
            Thread t =
                Thread.ofVirtual()
                    .start(
                        ctx.wrap(
                            () -> {
                              seen[1] = Cronwatch.current();
                            }));
            t.join();
          });
      assertNotNull(seen[0]);
      assertSame(seen[0], seen[1]);
      assertNull(Cronwatch.current());
    }
  }
}
