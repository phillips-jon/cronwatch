package dev.cronwatch.pgcron;

import java.util.Objects;
import org.jspecify.annotations.Nullable;

/**
 * A row of {@code cron.job}, as {@link PgCronOptions.Builder#pick}, {@link
 * PgCronOptions.Builder#jobName}, and {@link
 * PgCronOptions.Builder#options(java.util.function.Function)} are given it.
 *
 * @param jobId the job's id
 * @param jobName its name, or null for a job scheduled without one
 * @param schedule its schedule as pg_cron has it ({@code 0 3 * * *}, {@code 30 seconds})
 * @param database the database it runs in
 * @param username the role it runs as
 * @param active false for a job paused with {@code cron.alter_job(..., active := false)}
 */
public record PgCronJob(
    long jobId,
    @Nullable String jobName,
    String schedule,
    String database,
    String username,
    boolean active) {
  /** Checks that the required components are there. */
  public PgCronJob {
    Objects.requireNonNull(schedule, "schedule");
    Objects.requireNonNull(database, "database");
    Objects.requireNonNull(username, "username");
  }
}
