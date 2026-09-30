package dev.cronwatch.spring;

import dev.cronwatch.Cronwatch;
import dev.cronwatch.quartz.CronwatchQuartz;
import org.quartz.Scheduler;
import org.springframework.beans.factory.ObjectProvider;
import org.springframework.boot.autoconfigure.AutoConfiguration;
import org.springframework.boot.autoconfigure.condition.ConditionalOnBean;
import org.springframework.boot.autoconfigure.condition.ConditionalOnClass;
import org.springframework.boot.autoconfigure.condition.ConditionalOnProperty;
import org.springframework.context.annotation.Bean;
import org.springframework.core.env.Environment;

/**
 * The app's Quartz schedulers watched, when Quartz and {@code cronwatch-quartz} are on the class
 * path: see {@link CronwatchQuartzRegistrar}. {@code cronwatch.quartz.enabled=false} turns it off.
 */
@AutoConfiguration(
    after = {CronwatchAutoConfiguration.class, CronwatchShedLockAutoConfiguration.class},
    afterName = {
      "org.springframework.boot.autoconfigure.quartz.QuartzAutoConfiguration",
      "org.springframework.boot.quartz.autoconfigure.QuartzAutoConfiguration"
    })
@ConditionalOnClass({Scheduler.class, CronwatchQuartz.class})
@ConditionalOnBean(Cronwatch.class)
@ConditionalOnProperty(prefix = "cronwatch.quartz", name = "enabled", matchIfMissing = true)
public class CronwatchQuartzAutoConfiguration {
  /** Made by Spring. */
  public CronwatchQuartzAutoConfiguration() {}

  /** Watches the app's schedulers. */
  @Bean
  CronwatchQuartzRegistrar cronwatchQuartzRegistrar(
      Cronwatch cw,
      CronwatchProperties properties,
      Environment environment,
      ObjectProvider<Scheduler> schedulers,
      ObjectProvider<CronwatchChecker.ClusterLock> clusterLock) {
    return new CronwatchQuartzRegistrar(
        cw,
        properties,
        CronwatchSchedulingAutoConfiguration.appName(properties, environment),
        schedulers,
        clusterLock);
  }
}
