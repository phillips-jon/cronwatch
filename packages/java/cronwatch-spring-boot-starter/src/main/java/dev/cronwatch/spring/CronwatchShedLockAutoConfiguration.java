package dev.cronwatch.spring;

import net.javacrumbs.shedlock.core.LockProvider;
import org.springframework.beans.factory.ObjectProvider;
import org.springframework.boot.autoconfigure.AutoConfiguration;
import org.springframework.boot.autoconfigure.condition.ConditionalOnBean;
import org.springframework.boot.autoconfigure.condition.ConditionalOnClass;
import org.springframework.boot.autoconfigure.condition.ConditionalOnProperty;
import org.springframework.context.annotation.Bean;

/**
 * ShedLock, when the app has it: its {@code LockProvider} beans wrapped so a {@code @Scheduled} run
 * whose lock another instance held is given back, and the check run under a lock of its own name.
 * See {@link ShedLockSupport}.
 */
@AutoConfiguration(after = CronwatchAutoConfiguration.class)
@ConditionalOnClass(LockProvider.class)
@ConditionalOnProperty(prefix = "cronwatch", name = "enabled", matchIfMissing = true)
public class CronwatchShedLockAutoConfiguration {
  /** Made by Spring. */
  public CronwatchShedLockAutoConfiguration() {}

  /** Wraps the app's lock providers; static, as a post-processor must be. */
  @Bean
  static ShedLockSupport cronwatchShedLockSupport() {
    return new ShedLockSupport();
  }

  /** The check's lock, over the app's lock provider. */
  @Bean
  @ConditionalOnBean(LockProvider.class)
  CronwatchChecker.ClusterLock cronwatchClusterLock(
      ObjectProvider<LockProvider> providers, CronwatchProperties properties) {
    return work ->
        ShedLockSupport.underLock(
            providers.getObject(), CronwatchChecker.interval(properties.getCheckEvery()), work);
  }
}
