package dev.cronwatch.web;

import dev.cronwatch.JobContext;
import org.jspecify.annotations.Nullable;

/**
 * A job's function as a {@link Handler} runs it: given the run's context and the request. What it
 * returns is the run's: a {@code String} is its output when nothing was logged, a {@link Response}
 * is the handler's answer (and fails the run at 400 or more), and {@code null} or any other value
 * is answered with the run as JSON. Anything it throws fails the run, which is answered 500.
 *
 * <pre>{@code
 * Handler h = nightly.handler((job, request) -> {
 *   reports.build(job);
 *   return null;
 * });
 * }</pre>
 */
@FunctionalInterface
public interface HandlerFunction {
  /**
   * Runs the job for one request.
   *
   * @throws Exception anything, which fails the run
   */
  @Nullable Object handle(JobContext job, Request request) throws Exception;
}
