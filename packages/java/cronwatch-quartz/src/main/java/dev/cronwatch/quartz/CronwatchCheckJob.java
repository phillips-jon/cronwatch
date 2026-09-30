package dev.cronwatch.quartz;

import org.quartz.DisallowConcurrentExecution;
import org.quartz.Job;
import org.quartz.JobExecutionContext;
import org.quartz.SchedulerException;

/**
 * CronWatch's check as a Quartz job, scheduled with {@link CronwatchQuartz#scheduleCheck}: a sync
 * (the scheduler's jobs declared again, the declarations written, and jobs gone from it declared
 * again without their schedule, within 30 seconds) and a check, once per firing across a cluster.
 * Its runs are never a job. On a node that does not watch the scheduler, it does nothing.
 */
@DisallowConcurrentExecution
public final class CronwatchCheckJob implements Job {
  /** Made by Quartz's job factory. */
  public CronwatchCheckJob() {}

  @Override
  public void execute(JobExecutionContext context) {
    Object found;
    try {
      found = context.getScheduler().getContext().get(CronwatchQuartz.CONTEXT_KEY);
    } catch (SchedulerException e) {
      return;
    }
    if (found instanceof CronwatchQuartz q) {
      q.checkNow();
    }
  }
}
