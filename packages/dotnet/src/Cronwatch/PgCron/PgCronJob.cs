namespace Cronwatch.PgCron;

/// <summary>
/// A row of <c>cron.job</c>, as <see cref="PgCronOptions.Pick"/>,
/// <see cref="PgCronOptions.JobName"/>, and <see cref="PgCronOptions.OptionsFor"/> are given it.
/// </summary>
/// <param name="JobId">The job's id.</param>
/// <param name="JobName">Its name, or null for a job scheduled without one.</param>
/// <param name="Schedule">Its schedule as pg_cron has it (<c>0 3 * * *</c>, <c>30 seconds</c>).</param>
/// <param name="Database">The database it runs in.</param>
/// <param name="Username">The role it runs as.</param>
/// <param name="Active">False for a job paused with <c>cron.alter_job(..., active := false)</c>.</param>
public sealed record PgCronJob(long JobId, string? JobName, string Schedule, string Database, string Username, bool Active);

/// <summary>A row of <c>cron.job_run_details</c>, as <see cref="PgCronSource.ToRun"/> reads it.</summary>
/// <param name="RunId">The run's id.</param>
/// <param name="JobId">Its job's id.</param>
/// <param name="Status">
/// pg_cron's status: <c>starting</c>, <c>running</c>, <c>sending</c>, <c>connecting</c>,
/// <c>succeeded</c>, or <c>failed</c>.
/// </param>
/// <param name="ReturnMessage">What the command answered, or its error.</param>
/// <param name="StartTime">
/// When it started, epoch milliseconds, or null for a run queued and not started (or one a server
/// restart cut off).
/// </param>
/// <param name="EndTime">When it ended, epoch milliseconds, or null.</param>
public sealed record PgCronRow(long RunId, long JobId, string? Status, string? ReturnMessage, long? StartTime, long? EndTime);
