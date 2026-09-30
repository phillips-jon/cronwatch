package dev.cronwatch.spring;

import dev.cronwatch.Cronwatch;
import dev.cronwatch.bridge.Bridge;
import io.micrometer.observation.ObservationRegistry;
import org.springframework.beans.factory.ObjectProvider;
import org.springframework.boot.autoconfigure.AutoConfiguration;
import org.springframework.boot.autoconfigure.condition.ConditionalOnBean;
import org.springframework.boot.autoconfigure.condition.ConditionalOnProperty;
import org.springframework.context.annotation.Bean;
import org.springframework.core.env.Environment;
import org.springframework.scheduling.config.TaskManagementConfigUtils;
import org.springframework.util.ClassUtils;

/**
 * Every {@code @Scheduled} method watched with no code changes, when the app has scheduling on
 * ({@code @EnableScheduling}) and the client: see {@link CronwatchScheduling}. {@code
 * cronwatch.scheduled.enabled=false} turns it off.
 */
@AutoConfiguration(
    after = CronwatchAutoConfiguration.class,
    afterName = "org.springframework.boot.autoconfigure.task.TaskSchedulingAutoConfiguration")
@ConditionalOnBean(
    type = "dev.cronwatch.Cronwatch",
    name = TaskManagementConfigUtils.SCHEDULED_ANNOTATION_PROCESSOR_BEAN_NAME)
@ConditionalOnProperty(prefix = "cronwatch.scheduled", name = "enabled", matchIfMissing = true)
public class CronwatchSchedulingAutoConfiguration {
  /** Made by Spring. */
  public CronwatchSchedulingAutoConfiguration() {}

  /** Finds the scheduled methods; static, as a post-processor must be, and depends on nothing. */
  @Bean
  public static ScheduledMethods cronwatchScheduledMethods() {
    return new ScheduledMethods();
  }

  /** Declares the jobs and records their runs. */
  @Bean
  public CronwatchScheduling cronwatchScheduling(
      Cronwatch cw,
      ScheduledMethods methods,
      CronwatchProperties properties,
      Environment environment,
      ObjectProvider<ObservationRegistry> registries) {
    return new CronwatchScheduling(
        cw,
        methods,
        properties,
        appName(properties, environment),
        registries.getIfUnique(),
        ClassUtils.isPresent(
            "net.javacrumbs.shedlock.core.LockProvider",
            CronwatchSchedulingAutoConfiguration.class.getClassLoader()));
  }

  /**
   * The app's name for its tags and runs' ids: {@code cronwatch.app}, else {@code
   * $CRONWATCH_APP_ID}, else {@code spring.application.name}, else the main class.
   */
  static String appName(CronwatchProperties properties, Environment environment) {
    String app = properties.getApp();
    if (app != null && !app.isBlank()) {
      return app.trim();
    }
    return Bridge.appName(environment.getProperty("spring.application.name"));
  }
}
