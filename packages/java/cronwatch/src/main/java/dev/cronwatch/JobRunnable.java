package dev.cronwatch;

/**
 * A job's function that returns nothing, for {@link Job#run}. It may throw anything, checked or
 * not: {@code E} is inferred from what the lambda's body throws, so {@code run} throws exactly
 * that, and nothing checked when the body throws nothing checked.
 *
 * @param <E> what the function throws
 */
@FunctionalInterface
public interface JobRunnable<E extends Exception> {
  /**
   * Does the job's work.
   *
   * @throws E what the work throws; it fails the run and is thrown again from {@code run}
   */
  void run(JobContext job) throws E;
}
