package dev.cronwatch.spring;

import dev.cronwatch.Cronwatch;
import org.springframework.beans.factory.ObjectProvider;
import org.springframework.boot.autoconfigure.AutoConfiguration;
import org.springframework.boot.autoconfigure.condition.ConditionalOnBean;
import org.springframework.context.annotation.Bean;

/**
 * The check, on {@code cronwatch.check-every}, from when the context has started until it stops:
 * see {@link CronwatchChecker}. {@code cronwatch.check-mode=none} leaves checks to the app.
 */
@AutoConfiguration(
    after = {
      CronwatchAutoConfiguration.class,
      CronwatchSchedulingAutoConfiguration.class,
      CronwatchShedLockAutoConfiguration.class,
      CronwatchQuartzAutoConfiguration.class
    })
@ConditionalOnBean(Cronwatch.class)
public class CronwatchCheckAutoConfiguration {
  /** Made by Spring. */
  public CronwatchCheckAutoConfiguration() {}

  /** Runs the syncs and the check. */
  @Bean
  CronwatchChecker cronwatchChecker(
      Cronwatch cw,
      CronwatchProperties properties,
      ObjectProvider<CronwatchScheduling> scheduling,
      ObjectProvider<CronwatchChecker.ClusterLock> clusterLock,
      ObjectProvider<CronwatchChecker.QuartzChecks> quartz) {
    return new CronwatchChecker(
        cw, properties, scheduling.getIfUnique(), clusterLock.getIfUnique(), quartz.getIfUnique());
  }
}
