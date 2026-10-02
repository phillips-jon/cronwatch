/**
 * CronWatch: monitoring for scheduled jobs. Missed, failed, stuck, slow, over-budget and
 * under-floor runs are alerted once and recovered once, from the job's own process, with no service
 * to run.
 *
 * <p>The API is {@link dev.cronwatch.Cronwatch}. Stores are in {@code dev.cronwatch.store} (the
 * interface, {@code MemoryStore}, and {@code SqlStore} over a {@code DataSource}; {@code
 * dev.cronwatch.jdbc} holds only {@code SqlStore}'s deprecated alias of before 1.0); {@code
 * dev.cronwatch.pgcron} watches pg_cron; {@code dev.cronwatch.storetest} is the store contract test
 * for a store of the app's own. The alert channels are in {@code dev.cronwatch.alerts} and Claude
 * triage in {@code dev.cronwatch.triage}. {@code dev.cronwatch.web} is the dashboard and a job's
 * handler, framework-free, with an adapter for the JDK's own HTTP server. {@code
 * dev.cronwatch.internal.*} is not exported and may change in any release.
 */
@org.jspecify.annotations.NullMarked
module dev.cronwatch {
  requires static transitive java.sql;
  requires static transitive org.jspecify;
  requires static org.slf4j;
  requires static context.propagation;
  requires java.net.http;
  requires static transitive jdk.httpserver;

  exports dev.cronwatch;
  exports dev.cronwatch.json;
  exports dev.cronwatch.store;
  exports dev.cronwatch.jdbc;
  exports dev.cronwatch.storetest;
  exports dev.cronwatch.bridge;
  exports dev.cronwatch.cli;
  exports dev.cronwatch.alerts;
  exports dev.cronwatch.triage;
  exports dev.cronwatch.pgcron;
  exports dev.cronwatch.web;

// Micrometer's context propagation finds the current run's accessor through
// META-INF/services on the class path. It is not provided here: a provides
// clause naming a type of a module required statically fails resolution
// when that module is absent (ModuleTest holds it).
}
