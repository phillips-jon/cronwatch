package dev.cronwatch.spring;

import java.lang.annotation.Documented;
import java.lang.annotation.ElementType;
import java.lang.annotation.Retention;
import java.lang.annotation.RetentionPolicy;
import java.lang.annotation.Target;

/**
 * Names a {@code @Scheduled} method's job and gives its options, where it would otherwise be
 * watched as {@code SimpleClassName.method} with the client's defaults. Durations are the SDK's
 * text ({@code "15m"}); an attribute left empty is not set. {@code cronwatch.jobs[<name>].*}
 * properties are given after these.
 *
 * <pre>{@code
 * @Scheduled(cron = "0 0 2 * * *", zone = "UTC")
 * @CronwatchJob(name = "nightly-report", grace = "15m", expect = "Report written")
 * public void build() { ... }
 * }</pre>
 */
@Documented
@Retention(RetentionPolicy.RUNTIME)
@Target(ElementType.METHOD)
public @interface CronwatchJob {
  /** The job's name: 1 to 120 letters, digits, {@code .}, {@code _}, {@code :} or {@code -}. */
  String name() default "";

  /** Describes the job on the dashboard. */
  String description() default "";

  /** How late a run may start before it counts as missed. */
  String grace() default "";

  /** How long a run may go on before it is treated as stuck. */
  String timeout() default "";

  /** Alerts when a successful run takes longer. */
  String maxDuration() default "";

  /** Text a successful run's output must contain. */
  String expect() default "";

  /** Labels for the job, before the integration's own. */
  String[] tags() default {};

  /** Alerts on the nth consecutive failure rather than the first; 0 for the default. */
  int failuresBeforeAlert() default 0;
}
