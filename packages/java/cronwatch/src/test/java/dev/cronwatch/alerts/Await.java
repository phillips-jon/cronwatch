package dev.cronwatch.alerts;

import java.util.function.BooleanSupplier;

/** Waits for something asynchronous, polling, for up to 30 seconds. */
final class Await {
  private Await() {}

  /** Whether the condition came true within 30 seconds. */
  static boolean until(BooleanSupplier condition) throws InterruptedException {
    long deadline = System.nanoTime() + 30_000_000_000L;
    while (System.nanoTime() < deadline) {
      if (condition.getAsBoolean()) {
        return true;
      }
      Thread.sleep(10);
    }
    return condition.getAsBoolean();
  }
}
