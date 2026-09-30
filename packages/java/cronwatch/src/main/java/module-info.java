/**
 * CronWatch: monitoring for scheduled jobs. Missed, failed, stuck, slow and over-budget runs are
 * alerted once and recovered once, from the job's own process, with no service to run.
 *
 * <p>The API is {@link dev.cronwatch.Cronwatch}. Stores are in {@code dev.cronwatch.store} (the
 * interface and {@code MemoryStore}) and {@code dev.cronwatch.jdbc} ({@code SqlStore} over a {@code
 * DataSource}); {@code dev.cronwatch.storetest} is the store contract test for a store of the app's
 * own. {@code dev.cronwatch.internal.*} is not exported and may change in any release.
 */
@org.jspecify.annotations.NullMarked
module dev.cronwatch {
  requires static java.sql;
  requires static transitive org.jspecify;
  requires static org.slf4j;
  requires static context.propagation;

  exports dev.cronwatch.json;
}
