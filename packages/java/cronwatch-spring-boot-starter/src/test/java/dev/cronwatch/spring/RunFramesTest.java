package dev.cronwatch.spring;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertNull;

import org.junit.jupiter.api.Test;

/**
 * The per-thread frames ShedLock's lock provider reads. Spring observes a reactive
 * {@code @Scheduled} method around its subscription, started in the scheduler's thread and stopped
 * in whichever thread the publisher completes on: a frame pushed in one thread and popped in
 * another stayed on the first for good, one more each invocation, on a pooled thread.
 */
class RunFramesTest {
  @Test
  void aFrameEndedOnAnotherThreadLeavesNothingBehind() throws Exception {
    for (int i = 0; i < 100; i++) {
      RunFrames.Frame frame = RunFrames.push(null);
      Thread other = Thread.ofPlatform().start(() -> RunFrames.pop(frame));
      other.join();
    }
    assertEquals(0, RunFrames.depth());
  }

  @Test
  void framesNestInTheirThread() {
    RunFrames.Frame outer = RunFrames.push(null);
    RunFrames.Frame inner = RunFrames.push(null);
    RunFrames.lockAnswered(false);
    assertEquals(false, inner.lockTaken);
    assertNull(outer.lockTaken);
    RunFrames.pop(inner);
    RunFrames.pop(outer);
    assertEquals(0, RunFrames.depth());
  }
}
