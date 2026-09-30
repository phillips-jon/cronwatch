using System;
using System.Collections.Generic;
using System.Globalization;
using System.Linq;
using System.Security.Cryptography;
using System.Threading;
using System.Threading.Tasks;
using Cronwatch.PgCron;
using Npgsql;
using Xunit;

namespace Cronwatch.Tests.PgCron;

/// <summary>
/// The pg_cron source against a real pg_cron, as the SDK's <c>pgcron.test.ts</c> and the other
/// ports run it, when <c>CRONWATCH_TEST_PGCRON</c> is the URL of a Postgres with pg_cron preloaded
/// (<c>cron.database_name</c> naming that database). pg_cron runs on the wall clock, so these do
/// too, and every wait is a poll for an outcome, held to thirty seconds.
/// </summary>
public sealed class PgCronRealTests : IAsyncLifetime
{
    private string _url = "";
    private NpgsqlDataSource? _admin;

    /// <summary>The server as its URL's own role, which may do anything.</summary>
    private NpgsqlDataSource Admin => _admin ?? throw new InvalidOperationException("no database");

    public async ValueTask InitializeAsync()
    {
        _url = Databases.Require(Databases.PgCronVariable);
        _admin = Databases.Postgres(_url);
        // The tests may start at once, and two CREATE EXTENSIONs race.
        await using var c = await Admin.OpenConnectionAsync();
        await using var tx = await c.BeginTransactionAsync();
        await using (var cmd = new NpgsqlCommand("SELECT pg_advisory_xact_lock(7307)", c, tx))
        {
            await cmd.ExecuteNonQueryAsync();
        }
        await using (var cmd = new NpgsqlCommand("CREATE EXTENSION IF NOT EXISTS pg_cron", c, tx))
        {
            await cmd.ExecuteNonQueryAsync();
        }
        await tx.CommitAsync();
    }

    public async ValueTask DisposeAsync()
    {
        if (_admin != null)
        {
            await _admin.DisposeAsync();
        }
    }

    /// <summary>The wall clock moved on by an offset the test sets, in UTC.</summary>
    private sealed class WallClock : TimeProvider
    {
        private long _offset;

        public long Offset
        {
            get => Interlocked.Read(ref _offset);
            set => Interlocked.Exchange(ref _offset, value);
        }

        public override DateTimeOffset GetUtcNow() => base.GetUtcNow().AddMilliseconds(Offset);

        public override TimeZoneInfo LocalTimeZone => TimeZoneInfo.Utc;
    }

    /// <summary>A client with the source on the wall clock, keeping what it sent and reported.</summary>
    private sealed class Kit : IAsyncDisposable
    {
        public Kit(IStore store, TimeProvider clock, ISource source)
        {
            Cw = new CronwatchClient(new CronwatchOptions
            {
                Store = store,
                Clock = clock,
                Alerts = [Alerts],
                CronSecret = CronSecret.None,
                OnError = Errors.Handle,
                OnWarning = _ => { },
                ProcessExitHook = false,
                Sources = [source],
            });
        }

        public CronwatchClient Cw { get; }

        public Support.Capture Alerts { get; } = new();

        public Support.Errors Errors { get; } = new();

        public List<string> Others() =>
            Errors.Messages().Where(e => !e.Contains("cron.", StringComparison.Ordinal) && !e.Contains("row level", StringComparison.Ordinal)).ToList();

        public ValueTask DisposeAsync() => Cw.DisposeAsync();
    }

    private static string Tag(string label) =>
        "cwdotnet" + label + RandomNumberGenerator.GetInt32(1 << 24).ToString("x", CultureInfo.InvariantCulture);

    private static NpgsqlCommand Command(NpgsqlConnection c, string text, object[] parameters)
    {
        var cmd = new NpgsqlCommand(text, c);
        foreach (object p in parameters)
        {
            cmd.Parameters.Add(new NpgsqlParameter { Value = p });
        }
        return cmd;
    }

    private static async Task Sql(NpgsqlDataSource source, string text, params object[] parameters)
    {
        await using var c = await source.OpenConnectionAsync();
        await using var cmd = Command(c, text, parameters);
        await cmd.ExecuteNonQueryAsync();
    }

    private static async Task<List<long>> Longs(NpgsqlDataSource source, string text, params object[] parameters)
    {
        await using var c = await source.OpenConnectionAsync();
        await using var cmd = Command(c, text, parameters);
        await using var reader = await cmd.ExecuteReaderAsync();
        var output = new List<long>();
        while (await reader.ReadAsync())
        {
            output.Add(Convert.ToInt64(reader.GetValue(0), CultureInfo.InvariantCulture));
        }
        return output;
    }

    private Task Sql(string text, params object[] parameters) => Sql(Admin, text, parameters);

    private Task<List<long>> Longs(string text, params object[] parameters) => Longs(Admin, text, parameters);

    private async Task<long> DetailCount(string name) =>
        (await Longs("SELECT count(*) FROM cron.job_run_details d JOIN cron.job j USING (jobid) WHERE j.jobname = $1 AND d.start_time IS NOT NULL", name))[0];

    private async Task<long> StatusCount(string name, string status) =>
        (await Longs("SELECT count(*) FROM cron.job_run_details d JOIN cron.job j USING (jobid) WHERE j.jobname = $1 AND d.status = $2", name, status))[0];

    private PgCronSource Tagged(string tag, JobOptions? options = null, string? timezone = null) =>
        new(Admin, new PgCronOptions { Pick = j => j.JobName != null && j.JobName.StartsWith(tag, StringComparison.Ordinal), Options = options, Timezone = timezone });

    [Fact]
    public async Task The_source_against_a_real_pg_cron()
    {
        string tag = Tag("real");
        string ok = tag + "-ok";
        string fail = tag + "-fail";
        string sleep = tag + "-sleep";
        var clock = new WallClock();
        var store = new MemoryStore();
        try
        {
            await Sql("SELECT cron.schedule($1, '1 seconds', 'SELECT 1')", ok);
            await Sql("SELECT cron.schedule($1, '1 seconds', 'SELECT 1/0')", fail);
            await Sql("SELECT cron.schedule($1, '1 seconds', 'SELECT pg_sleep(3)')", sleep);
            await Support.Eventually("runs of each job", async () => await StatusCount(ok, "succeeded") >= 2 && await StatusCount(fail, "failed") >= 1);

            var k = new Kit(store, clock, Tagged(tag, new JobOptions { Grace = "30s" }));
            CheckResult first = await k.Cw.CheckAsync();
            Assert.Equal("every 1s", PgCronTests.Find(first.Jobs, ok).Definition.Schedule);
            Assert.Equal("UTC", PgCronTests.Find(first.Jobs, ok).Definition.Timezone);
            var okRuns = await k.Cw.RunsAsync(ok, 20);
            Assert.True(okRuns.Count >= 2, "ok runs imported (" + okRuns.Count + ")");
            Assert.All(okRuns, r => Assert.True(r.Id.StartsWith("pgcron:", StringComparison.Ordinal) && r.Trigger == "pg_cron", r.Id));
            Assert.Contains(okRuns, r => r.Status == RunStatus.Ok && r.Output == "1 row");
            // A failure and its message are imported.
            Assert.Contains(await k.Cw.RunsAsync(fail, 20), r => r.Status == RunStatus.Failed && (r.Error ?? "").Contains("division by zero", StringComparison.Ordinal));
            Assert.Equal(["failed " + fail], first.Alerts.Select(a => a.Type.Value + " " + a.Job));
            Assert.Equal(JobHealth.Healthy, PgCronTests.Find(first.Jobs, ok).Health);

            // A run imported while it was going is updated when it finishes.
            long running = 0;
            await Support.Eventually("the sleeping job running", async () =>
            {
                var ids = await Longs("SELECT d.runid FROM cron.job_run_details d JOIN cron.job j USING (jobid) WHERE j.jobname = $1 AND d.status = 'running' AND d.start_time IS NOT NULL", sleep);
                running = ids.Count == 0 ? 0 : ids[0];
                return ids.Count > 0;
            });
            await k.Cw.CheckAsync();
            // Copied running, unless it finished between the read above and the check.
            Run imported = await k.Cw.GetRunAsync("pgcron:" + running) ?? throw new Xunit.Sdk.XunitException("not imported");
            Assert.True(imported.Status == RunStatus.Running || imported.Status == RunStatus.Ok, imported.Status.Value);
            await Support.Eventually("the sleeping run finished", async () =>
            {
                await k.Cw.CheckAsync();
                Run? r = await k.Cw.GetRunAsync("pgcron:" + running);
                return r != null && r.Status == RunStatus.Ok;
            });
            Run slept = (await k.Cw.GetRunAsync("pgcron:" + running))!;
            Assert.True(slept.DurationMs >= 2900, "duration " + slept.DurationMs);

            // New runs keep arriving; nothing is copied twice, even by a fresh client after a
            // restart.
            int before = (await k.Cw.RunsAsync(ok, 500)).Count;
            await Support.Eventually("later runs imported", async () =>
            {
                await k.Cw.CheckAsync();
                return (await k.Cw.RunsAsync(ok, 500)).Count > before;
            });
            var ids = (await k.Cw.RunsAsync(ok, 500)).Select(r => r.Id).ToList();
            Assert.Equal(ids.Count, ids.Distinct(StringComparer.Ordinal).Count());

            // The ok job is unscheduled, and the fail job paused: neither is missed.
            await Sql("SELECT cron.unschedule($1::text)", ok);
            await Sql("SELECT cron.alter_job(jobid, active := false) FROM cron.job WHERE jobname = $1", fail);
            await Support.Eventually("the paused job's runs ended", async () =>
                await StatusCount(fail, "running") == 0 && await StatusCount(fail, "starting") == 0
                && await StatusCount(fail, "sending") == 0 && await StatusCount(fail, "connecting") == 0);
            await k.DisposeAsync();
            k = new Kit(store, clock, Tagged(tag, new JobOptions { Grace = "30s" }));
            await k.Cw.CheckAsync();
            int settled = (await k.Cw.RunsAsync(fail, 500)).Count;
            await k.Cw.CheckAsync();
            // A re-import adds nothing.
            Assert.Equal(settled, (await k.Cw.RunsAsync(fail, 500)).Count);
            Assert.Equal(Math.Min(await DetailCount(fail), settled), (await k.Cw.RunsAsync(fail, 500)).Count);
            clock.Offset = 2 * Support.Min;
            CheckResult late = await k.Cw.CheckAsync();
            // The unscheduled job is gone, not late, and the paused one is not expected.
            Assert.DoesNotContain(late.Alerts, a => a.Type.Value == "missed" && (a.Job == ok || a.Job == fail));
            JobSummary okJob = PgCronTests.Find(late.Jobs, ok);
            Assert.Null(okJob.Definition.Schedule);
            Assert.Contains("no longer in cron.job", okJob.Definition.Description, StringComparison.Ordinal);
            await k.DisposeAsync();
        }
        finally
        {
            await Sql("SELECT cron.unschedule(jobid) FROM cron.job WHERE jobname LIKE $1", tag + "%");
        }
    }

    private async Task<long> Insert(long jobId, string status, string times, string message) =>
        (await Longs(
            "INSERT INTO cron.job_run_details (jobid, runid, database, username, command, status, return_message, start_time, end_time) "
            + "SELECT $1, nextval('cron.runid_seq'), 'postgres', 'postgres', 'select 1', $2, $3, " + times + " RETURNING runid",
            jobId,
            status,
            message))[0];

    /// <summary>Schedules a job and pauses it, so pg_cron itself adds no rows while the test writes its own.</summary>
    private async Task<long> SchedulePaused(string name)
    {
        long id = (await Longs("SELECT cron.schedule($1, '0 3 * * *', 'SELECT 1')", name))[0];
        await Sql("SELECT cron.alter_job($1, active := false)", id);
        return id;
    }

    [Fact]
    public async Task Restart_rows_a_crowded_job_first_sight_and_a_rename()
    {
        string tag = Tag("row");
        string busy = tag + "-busy";
        string quiet = tag + "-quiet";
        string hist = tag + "-hist";
        try
        {
            long busyId = await SchedulePaused(busy);
            long quietId = await SchedulePaused(quiet);
            long histId = await SchedulePaused(hist);
            // First sight of a job whose newest rows include a run cut off by a restart, and older
            // failures.
            await Sql(
                "INSERT INTO cron.job_run_details (jobid, runid, database, username, command, status, return_message, start_time, end_time) "
                + "SELECT $1, nextval('cron.runid_seq'), 'postgres', 'postgres', 'select 1', 'failed', 'ERROR: old', now() - interval '3 days', now() - interval '3 days' FROM generate_series(1, 5)",
                histId);
            await Insert(histId, "failed", "NULL, NULL", "server restarted");
            await Sql(
                "INSERT INTO cron.job_run_details (jobid, runid, database, username, command, status, return_message, start_time, end_time) "
                + "SELECT $1, nextval('cron.runid_seq'), 'postgres', 'postgres', 'select 1', 'succeeded', '1 row', now() - make_interval(mins => 30 - g), now() - make_interval(mins => 30 - g) FROM generate_series(1, 19) g",
                histId);

            await using var k = new Kit(new MemoryStore(), TimeProvider.System, Tagged(tag, timezone: "UTC"));
            await k.Cw.CheckAsync();
            // The twenty newest copied, history never judged, and never read again.
            Assert.Equal(20, (await k.Cw.RunsAsync(hist, 500)).Count);
            Assert.Empty(k.Alerts.Types());
            await k.Cw.CheckAsync();
            Assert.Equal(20, (await k.Cw.RunsAsync(hist, 500)).Count);

            // A restart cuts off a busy job's queued run; the busy job then runs past a page; then
            // the quiet job fails.
            long cut = await Insert(busyId, "failed", "NULL, NULL", "server restarted");
            await Sql(
                "INSERT INTO cron.job_run_details (jobid, runid, database, username, command, status, return_message, start_time, end_time) "
                + "SELECT $1, nextval('cron.runid_seq'), 'postgres', 'postgres', 'select 1', 'succeeded', '1 row', now() - make_interval(secs => 600 - g), now() - make_interval(secs => 600 - g) FROM generate_series(1, 520) g",
                busyId);
            long disk = await Insert(quietId, "failed", "now(), now()", "ERROR: disk full");
            for (int i = 0; i < 3; i++)
            {
                await k.Cw.CheckAsync();
            }
            Run cutRun = await k.Cw.GetRunAsync("pgcron:" + cut) ?? throw new Xunit.Sdk.XunitException("the cut run was not copied");
            Assert.Equal("server restarted", cutRun.Error);
            Run diskRun = await k.Cw.GetRunAsync("pgcron:" + disk) ?? throw new Xunit.Sdk.XunitException("the quiet job's failure was not copied");
            Assert.Equal(RunStatus.Failed, diskRun.Status);
            Assert.Contains(k.Alerts.List(), a => a.Type.Value == "failed" && a.Job == quiet);

            // Renamed in pg_cron: the old name keeps its runs and loses its schedule.
            await Sql("UPDATE cron.job SET jobname = $1 WHERE jobid = $2", quiet + "-v2", quietId);
            await Sql("SELECT cron.alter_job($1, active := true)", quietId);
            await k.Cw.CheckAsync();
            var jobs = await k.Cw.JobsAsync();
            JobSummary old = PgCronTests.Find(jobs, quiet);
            Assert.Null(old.Definition.Schedule);
            Assert.Contains("renamed to", old.Definition.Description, StringComparison.Ordinal);
            Assert.Equal("0 3 * * *", PgCronTests.Find(jobs, quiet + "-v2").Definition.Schedule);
            Assert.Empty(k.Others());
        }
        finally
        {
            await Sql("SELECT cron.unschedule(jobid) FROM cron.job WHERE jobname LIKE $1", tag + "%");
        }
    }

    /// <summary>
    /// A role that may read cron's tables but not its settings: the zone is assumed and reported,
    /// <c>cron.log_run</c> unreadable is taken as on, and a transaction the role has open on
    /// another connection is never touched.
    /// </summary>
    [Fact]
    public async Task A_role_that_may_not_read_cron_settings_is_given_utc_told_once_and_its_transaction_untouched()
    {
        string role = Tag("role");
        var b = new NpgsqlConnectionStringBuilder(Databases.PgConnectionString(_url)) { Username = role, Password = "pw" };
        await using var asRole = NpgsqlDataSource.Create(b.ConnectionString);
        try
        {
            await Sql("CREATE ROLE " + role + " LOGIN PASSWORD 'pw'");
            await Sql("GRANT USAGE ON SCHEMA cron TO " + role);
            await Sql("GRANT SELECT ON cron.job, cron.job_run_details TO " + role);
            await Sql(asRole, "SELECT cron.schedule($1, '0 3 * * *', 'SELECT 1')", role + "-job");
            await using var k = new Kit(new MemoryStore(), TimeProvider.System, new PgCronSource(asRole));
            await using var app = await asRole.OpenConnectionAsync();
            await using var tx = await app.BeginTransactionAsync();
            await using (var cmd = new NpgsqlCommand("SELECT 1", app, tx))
            {
                await cmd.ExecuteScalarAsync();
            }
            CheckResult result = await k.Cw.CheckAsync();
            await using (var cmd = new NpgsqlCommand("SELECT 1", app, tx))
            {
                // The transaction is still usable.
                Assert.Equal(1, (int)(await cmd.ExecuteScalarAsync())!);
            }
            await tx.RollbackAsync();
            JobSummary job = PgCronTests.Find(result.Jobs, role + "-job");
            Assert.Equal("UTC", job.Definition.Timezone);
            // cron.log_run unreadable is taken as on.
            Assert.Equal("0 3 * * *", job.Definition.Schedule);
            Assert.Contains(k.Errors.Messages(), e => e.Contains("could not read cron.timezone", StringComparison.Ordinal));
        }
        finally
        {
            // Every job of the role goes before the role: pg_cron's scheduler stops on a job whose
            // role is gone.
            await Quietly(() => Sql("SELECT cron.unschedule(jobid) FROM cron.job WHERE username = $1", role));
            await Quietly(() => Sql("DROP OWNED BY " + role));
            await Quietly(() => Sql("DROP ROLE IF EXISTS " + role));
        }
    }

    private static async Task Quietly(Func<Task> step)
    {
        try
        {
            await step();
        }
        catch (PostgresException)
        {
            // Cleaning up after a failure: the failure is what the test reports.
        }
    }
}
