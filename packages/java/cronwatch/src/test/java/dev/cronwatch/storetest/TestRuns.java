package dev.cronwatch.storetest;

import dev.cronwatch.Run;
import dev.cronwatch.RunStatus;

/** The contract's runs, for the stores' own tests in other packages. */
public final class TestRuns {
  private TestRuns() {}

  /**
   * A run as the contract writes them: finished ten milliseconds after it started unless it is
   * running, with one metric, {@code n}, of 1.
   */
  public static Run newRun(String id, String job, RunStatus status, long startedAt) {
    return StoreContract.newRun(id, job, status, startedAt);
  }
}
