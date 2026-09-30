/**
 * CronWatch for Spring Boot 3.5 and 4: the client from {@code cronwatch.*} properties, every
 * {@code @Scheduled} method watched with no code changes, ShedLock's lock providers and Quartz's
 * schedulers handled, and the check run once per cluster when the app has either.
 */
@org.jspecify.annotations.NullMarked
module dev.cronwatch.spring {
  requires transitive dev.cronwatch;
  requires static dev.cronwatch.quartz;
  requires static org.quartz;
  requires static net.javacrumbs.shedlock.core;
  requires transitive spring.boot;
  requires transitive spring.boot.autoconfigure;
  requires transitive spring.context;
  requires spring.aop;
  requires spring.beans;
  requires spring.core;
  requires micrometer.observation;
  requires static org.jspecify;

  exports dev.cronwatch.spring;

  // Spring makes the auto-configurations and binds the properties by reflection.
  opens dev.cronwatch.spring to
      spring.core,
      spring.beans,
      spring.context,
      spring.boot;
}
