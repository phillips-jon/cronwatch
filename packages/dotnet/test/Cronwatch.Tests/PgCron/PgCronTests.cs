using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.Linq;
using System.Threading.Tasks;
using Cronwatch.Internal;
using Cronwatch.PgCron;
using Microsoft.Extensions.Time.Testing;
using Xunit;
using static Cronwatch.Tests.Support;

namespace Cronwatch.Tests.PgCron;

/// <summary>
/// The SDK's <c>pgcron.test.ts</c>, ported over an in-memory <c>cron</c> schema
/// (<see cref="FakeCron"/>), with the other ports' own: the source's queries and the options'
/// refusals.
/// </summary>
public class PgCronTests
{
    private const long Day = 24 * Hour;

    /// <summary>A client with the source, on the clock, reporting to its capture and errors.</summary>
    internal static Made Kit(PgCronSource source, IStore? store = null, FakeTimeProvider? clock = null) =>
        Make(store: store ?? new MemoryStore(), clock: clock, sources: [source]);

    /// <summary>The errors reported, but for the settings and row level security notes.</summary>
    internal static List<string> Others(Made k) =>
        k.Errors.Messages().Where(e => !e.Contains("cron.", StringComparison.Ordinal) && !e.Contains("row level", StringComparison.Ordinal)).ToList();

    internal static List<string> Names(CheckResult r) => r.Jobs.Select(j => j.Name).ToList();

    internal static JobSummary Find(IEnumerable<JobSummary> jobs, string name) => jobs.First(j => j.Name == name);

    internal static List<string> TypeAndJob(IEnumerable<Alert> alerts) =>
        alerts.Select(a => a.Type.Value + " " + a.Job).Order(StringComparer.Ordinal).ToList();

    internal static async Task<Run> GetRun(Made k, string id) => await k.Cw.GetRunAsync(id) ?? throw new Xunit.Sdk.XunitException("no run " + id);

    private static async Task<List<string>> StoredNames(IStore store) => (await store.ListJobsAsync()).Select(j => j.Name).ToList();

    [Fact]
    public void Pg_cron_schedules_become_cronwatch_schedules()
    {
        Assert.Equal("every 30s", PgCronSource.ToSchedule("30 seconds"));
        Assert.Equal("every 1s", PgCronSource.ToSchedule("1 second"));
        Assert.Equal("0 0 L * *", PgCronSource.ToSchedule("0 0 $ * *"));
        Assert.Equal("*/5 * * * *", PgCronSource.ToSchedule(" */5  * * * * "));
        Assert.Null(PgCronSource.ToSchedule("@reboot"));
        Assert.Equal("nightly-vacuum", PgCronSource.DefaultJobName(new PgCronJob(7, "nightly vacuum", "", "", "", true)));
        Assert.Equal("pg_cron:7", PgCronSource.DefaultJobName(new PgCronJob(7, null, "", "", "", true)));
        Assert.Equal("pg_cron:7", PgCronSource.DefaultJobName(new PgCronJob(7, "  ", "", "", "", true)));
    }

    [Fact]
    public void Pg_cron_ignores_fields_past_the_fifth_and_so_does_the_reader()
    {
        Assert.Equal("0 5 * * *", PgCronSource.ToSchedule("0 5 * * * *"));
        Assert.Equal("* * * * *", PgCronSource.ToSchedule("* * * * * *"));
        Assert.Equal("0 0 L * *", PgCronSource.ToSchedule("0 0 $ * * extra"));
        Assert.Equal("@hourly", PgCronSource.ToSchedule("@hourly"));
    }

    [Fact]
    public async Task Jobs_are_declared_history_is_copied_quietly_and_imports_are_idempotent()
    {
        var clock = Clock();
        var cron = new FakeCron();
        cron.AddJob(1, "nightly vacuum", "0 3 * * *");
        cron.AddJob(2, null, "10 seconds");
        cron.AddJob(3, "paused", "0 * * * *", active: false);
        cron.AddJob(4, "other", "0 * * * *");
        long three = Js.DateUtc(2026, 0, 5, 3, 0, 0, 0);
        for (int i = 24; i >= 1; i--)
        {
            cron.Add(1, "succeeded", three - (i * Day), three - (i * Day) + 5000, "VACUUM");
        }
        cron.Add(1, "failed", three, three + 2000, "ERROR:  deadlock detected\n");
        var store = new MemoryStore();
        PgCronSource Source() => cron.Source(new PgCronOptions { Pick = j => j.JobId != 4, Prefix = "db:" });
        var k = Kit(Source(), store, clock);

        CheckResult first = await k.Cw.CheckAsync();
        Assert.Equal(["db:nightly-vacuum", "db:paused", "db:pg_cron:2"], Names(first));
        JobSummary vacuum = Find(first.Jobs, "db:nightly-vacuum");
        Assert.Equal("0 3 * * *", vacuum.Definition.Schedule);
        Assert.Equal("UTC", vacuum.Definition.Timezone);
        Assert.Equal(["pg_cron"], vacuum.Definition.Tags);
        Assert.Equal("every 10s", Find(first.Jobs, "db:pg_cron:2").Definition.Schedule);
        Assert.Null(Find(first.Jobs, "db:paused").Definition.Schedule);
        var runs = await k.Cw.RunsAsync("db:nightly-vacuum", 100);
        Assert.Equal(20, runs.Count);
        Assert.Equal("pgcron:db:25", runs[0].Id);
        Assert.Equal(RunStatus.Failed, runs[0].Status);
        Assert.Equal("ERROR:  deadlock detected", runs[0].Error);
        Assert.Equal(2000, runs[0].DurationMs);
        Assert.Equal("pg_cron", runs[0].Trigger);
        Assert.Equal("VACUUM", runs[1].Output);
        // Only the newest finished run is judged; history does not alert.
        Assert.Equal(["failed"], k.Alerts.Types());

        await k.Cw.CheckAsync();
        await k.DisposeAsync();
        var alerts = k.Alerts;
        k = Kit(Source(), store, clock);
        await k.Cw.CheckAsync();
        // A re-import, even after a restart, adds nothing.
        Assert.Equal(20, (await k.Cw.RunsAsync("db:nightly-vacuum", 100)).Count);
        Assert.Empty(k.Alerts.Types());

        // A run not yet started holds the cursor; the run after it is copied now and it is copied
        // once it starts.
        FakeCron.Detail starting = cron.Add(2, "starting", null, null);
        cron.Add(2, "succeeded", T0 - 5000, T0 - 4000, "1 row");
        clock.Advance(1000);
        await k.Cw.CheckAsync();
        Assert.Equal(["pgcron:db:27"], (await k.Cw.RunsAsync("db:pg_cron:2", 20)).Select(r => r.Id));
        starting.Status = "running";
        starting.Start = T0 - 3000;
        await k.Cw.CheckAsync();
        Assert.Equal(RunStatus.Running, (await GetRun(k, "pgcron:db:26")).Status);
        starting.Status = "failed";
        starting.End = T0 - 1000;
        starting.Message = "ERROR:  boom";
        clock.Advance(1000);
        await k.Cw.CheckAsync();
        Run finished = await GetRun(k, "pgcron:db:26");
        Assert.Equal(RunStatus.Failed, finished.Status);
        Assert.Equal(2000, finished.DurationMs);
        // A run that was running and then failed is judged when it finishes.
        Assert.Equal(["failed"], k.Alerts.Types());
        Assert.Equal(["failed"], alerts.Types());

        // The nightly job stops running: missed, from its schedule, with no run details at all.
        clock.Set(Js.DateUtc(2026, 0, 6, 3, 11, 0, 0));
        cron.Add(2, "succeeded", clock.Ms() - 2000, clock.Ms() - 1000, "1 row");
        CheckResult later = await k.Cw.CheckAsync();
        Assert.Equal(["missed db:nightly-vacuum", "recovered db:pg_cron:2"], TypeAndJob(later.Alerts));
        Assert.Empty((await k.Cw.CheckAsync()).Alerts);

        // Unscheduled: its name keeps its history but loses its schedule, so it is never missed
        // again, and the missed alert it had open closes with a recovery that says so.
        lock (cron.Jobs)
        {
            cron.Jobs.RemoveAt(0);
        }
        clock.Set(Js.DateUtc(2026, 0, 8, 3, 11, 0, 0));
        CheckResult gone = await k.Cw.CheckAsync();
        JobSummary vacuumNow = Find(gone.Jobs, "db:nightly-vacuum");
        Assert.Null(vacuumNow.Definition.Schedule);
        Assert.Contains("no longer watched", vacuumNow.Definition.Description, StringComparison.Ordinal);
        // Its failure stays open until a successful run.
        Assert.Equal([Condition.Failed], vacuumNow.Open);
        var closed = gone.Alerts.Where(a => a.Job == "db:nightly-vacuum").ToList();
        Assert.Single(closed);
        Assert.Equal("recovered", closed[0].Type.Value);
        Assert.Equal("db:nightly-vacuum is no longer scheduled", closed[0].Title);
        Assert.Equal(
            "{\"after\":[\"missed\"],\"reason\":\"unscheduled\",\"since\":" + Js.FormatLong(Js.DateUtc(2026, 0, 6, 3, 11, 0, 0)) + "}",
            closed[0].Details.ToValue().ToJson());
        Assert.DoesNotContain((await k.Cw.CheckAsync()).Alerts, a => a.Job == "db:nightly-vacuum");
        Assert.Equal(20, (await k.Cw.RunsAsync("db:nightly-vacuum", 100)).Count);
        await k.DisposeAsync();
    }

    // The review: the source declared a job again only when its settings changed, so after the
    // dashboard's forget every later run was refused as not declared until the process restarted.
    [Fact]
    public async Task A_job_forgotten_from_the_dashboard_is_declared_again_and_its_later_runs_recorded()
    {
        var clock = Clock();
        var cron = new FakeCron();
        cron.AddJob(1, "vacuum", "0 3 * * *");
        cron.Add(1, "succeeded", T0 - 5000, T0 - 4000, "VACUUM");
        var k = Kit(cron.Source(), clock: clock);
        await k.Cw.CheckAsync();
        await k.Cw.ForgetAsync("vacuum");
        cron.Add(1, "succeeded", T0 - 3000, T0 - 2000, "VACUUM");
        cron.Add(1, "failed", T0 - 1000, T0, "ERROR:  boom");
        clock.Advance(1000);
        CheckResult result = await k.Cw.CheckAsync();
        Assert.Empty(Others(k));
        Assert.Equal(["vacuum"], Names(result));
        Assert.Equal("0 3 * * *", result.Jobs[0].Definition.Schedule);
        Assert.Equal(["pgcron:3", "pgcron:2"], (await k.Cw.RunsAsync("vacuum", 50)).Select(r => r.Id));
        Assert.Equal(["vacuum"], k.Cw.DefinedJobs.Select(d => d.Name));
        await k.DisposeAsync();
    }

    [Fact]
    public async Task A_pick_job_name_or_options_function_that_fails_fails_only_its_job_reported_once()
    {
        var cron = new FakeCron();
        cron.AddJob(1, "one", "0 * * * *");
        cron.AddJob(2, "two", "0 * * * *");
        cron.AddJob(3, "three", "0 * * * *");
        cron.AddJob(4, "four", "0 * * * *");
        var broken = new ConcurrentDictionary<string, bool>(StringComparer.Ordinal);
        var store = new MemoryStore();
        var options = new PgCronOptions
        {
            Pick = j => broken.ContainsKey("pick:" + j.JobId) ? throw new InvalidOperationException("pick broke") : true,
            JobName = j =>
                broken.ContainsKey("throw:" + j.JobId) ? throw new InvalidOperationException("name broke")
                : broken.ContainsKey("null:" + j.JobId) ? null
                : "j-" + j.JobName,
            OptionsFor = j => broken.ContainsKey("options:" + j.JobId) ? throw new InvalidOperationException("options broke") : new JobOptions(),
        };
        const string Tail = "; it keeps its last declaration until that works";
        var clock = Clock();
        await using var k = Kit(cron.Source(options), store, clock);

        // First sight, with job 1's name function throwing and job 2's giving null: only those
        // two are skipped.
        broken["throw:1"] = true;
        broken["null:2"] = true;
        FakeCron.Detail first = cron.Add(3, "succeeded", T0 - 60_000, T0 - 59_000, "ok");
        await k.Cw.CheckAsync();
        Assert.Equal(["j-four", "j-three"], await StoredNames(store));
        Assert.Equal("j-three", (await GetRun(k, "pgcron:" + first.RunId)).Job);
        Assert.Equal(
            [
                "pg_cron job 1: jobName threw InvalidOperationException: name broke" + Tail,
                "pg_cron job 2: jobName returned null, not a name" + Tail,
            ],
            Others(k));

        // Once they work, both are declared; then every function fails in turn for jobs already
        // declared.
        broken.Clear();
        await k.Cw.CheckAsync();
        Assert.Equal(["j-four", "j-one", "j-three", "j-two"], await StoredNames(store));
        broken["pick:1"] = true;
        broken["null:2"] = true;
        broken["options:3"] = true;
        broken["throw:4"] = true;
        k.Errors.Entries.Clear();
        FakeCron.Detail one = cron.Add(1, "failed", T0 + 1000, T0 + 2000, "ERROR:  one");
        FakeCron.Detail three = cron.Add(3, "succeeded", T0 + 1000, T0 + 2000, "ok");
        clock.Advance(5000);
        await k.Cw.CheckAsync();
        await k.Cw.CheckAsync();
        // Each reported once, over two syncs.
        Assert.Equal(
            [
                "pg_cron job 1: the jobs callback threw InvalidOperationException: pick broke" + Tail,
                "pg_cron job 2: jobName returned null, not a name" + Tail,
                "pg_cron job 3: the options callback threw InvalidOperationException: options broke" + Tail,
                "pg_cron job 4: jobName threw InvalidOperationException: name broke" + Tail,
            ],
            Others(k));
        // Each keeps its name and schedule, is not retired, and its runs are still copied.
        foreach (StoredJob stored in await store.ListJobsAsync())
        {
            Assert.Equal("0 * * * *", stored.Definition.Schedule);
            string description = stored.Definition.Description ?? "";
            Assert.DoesNotContain("no longer", description, StringComparison.Ordinal);
            Assert.DoesNotContain("renamed", description, StringComparison.Ordinal);
        }
        Assert.Equal("j-one", (await GetRun(k, "pgcron:" + one.RunId)).Job);
        Assert.Equal("j-three", (await GetRun(k, "pgcron:" + three.RunId)).Job);

        // Working again and then failing again is reported again.
        broken.Clear();
        await k.Cw.CheckAsync();
        broken["pick:1"] = true;
        await k.Cw.CheckAsync();
        var others = Others(k);
        Assert.Equal(5, others.Count);
        Assert.StartsWith("pg_cron job 1: the jobs callback threw", others[4], StringComparison.Ordinal);
    }

    [Fact]
    public async Task A_jobs_options_apply_and_a_schedule_it_cannot_read_is_reported()
    {
        var cron = new FakeCron();
        cron.AddJob(1, "odd", "not a schedule");
        var clock = Clock();
        await using var k = Kit(cron.Source(new PgCronOptions { Options = new JobOptions { Grace = "1m", Expect = Expect.Matches("rows?") } }), clock: clock);
        cron.Add(1, "succeeded", clock.Ms() - 1000, clock.Ms(), "nothing");
        CheckResult result = await k.Cw.CheckAsync();
        Assert.Null(result.Jobs[0].Definition.Schedule);
        Assert.Equal("1m", result.Jobs[0].Definition.Get("grace"));
        Assert.Contains(k.Errors.Messages(), e => e.Contains("watching it without a schedule", StringComparison.Ordinal));
        Run run = (await k.Cw.RunsAsync("odd", 20))[0];
        // Expect applies to imported output.
        Assert.Equal(RunStatus.Failed, run.Status);
        Assert.Contains("did not match", run.Error, StringComparison.Ordinal);
    }

    [Fact]
    public async Task A_run_cut_off_by_a_restart_is_recorded_and_one_held_run_never_stops_the_others()
    {
        var clock = Clock();
        var cron = new FakeCron();
        cron.AddJob(1, "fast", "30 seconds");
        cron.AddJob(2, "other", "0 * * * *");
        await using var k = Kit(cron.Source(), clock: clock);
        cron.Add(1, "succeeded", T0 - 60_000, T0 - 59_000, "1 row");
        await k.Cw.CheckAsync();
        // pg_cron restarts while a run is queued: it marks it failed, "server restarted", with no
        // times at all.
        FakeCron.Detail restarted = cron.Add(1, "failed", null, null, "server restarted");
        // The fast job then runs far more than a page's worth, and the other job fails after all
        // of them.
        for (int i = 0; i < 520; i++)
        {
            cron.Add(1, "succeeded", T0 - 50_000 + i, T0 - 50_000 + i + 1, "1 row");
        }
        FakeCron.Detail failure = cron.Add(2, "failed", T0 - 1000, T0 - 500, "ERROR:  disk full");
        FakeCron.Detail queued = cron.Add(1, "starting", null, null);
        clock.Advance(1000);
        await k.Cw.CheckAsync();
        await k.Cw.CheckAsync();
        Run cut = await GetRun(k, "pgcron:" + restarted.RunId);
        Assert.Equal(RunStatus.Failed, cut.Status);
        Assert.Equal("server restarted", cut.Error);
        // Placed at the job's newest run before it.
        Assert.Equal(T0 - 60_000, cut.StartedAt);
        // The other job's failure is not starved.
        Assert.Equal(RunStatus.Failed, (await GetRun(k, "pgcron:" + failure.RunId)).Status);
        Assert.Contains(k.Alerts.List(), a => a.Type.Value == "failed" && a.Job == "other");
        // A queued run is held.
        Assert.Null(await k.Cw.GetRunAsync("pgcron:" + queued.RunId));

        // Held only so long: then it is copied as running from when it was first seen, and a late
        // start updates nothing but its end.
        clock.Advance(11 * Min);
        await k.Cw.CheckAsync();
        Run waiting = await GetRun(k, "pgcron:" + queued.RunId);
        Assert.Equal(RunStatus.Running, waiting.Status);
        Assert.Equal(T0 + 1000, waiting.StartedAt);
        queued.Status = "succeeded";
        queued.Start = clock.Ms() - 2000;
        queued.End = clock.Ms() - 1000;
        clock.Advance(1000);
        await k.Cw.CheckAsync();
        Assert.Equal(RunStatus.Ok, (await GetRun(k, "pgcron:" + queued.RunId)).Status);
        Assert.Empty(Others(k));
    }

    [Fact]
    public async Task First_sight_never_judges_history_even_with_a_held_or_cut_off_run_among_the_newest()
    {
        var cron = new FakeCron();
        cron.AddJob(1, "nightly", "0 3 * * *");
        for (int i = 0; i < 30; i++)
        {
            cron.Add(1, "failed", T0 - ((40 - i) * Hour), T0 - ((40 - i) * Hour) + 1000, "ERROR:  old");
        }
        cron.Add(1, "failed", null, null, "server restarted");
        for (int i = 0; i < 19; i++)
        {
            long at = T0 - (long)((10 - (i / 2.0)) * Hour);
            cron.Add(1, "succeeded", at, at + 1000, "ok");
        }
        await using var k = Kit(cron.Source());
        await k.Cw.CheckAsync();
        await k.Cw.CheckAsync();
        // Only the newest twenty are copied, and no alert comes from history.
        Assert.Equal(20, (await k.Cw.RunsAsync("nightly", 500)).Count);
        Assert.Empty(k.Alerts.Types());
    }

    [Fact]
    public async Task A_renamed_job_leaves_no_scheduled_ghost_in_this_process_or_the_next()
    {
        var clock = Clock();
        var cron = new FakeCron();
        FakeCron.Job rollup = cron.AddJob(1, "rollup", "*/5 * * * *");
        cron.Add(1, "succeeded", T0 - 60_000, T0 - 59_000, "1 row");
        var store = new MemoryStore();
        var k = Kit(cron.Source(), store, clock);
        await k.Cw.CheckAsync();
        rollup.JobName = "rollup-v2";
        FakeCron.Detail running = cron.Add(1, "running", T0 - 1000, null);
        await k.Cw.CheckAsync();
        var summary = await k.Cw.JobsAsync();
        JobSummary old = Find(summary, "rollup");
        Assert.Null(old.Definition.Schedule);
        Assert.Contains("renamed to rollup-v2", old.Definition.Description, StringComparison.Ordinal);
        Assert.Equal("*/5 * * * *", Find(summary, "rollup-v2").Definition.Schedule);
        Assert.Equal("rollup-v2", (await GetRun(k, "pgcron:" + running.RunId)).Job);
        running.Status = "succeeded";
        running.End = T0;
        clock.Advance(Hour);
        cron.Add(1, "succeeded", clock.Ms() - 2000, clock.Ms() - 1000, "1 row");
        await k.Cw.CheckAsync();
        Assert.Equal(RunStatus.Ok, (await GetRun(k, "pgcron:" + running.RunId)).Status);
        var alerts = k.Alerts.List();
        var errors = Others(k);
        await k.DisposeAsync();

        // Renamed again while no process watched: the next process retires the name the store
        // still schedules.
        rollup.JobName = "rollup-v3";
        k = Kit(cron.Source(), store, clock);
        clock.Advance(Min);
        await k.Cw.CheckAsync();
        summary = await k.Cw.JobsAsync();
        Assert.Null(Find(summary, "rollup-v2").Definition.Schedule);
        Assert.Contains("renamed to rollup-v3", Find(summary, "rollup-v2").Definition.Description, StringComparison.Ordinal);
        Assert.Equal("*/5 * * * *", Find(summary, "rollup-v3").Definition.Schedule);
        // Runs already copied under an old name are not copied again.
        Assert.Empty(await k.Cw.RunsAsync("rollup-v3", 20));
        clock.Advance(Hour);
        await k.Cw.CheckAsync();
        alerts.AddRange(k.Alerts.List());
        // Never missed under an old name: only the job's current name can be missed.
        Assert.Empty(TypeAndJob(alerts.Where(a => a.Job != "rollup-v3")));
        errors.AddRange(Others(k));
        Assert.Empty(errors);
        await k.DisposeAsync();
    }

    [Fact]
    public async Task A_job_paused_or_renamed_while_missed_closes_missed_with_a_recovery()
    {
        var clock = Clock();
        var cron = new FakeCron();
        FakeCron.Job hourly = cron.AddJob(1, "hourly", "0 * * * *");
        FakeCron.Job rollup = cron.AddJob(2, "rollup", "0 * * * *");
        cron.Add(1, "succeeded", T0 - (3 * Hour), T0 - (3 * Hour) + 1000);
        cron.Add(2, "succeeded", T0 - (3 * Hour), T0 - (3 * Hour) + 1000);
        await using var k = Kit(cron.Source(), clock: clock);
        await k.Cw.CheckAsync();
        Assert.Equal(["missed hourly", "missed rollup"], TypeAndJob(k.Alerts.List()));
        hourly.Active = false;
        rollup.JobName = "rollup-v2";
        clock.Advance(Min);
        CheckResult r = await k.Cw.CheckAsync();
        Assert.Equal(
            ["recovered hourly hourly is no longer scheduled", "recovered rollup rollup is no longer scheduled"],
            r.Alerts.Select(a => a.Type.Value + " " + a.Job + " " + a.Title).Order(StringComparer.Ordinal));
        clock.Advance(Min);
        Assert.Empty((await k.Cw.CheckAsync()).Alerts);
    }

    [Fact]
    public async Task A_run_marked_timeout_by_a_check_is_still_read_and_its_late_finish_recorded()
    {
        var clock = Clock();
        var cron = new FakeCron();
        cron.AddJob(1, "vacuum", "0 3 * * *");
        await using var k = Kit(cron.Source(new PgCronOptions { Options = new JobOptions { Timeout = "30m" } }), clock: clock);
        FakeCron.Detail running = cron.Add(1, "running", T0, null);
        await k.Cw.CheckAsync();
        Assert.Equal(RunStatus.Running, (await GetRun(k, "pgcron:" + running.RunId)).Status);
        clock.Advance(45 * Min);
        await k.Cw.CheckAsync();
        Assert.Equal(RunStatus.Timeout, (await GetRun(k, "pgcron:" + running.RunId)).Status);
        Assert.Equal(["stuck"], k.Alerts.Types());
        clock.Advance(10 * Min);
        running.Status = "succeeded";
        running.End = clock.Ms() - 60_000;
        running.Message = "VACUUM";
        await k.Cw.CheckAsync();
        Run done = await GetRun(k, "pgcron:" + running.RunId);
        Assert.Equal(RunStatus.Ok, done.Status);
        Assert.Equal("VACUUM", done.Output);
        Assert.Equal(["stuck", "recovered"], k.Alerts.Types());
        Assert.Equal(JobHealth.Healthy, (await k.Cw.JobSummaryAsync("vacuum"))!.Health);
    }

    [Fact]
    public async Task Settings_a_role_may_not_read_are_assumed_and_reported_once()
    {
        var cron = new FakeCron();
        cron.Settings["cron.timezone"] = null;
        cron.Settings["cron.log_run"] = null;
        cron.AddJob(1, "nightly", "0 3 * * *");
        await using var k = Kit(cron.Source());
        CheckResult first = await k.Cw.CheckAsync();
        await k.Cw.CheckAsync();
        Assert.Equal("UTC", first.Jobs[0].Definition.Timezone);
        Assert.Single(k.Errors.Messages(), e => e.Contains("cron.timezone", StringComparison.Ordinal));
        // cron.log_run unreadable is taken as on.
        Assert.DoesNotContain(k.Errors.Messages(), e => e.Contains("log_run", StringComparison.Ordinal));
    }

    [Fact]
    public async Task The_sources_queries_and_jobs_picked_by_name_or_id()
    {
        var cron = new FakeCron();
        cron.Settings["cron.log_run"] = "off";
        cron.AddJob(1, "nightly", "0 3 * * *");
        cron.Add(1, "succeeded", T0 - 1000, T0);
        await using (var k = Kit(cron.Source(new PgCronOptions { Timezone = "America/New_York", JobIds = [1] })))
        {
            CheckResult r = await k.Cw.CheckAsync();
            // No schedule and no runs read when pg_cron records no runs.
            Assert.Null(r.Jobs[0].Definition.Schedule);
            Assert.Empty(await k.Cw.RunsAsync("nightly", 20));
            Assert.Contains(k.Errors.Messages(), e => e.Contains("cron.log_run is off", StringComparison.Ordinal));
        }
        foreach (string q in cron.Queries)
        {
            Assert.DoesNotContain("current_setting", q, StringComparison.Ordinal);
            Assert.DoesNotContain("COMMIT", q, StringComparison.Ordinal);
            Assert.DoesNotContain("ROLLBACK", q, StringComparison.Ordinal);
        }

        var two = new FakeCron();
        two.AddJob(1, "a", "0 3 * * *");
        two.AddJob(2, "b", "0 3 * * *");
        two.AddJob(3, "c", "0 3 * * *");
        await using (var k = Kit(two.Source(new PgCronOptions { Jobs = ["b"], JobIds = [3] })))
        {
            Assert.Equal(["b", "c"], Names(await k.Cw.CheckAsync()));
        }
    }

    [Fact]
    public async Task The_options_are_checked_without_quoting_their_values()
    {
        var both = Assert.Throws<CronwatchException>(() => new FakeCron().Source(new PgCronOptions { Jobs = ["x"], Pick = _ => true }));
        Assert.Equal("PgCronOptions: give Pick, or Jobs and JobIds, not both", both.Message);
        Assert.Equal(CronwatchErrorKind.Invalid, both.Kind);
        var schedule = Assert.Throws<CronwatchException>(() => new FakeCron().Source(new PgCronOptions { Options = new JobOptions { Schedule = "secret-looking 0 3 * * *" } }));
        Assert.DoesNotContain("secret-looking", schedule.Message, StringComparison.Ordinal);
        var twice = Assert.Throws<CronwatchException>(() => new FakeCron().Source(new PgCronOptions { Options = new JobOptions(), OptionsFor = _ => null }));
        Assert.Equal("PgCronOptions: give Options or OptionsFor, not both", twice.Message);

        // Options a function gives that set a schedule are reported, and that job is not declared.
        var cron = new FakeCron();
        cron.AddJob(1, "a", "0 3 * * *");
        cron.AddJob(2, "b", "0 3 * * *");
        await using (var k = Kit(cron.Source(new PgCronOptions { OptionsFor = j => j.JobId == 1 ? new JobOptions { Timezone = "Europe/Paris" } : new JobOptions() })))
        {
            Assert.Equal(["b"], Names(await k.Cw.CheckAsync()));
            Assert.Contains(k.Errors.Messages(), e => e.Contains("may not set a schedule or timezone", StringComparison.Ordinal));
        }

        var o = new PgCronOptions { Prefix = "db:", Timezone = "UTC", JobName = j => j.JobName };
        Assert.Equal("PgCronOptions(Prefix, JobName, Timezone)", o.ToString());
        Assert.Equal("PgCronSource(PgCronOptions(Prefix, JobName, Timezone))", new FakeCron().Source(o).ToString());
        Assert.Equal("pg_cron", new FakeCron().Source(o).Name);
        Assert.Throws<ArgumentNullException>(() => new PgCronSource((System.Data.Common.DbDataSource)null!));
    }

    [Fact]
    public void The_array_literals_hold_what_they_are_given()
    {
        Assert.Equal("{}", PgCronSource.ArrayOf([]));
        Assert.Equal("{1,-2,9007199254740993}", PgCronSource.ArrayOf([1, -2, 9_007_199_254_740_993]));
    }
}
