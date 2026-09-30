package dev.cronwatch.internal.core;

import dev.cronwatch.JobContext;
import io.micrometer.context.ThreadLocalAccessor;
import org.jspecify.annotations.Nullable;

/**
 * The current run for Micrometer's context propagation, which every Spring Boot app with Reactor or
 * Micrometer has: registered through {@code META-INF/services}, it lets Spring's {@code
 * ContextPropagatingTaskDecorator}, Reactor's automatic context propagation and {@code
 * ContextSnapshot} carry the run to other threads with no code. Loaded only by that library, so the
 * core needs it only when the app has it.
 */
public final class RunAccessor implements ThreadLocalAccessor<JobContext> {
  /** The key the run is kept under in a context snapshot. */
  public static final String KEY = "dev.cronwatch.run";

  /** The accessor, as the service loader makes it. */
  public RunAccessor() {}

  @Override
  public Object key() {
    return KEY;
  }

  @Override
  public @Nullable JobContext getValue() {
    return CurrentRun.get();
  }

  @Override
  public void setValue(JobContext value) {
    CurrentRun.set(value);
  }

  @Override
  public void setValue() {
    CurrentRun.set(null);
  }

  @Override
  public void restore(JobContext previous) {
    CurrentRun.set(previous);
  }

  @Override
  public void restore() {
    CurrentRun.set(null);
  }
}
