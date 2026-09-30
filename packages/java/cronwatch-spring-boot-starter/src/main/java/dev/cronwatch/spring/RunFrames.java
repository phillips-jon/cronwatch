package dev.cronwatch.spring;

import dev.cronwatch.ObservedRun;
import java.util.ArrayDeque;
import org.jspecify.annotations.Nullable;

/**
 * The {@code @Scheduled} runs open in each thread, innermost last, so ShedLock's wrapped lock
 * provider can tell the run whose method it is guarding whether its lock was taken. A method that
 * is not watched pushes a frame with no run, so every start pairs with its end however methods
 * nest. The thread's entry is removed when its last frame is, so no pooled thread keeps one.
 */
final class RunFrames {
  private static final ThreadLocal<ArrayDeque<Frame>> STACK = new ThreadLocal<>();

  private RunFrames() {}

  /** One {@code @Scheduled} invocation in a thread. */
  static final class Frame {
    final @Nullable ObservedRun run;

    /** What the first lock asked for in the invocation answered: null until one was asked. */
    @Nullable Boolean lockTaken;

    Frame(@Nullable ObservedRun run) {
      this.run = run;
    }
  }

  /** Pushes a frame for an invocation starting in this thread. */
  static Frame push(@Nullable ObservedRun run) {
    ArrayDeque<Frame> stack = STACK.get();
    if (stack == null) {
      stack = new ArrayDeque<>();
      STACK.set(stack);
    }
    Frame f = new Frame(run);
    stack.push(f);
    return f;
  }

  /** Removes {@code frame} from this thread's stack, and the stack with its last frame. */
  static void pop(Frame frame) {
    ArrayDeque<Frame> stack = STACK.get();
    if (stack == null) {
      return;
    }
    stack.removeFirstOccurrence(frame);
    if (stack.isEmpty()) {
      STACK.remove();
    }
  }

  /**
   * Tells the innermost invocation in this thread what its first lock answered; a later lock in the
   * same invocation (one the method takes itself) changes nothing.
   */
  static void lockAnswered(boolean taken) {
    ArrayDeque<Frame> stack = STACK.get();
    if (stack == null || stack.isEmpty()) {
      return;
    }
    Frame top = stack.peek();
    if (top.lockTaken == null) {
      top.lockTaken = taken;
    }
  }
}
