package dev.cronwatch.pgcron;

import org.jspecify.annotations.Nullable;

/**
 * A row of {@code cron.job_run_details}, as {@link PgCron#run} reads it.
 *
 * @param runId the run's id
 * @param jobId its job's id
 * @param status pg_cron's status: {@code starting}, {@code running}, {@code sending}, {@code
 *     connecting}, {@code succeeded} or {@code failed}
 * @param returnMessage what the command answered, or its error
 * @param startTime when it started, epoch milliseconds, or null for a run queued and not started
 *     (or one a server restart cut off)
 * @param endTime when it ended, epoch milliseconds, or null
 */
record PgCronRow(
    long runId,
    long jobId,
    @Nullable String status,
    @Nullable String returnMessage,
    @Nullable Long startTime,
    @Nullable Long endTime) {}
