/**
 * CronWatch for JobRunr 8: {@link dev.cronwatch.jobrunr.CronwatchJobRunr} is the server filter that
 * records every attempt, declares the recurring jobs, and runs the check as a recurring job.
 */
@org.jspecify.annotations.NullMarked
module dev.cronwatch.jobrunr {
  requires transitive dev.cronwatch;
  requires transitive org.jobrunr.core;
  requires static org.jspecify;

  exports dev.cronwatch.jobrunr;
}
