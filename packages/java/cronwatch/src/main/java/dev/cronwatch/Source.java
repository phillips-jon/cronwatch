package dev.cronwatch;

import java.util.List;

/**
 * Where runs this process does not wrap come from, such as pg_cron's jobs (a later release). A
 * check syncs each one first, so what it records is evaluated in the same check; one that throws is
 * reported as {@code source <name>} and the check carries on.
 */
public interface Source {
  /** Names the source in errors. */
  String name();

  /**
   * Declares the jobs (with {@link Cronwatch#job}) and records their new runs (with {@link
   * Cronwatch#recordRun}), returning the alerts recording them sent.
   *
   * @throws Exception when the source could not be read
   */
  List<Alert> sync(Cronwatch cronwatch) throws Exception;
}
