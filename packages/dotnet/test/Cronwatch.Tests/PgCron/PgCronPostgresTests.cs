using System;
using System.Globalization;
using System.Threading.Tasks;
using System.Transactions;
using Cronwatch.Internal;
using Cronwatch.PgCron;
using Npgsql;
using Xunit;
using static Cronwatch.Tests.Support;

namespace Cronwatch.Tests.PgCron;

/// <summary>
/// The pg_cron source's SQL against a real Postgres, over a fake <c>cron</c> schema made in a
/// database of the test's own (so it never meets a real pg_cron, nor another test), when
/// <c>CRONWATCH_TEST_PG</c> is set, as the Elixir and Java ports run it.
/// </summary>
public sealed class PgCronPostgresTests : IAsyncLifetime
{
    private string _url = "";
    private string _database = "";
    private NpgsqlDataSource? _source;

    private NpgsqlDataSource Source => _source ?? throw new InvalidOperationException("no database");

    public async ValueTask InitializeAsync()
    {
        _url = Databases.Require(Databases.PgVariable);
        _database = Databases.Prefix("pgcron") + "fake";
        await using (var admin = Databases.Postgres(_url))
        {
            await Databases.ExecAsync(admin, "CREATE DATABASE " + _database);
        }
        var b = new NpgsqlConnectionStringBuilder(Databases.PgConnectionString(_url)) { Database = _database };
        _source = NpgsqlDataSource.Create(b.ConnectionString);
        await Databases.ExecAsync(
            Source,
            "CREATE SCHEMA cron",
            "CREATE TABLE cron.job (jobid bigserial PRIMARY KEY, schedule text NOT NULL, command text NOT NULL DEFAULT 'SELECT 1', database text NOT NULL DEFAULT 'cw', username text NOT NULL DEFAULT 'postgres', active boolean NOT NULL DEFAULT true, jobname text)",
            "CREATE TABLE cron.job_run_details (jobid bigint, runid bigserial PRIMARY KEY, job_pid integer, database text, username text, command text, status text, return_message text, start_time timestamptz, end_time timestamptz)");
    }

    public async ValueTask DisposeAsync()
    {
        if (_source != null)
        {
            await _source.DisposeAsync();
        }
        if (_database.Length > 0)
        {
            await using var admin = Databases.Postgres(_url);
            await Databases.ExecAsync(admin, "DROP DATABASE IF EXISTS " + _database + " WITH (FORCE)");
        }
    }

    private static string At(long? ms) =>
        ms is { } m ? "to_timestamp(" + m.ToString(CultureInfo.InvariantCulture) + " / 1000.0)" : "NULL";

    /// <summary>Adds a row of run details, answering its runid.</summary>
    private async Task<long> Add(long jobId, string status, long? start, long? end, string? message)
    {
        await using var c = await Source.OpenConnectionAsync();
        await using var cmd = c.CreateCommand();
        cmd.CommandText = "INSERT INTO cron.job_run_details (jobid, status, return_message, start_time, end_time) VALUES ($1, $2, $3, "
            + At(start) + ", " + At(end) + ") RETURNING runid";
        cmd.Parameters.Add(new NpgsqlParameter { Value = jobId });
        cmd.Parameters.Add(new NpgsqlParameter { Value = status });
        cmd.Parameters.Add(new NpgsqlParameter { Value = (object?)message ?? DBNull.Value, NpgsqlDbType = NpgsqlTypes.NpgsqlDbType.Text });
        return (long)(await cmd.ExecuteScalarAsync())!;
    }

    [Fact]
    public async Task The_sources_sql_against_postgres_history_cursors_arrays_times_and_a_run_held()
    {
        await Databases.ExecAsync(
            Source,
            "INSERT INTO cron.job (jobname, schedule) VALUES ('nightly vacuum', '0 3 * * *')",
            "INSERT INTO cron.job (jobname, schedule) VALUES (NULL, '10 seconds')");
        long three = Js.DateUtc(2026, 0, 5, 3, 0, 0, 0);
        const long Day = 24 * Hour;
        for (int i = 24; i >= 1; i--)
        {
            await Add(1, "succeeded", three - (i * Day), three - (i * Day) + 5000, "VACUUM");
        }
        await Add(1, "failed", three + 123, three + 2123, "ERROR:  deadlock detected\n");

        var clock = Clock();
        await using var k = PgCronTests.Kit(new PgCronSource(Source), clock: clock);
        CheckResult first = await k.Cw.CheckAsync();
        Assert.Equal(["nightly-vacuum", "pg_cron:2"], PgCronTests.Names(first));
        Assert.Equal("0 3 * * *", first.Jobs[0].Definition.Schedule);
        Assert.Equal("UTC", first.Jobs[0].Definition.Timezone);

        var all = await k.Cw.RunsAsync("nightly-vacuum", 100);
        Assert.Equal(20, all.Count);
        Run newest = all[0];
        Assert.Equal("pgcron:25", newest.Id);
        Assert.Equal(three + 123, newest.StartedAt);
        Assert.Equal(2000, newest.DurationMs);
        Assert.Equal("ERROR:  deadlock detected", newest.Error);
        Assert.Equal(["failed"], k.Alerts.Types());

        // A run going, one queued, then more than a page of runs.
        long going = await Add(2, "running", T0 - 3000, null, null);
        long queued = await Add(2, "starting", null, null, null);
        await Databases.ExecAsync(
            Source,
            "INSERT INTO cron.job_run_details (jobid, status, return_message, start_time, end_time) SELECT 2, 'succeeded', '1 row', "
            + "to_timestamp((" + (T0 - 60_000).ToString(CultureInfo.InvariantCulture) + " + g) / 1000.0), "
            + "to_timestamp((" + (T0 - 60_000).ToString(CultureInfo.InvariantCulture) + " + g + 1) / 1000.0) FROM generate_series(1, 520) g");
        long last = going + 521;
        clock.Advance(1000);
        await k.Cw.CheckAsync();
        await k.Cw.CheckAsync();
        Assert.Equal(RunStatus.Running, (await PgCronTests.GetRun(k, "pgcron:" + going)).Status);
        Assert.Null(await k.Cw.GetRunAsync("pgcron:" + queued));
        // The job's newest runs are read, however many pages they take.
        Assert.Equal("1 row", (await PgCronTests.GetRun(k, "pgcron:" + last)).Output);

        await Databases.ExecAsync(
            Source,
            "UPDATE cron.job_run_details SET status = 'succeeded', end_time = " + At(T0 - 1000) + " WHERE runid = " + going.ToString(CultureInfo.InvariantCulture));
        await k.Cw.CheckAsync();
        Run done = await PgCronTests.GetRun(k, "pgcron:" + going);
        Assert.Equal(RunStatus.Ok, done.Status);
        Assert.Equal(2000, done.DurationMs);
        Assert.Empty(PgCronTests.Others(k));
    }

    /// <summary>
    /// A check made while the app holds a transaction open on the same database, both an ambient
    /// <see cref="TransactionScope"/> and one on a connection of its own: the source reads on
    /// connections of its own, and the app's transactions carry on.
    /// </summary>
    [Fact]
    public async Task The_source_never_reads_inside_the_apps_transaction()
    {
        await Databases.ExecAsync(Source, "INSERT INTO cron.job (jobname, schedule) VALUES ('nightly', '0 3 * * *')");
        await Add(1, "succeeded", T0 - 2000, T0 - 1000, "ok");
        await using var k = PgCronTests.Kit(new PgCronSource(Source));
        await using var app = await Source.OpenConnectionAsync();
        await using var tx = await app.BeginTransactionAsync();
        await using (var cmd = new NpgsqlCommand("UPDATE cron.job SET command = 'SELECT 2'", app, tx))
        {
            await cmd.ExecuteNonQueryAsync();
        }
        using (var scope = new TransactionScope(TransactionScopeAsyncFlowOption.Enabled))
        {
            await k.Cw.CheckAsync();
            // Left without Complete: the scope rolls back, and the source's reads were never in it.
        }
        await using (var cmd = new NpgsqlCommand("SELECT 1", app, tx))
        {
            // The transaction is still usable.
            Assert.Equal(1, (int)(await cmd.ExecuteScalarAsync())!);
        }
        await tx.RollbackAsync();
        Assert.Single(await k.Cw.RunsAsync("nightly", 20));
    }
}
