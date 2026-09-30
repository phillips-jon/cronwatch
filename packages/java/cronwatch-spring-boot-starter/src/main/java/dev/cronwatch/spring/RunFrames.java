package dev.cronwatch.spring;

import dev.cronwatch.ObservedRun;
import java.util.Deque;
import java.util.concurrent.ConcurrentLinkedDeque;
import org.jspecify.annotations.Nullable;

/**
 * The {@code @Scheduled} runs open in each thread, innermost last, so ShedLock's wrapped lock
 * provider can tell the run whose method it is guarding whether its lock was taken. A method that
 * is not watched pushes a frame with no run, so every start pairs with its end however methods
 * nest. The thread's entry is removed when its last frame is, so no pooled thread keeps one.
 */
final class RunFrames {
  private static final ThreadLocal<Deque<Frame>> STACK = new ThreadLocal<>();

  private RunFrames() {}

  /** One {@code @Scheduled} invocation in a thread. */
  static final class Frame {
    final @Nullable ObservedRun run;

    /** The stack of the thread the invocation started in, which it is taken off at its end. */
    final Deque<Frame> stack;

    /** The thread the invocation started in. */
    final Thread thread = Thread.currentThread();

    /** What the first lock asked for in the invocation answered: null until one was asked. */
    volatile @Nullable Boolean lockTaken;

    Frame(@Nullable ObservedRun run, Deque<Frame> stack) {
      this.run = run;
      this.stack = stack;
    }
  }

  /** Pushes a frame for an invocation starting in this thread. */
  static Frame push(@Nullable ObservedRun run) {
    Deque<Frame> stack = STACK.get();
    if (stack == null) {
      stack = new ConcurrentLinkedDeque<>();
      STACK.set(stack);
    }
    Frame f = new Frame(run, stack);
    stack.push(f);
    return f;
  }

  /**
   * Removes {@code frame} from the stack of the thread it started in, whichever thread ends it (a
   * reactive method's observation stops where its publisher completes), and in that thread the
   * stack with its last frame.
   */
  static void pop(Frame frame) {
    frame.stack.removeFirstOccurrence(frame);
    if (Thread.currentThread().equals(frame.thread) && frame.stack.isEmpty()) {
      STACK.remove();
    }
  }

  /** How many invocations are open in this thread. */
  static int depth() {
    Deque<Frame> stack = STACK.get();
    return stack == null ? 0 : stack.size();
  }

  /**
   * Tells the innermost invocation in this thread what its first lock answered; a later lock in the
   * same invocation (one the method takes itself) changes nothing.
   */
  static void lockAnswered(boolean taken) {
    Deque<Frame> stack = STACK.get();
    Frame top = stack == null ? null : stack.peek();
    if (top != null && top.lockTaken == null) {
      top.lockTaken = taken;
    }
  }
}
