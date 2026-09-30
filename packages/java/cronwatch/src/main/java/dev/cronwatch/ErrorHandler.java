package dev.cronwatch;

/**
 * Called with anything that goes wrong outside a job: the store failing, an alert channel failing,
 * a triage timeout (the SDK's {@code onError}). {@code where} says what was being done ({@code
 * recording nightly-report}, {@code alert channel slack}). The default logs it through {@link
 * System.Logger} named {@code dev.cronwatch} at {@code ERROR}, as {@code [cronwatch] <where>:
 * <error>}. A handler that throws is ignored.
 */
@FunctionalInterface
public interface ErrorHandler {
  /** Handles one error. */
  void handle(String where, Throwable error);
}
