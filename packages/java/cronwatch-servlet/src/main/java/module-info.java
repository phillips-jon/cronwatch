/**
 * The CronWatch dashboard and a job's handler for a Jakarta servlet container: {@link
 * dev.cronwatch.servlet.CronwatchFilter} and {@link dev.cronwatch.servlet.CronwatchServlet}, over
 * the core's framework-free {@code Routes} and {@code Handler}.
 */
@org.jspecify.annotations.NullMarked
module dev.cronwatch.servlet {
  requires transitive dev.cronwatch;
  requires transitive jakarta.servlet;
  requires static org.jspecify;

  exports dev.cronwatch.servlet;
}
