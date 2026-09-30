package dev.cronwatch;

import org.jspecify.annotations.Nullable;

/**
 * A job's function that returns a value, for {@link Job#call}. A {@code String} it returns is the
 * run's output when nothing was logged (and what an expect rule checks); an HTTP answer of 400 or
 * more ({@code java.net.http.HttpResponse}, Spring's {@code ResponseEntity}) fails the run. It may
 * throw anything, checked or not: {@code E} is inferred from what the lambda's body throws.
 *
 * @param <T> what the function returns
 * @param <E> what the function throws
 */
@FunctionalInterface
public interface JobCallable<T extends @Nullable Object, E extends Exception> {
  /**
   * Does the job's work.
   *
   * @throws E what the work throws; it fails the run and is thrown again from {@code call}
   */
  T call(JobContext job) throws E;
}
