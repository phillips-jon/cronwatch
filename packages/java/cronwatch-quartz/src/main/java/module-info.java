/**
 * CronWatch for Quartz 2.5: {@link dev.cronwatch.quartz.CronwatchQuartz} watches a scheduler, and
 * {@link dev.cronwatch.quartz.CronwatchCheckJob} runs CronWatch's check once per cluster.
 */
@org.jspecify.annotations.NullMarked
module dev.cronwatch.quartz {
  requires transitive dev.cronwatch;
  requires transitive org.quartz;
  requires static org.jspecify;

  exports dev.cronwatch.quartz;
}
