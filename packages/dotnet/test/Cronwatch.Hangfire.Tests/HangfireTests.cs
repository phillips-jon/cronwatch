using System;
using System.Collections.Generic;
using System.Linq;
using System.Threading.Tasks;
using Hangfire;
using Hangfire.Common;
using Hangfire.States;
using Xunit;
using static Cronwatch.Hangfire.Tests.Harness;
using HangfireJob = global::Hangfire.Common.Job;

namespace Cronwatch.Hangfire.Tests;

/// <summary>
/// Cronwatch.Hangfire against a real Hangfire server on in-memory storage. Hangfire keeps its
/// filters, its storage and its type resolver in statics, so every test is in this one class,
/// whose tests xUnit runs one at a time.
/// </summary>
public class HangfireTests
{
    private static CronwatchHangfireOptions Naming(string method, string name) =>
        new() { Named = new Dictionary<string, string>(StringComparer.Ordinal) { ["Cronwatch.Hangfire.Tests.TestJobs." + method] = name } };

    [Fact]
    public async Task Recurring_jobs_are_declared_on_their_crons()
    {
        await using var h = new Harness(start: false);
        h.Recurring.AddOrUpdate("nightly", () => TestJobs.Nothing(), "0 2 * * *", new RecurringJobOptions { TimeZone = TimeZoneInfo.FindSystemTimeZoneById("Europe/Paris") });
        h.Recurring.AddOrUpdate("windows", () => TestJobs.Nothing(), "30 6 * * *", new RecurringJobOptions { TimeZone = TimeZoneInfo.FindSystemTimeZoneById("W. Europe Standard Time") });
        // Hangfire reads macros such as @daily with the Cronos it carries in later 1.8 releases;
        // 1.8.0's Cronos (0.7.1) refuses them, and so does Hangfire.
        bool macros = true;
        try
        {
            h.Recurring.AddOrUpdate("daily", () => TestJobs.Nothing(), "@daily");
        }
        catch (ArgumentException)
        {
            macros = false;
        }
        h.Recurring.AddOrUpdate("question", () => TestJobs.Nothing(), "0 3 ? * *");
        h.Recurring.AddOrUpdate("seconds", () => TestJobs.Nothing(), "*/10 * * * * *");
        // Cronos runs a cron naming both days only when both match; croner, as cron does, when
        // either does.
        h.Recurring.AddOrUpdate("both", () => TestJobs.Nothing(), "0 0 1 * 1");
        h.Recurring.AddOrUpdate("unread", () => TestJobs.Nothing(), "0 0 L-3 * *");
        await h.Integration.SyncAsync();
        Assert.Equal("{\"schedule\":\"0 2 * * *\",\"timezone\":\"Europe/Paris\",\"tags\":[\"hangfire\",\"hangfire:billing\"],\"name\":\"nightly\"}", await h.StoredAsync("nightly"));
        Assert.Equal("{\"schedule\":\"30 6 * * *\",\"timezone\":\"Europe/Berlin\",\"tags\":[\"hangfire\",\"hangfire:billing\"],\"name\":\"windows\"}", await h.StoredAsync("windows"));
        if (macros)
        {
            Assert.Equal("{\"schedule\":\"@daily\",\"timezone\":\"UTC\",\"tags\":[\"hangfire\",\"hangfire:billing\"],\"name\":\"daily\"}", await h.StoredAsync("daily"));
        }
        Assert.Equal("{\"schedule\":\"0 3 * * *\",\"timezone\":\"UTC\",\"tags\":[\"hangfire\",\"hangfire:billing\"],\"name\":\"question\"}", await h.StoredAsync("question"));
        Assert.Equal("{\"schedule\":\"*/10 * * * * *\",\"timezone\":\"UTC\",\"tags\":[\"hangfire\",\"hangfire:billing\"],\"name\":\"seconds\"}", await h.StoredAsync("seconds"));
        Assert.Equal("{\"tags\":[\"hangfire\",\"hangfire:billing\"],\"name\":\"both\"}", await h.StoredAsync("both"));
        Assert.Equal("{\"tags\":[\"hangfire\",\"hangfire:billing\"],\"name\":\"unread\"}", await h.StoredAsync("unread"));
        var errors = h.Errors.OrderBy(e => e, StringComparer.Ordinal).ToList();
        Assert.Equal(2, errors.Count);
        Assert.StartsWith(
            "declaring Hangfire recurring job \"both\": cronwatch: Hangfire recurring job \"both\" is \"0 0 1 * 1\" in UTC, but after a run at ",
            errors[0],
            StringComparison.Ordinal);
        Assert.Contains("Hangfire runs it next at", errors[0], StringComparison.Ordinal);
        Assert.StartsWith("declaring Hangfire recurring job \"unread\": cronwatch: Hangfire recurring job \"unread\" is \"0 0 L-3 * *\", which CronWatch cannot read", errors[1], StringComparison.Ordinal);

        // Read again, nothing is walked again or reported again.
        int walks = h.Integration.Checks.Walks;
        await h.Integration.SyncAsync();
        Assert.Equal(walks, h.Integration.Checks.Walks);
        Assert.Equal(2, h.Errors.Count);
    }

    [Fact]
    public async Task A_job_failing_twice_through_retries_and_then_succeeding_is_three_runs()
    {
        TestJobs.Attempts.Clear();
        await using var h = new Harness(options: Naming("Flaky", "flaky"));
        string id = h.Client.Enqueue(() => TestJobs.Flaky("retries"));
        await Eventually("three runs, the last ok", async () => (await h.RunsAsync("flaky")).Count(r => r.Status != RunStatus.Running) == 3);
        var runs = (await h.RunsAsync("flaky")).OrderBy(r => r.Id, StringComparer.Ordinal).ToList();
        Assert.Equal(["hangfire:billing:" + id + ":0", "hangfire:billing:" + id + ":1", "hangfire:billing:" + id + ":2"], runs.Select(r => r.Id).ToList());
        Assert.Equal([RunStatus.Failed, RunStatus.Failed, RunStatus.Ok], runs.Select(r => r.Status).ToList());
        Assert.StartsWith("InvalidOperationException: attempt 1 failed", runs[0].Error, StringComparison.Ordinal);
        Assert.Equal(["attempt 1", "attempt 2", "attempt 3"], runs.Select(r => r.Output).ToList());
        Assert.All(runs, r => Assert.Equal("hangfire", r.Trigger));
        await Eventually("the alert and its recovery", () => Task.FromResult(h.Alerts.Types().Count == 2));
        Assert.Equal(["failed", "recovered"], h.Alerts.Types());
        Assert.Empty(h.Errors);
    }

    [Fact]
    public async Task An_async_job_method_sees_its_run_after_an_await()
    {
        TestJobs.Seen.Clear();
        await using var h = new Harness(options: Naming("AsyncWork", "async-work"));
        string id = h.Client.Enqueue(() => TestJobs.AsyncWork("async"));
        await Eventually("the run", async () => (await h.RunsAsync("async-work")).Any(r => r.Status == RunStatus.Ok));
        Run run = (await h.RunsAsync("async-work"))[0];
        Assert.Equal("written after an await", run.Output);
        Assert.Equal("hangfire:billing:" + id + ":0", TestJobs.Seen["async"]);
    }

    [Fact]
    public async Task A_worker_thread_carries_no_run_after_a_job()
    {
        TestJobs.Seen.Clear();
        await using var h = new Harness(workers: 1);
        string first = h.Client.Enqueue(() => TestJobs.Import());
        await Eventually("the named job's run", async () => (await h.RunsAsync("import")).Any(r => r.Status == RunStatus.Ok));
        h.Client.Enqueue(() => TestJobs.Look("after"));
        await Eventually("the job after it", () => Task.FromResult(TestJobs.Seen.ContainsKey("after")));
        Assert.Equal("none", TestJobs.Seen["after"]);
        Run run = Assert.Single(await h.RunsAsync("import"));
        Assert.Equal("hangfire:billing:" + first + ":0", run.Id);
        Assert.Equal("imported", run.Output);
        Assert.Equal("{\"tags\":[\"hangfire\",\"hangfire:billing\"],\"name\":\"import\"}", await h.StoredAsync("import"));
        // A job neither recurring nor named is not watched.
        Assert.Equal(["import"], (await h.Store.ListJobsAsync()).Select(j => j.Name).ToList());
    }

    [Fact]
    public async Task A_recurring_job_firing_each_second_is_recorded_as_its_job()
    {
        TestJobs.Seen.Clear();
        await using var h = new Harness();
        h.Recurring.AddOrUpdate("tick", () => TestJobs.Look("tick"), "* * * * * *");
        await h.Integration.SyncAsync();
        await Eventually("a run of the recurring job", async () => (await h.RunsAsync("tick")).Any(r => r.Status == RunStatus.Ok));
        Run run = (await h.RunsAsync("tick")).First(r => r.Status == RunStatus.Ok);
        Assert.Equal("hangfire", run.Trigger);
        Assert.StartsWith("hangfire:billing:", run.Id, StringComparison.Ordinal);
        Assert.Contains("\"schedule\":\"* * * * * *\"", await h.StoredAsync("tick"), StringComparison.Ordinal);
        await Eventually("the job's own look", () => Task.FromResult(TestJobs.Seen.ContainsKey("tick")));
        Assert.StartsWith("hangfire:billing:", TestJobs.Seen["tick"], StringComparison.Ordinal);
    }

    [Fact]
    public async Task A_job_its_servers_shutdown_stops_is_given_back()
    {
        TestJobs.Started = new(TaskCreationOptions.RunContinuationsAsynchronously);
        await using var h = new Harness(workers: 1, options: Naming("Sleepy", "sleepy"));
        h.Client.Enqueue(() => TestJobs.Sleepy(default));
        await TestJobs.Started.Task.WaitAsync(TimeSpan.FromMinutes(1));
        await Eventually("the run open", async () => (await h.RunsAsync("sleepy")).Count == 1);
        h.StopServer();
        await Eventually("the run given back", async () => (await h.RunsAsync("sleepy")).Count == 0);
        Assert.Empty(h.Alerts.Types());
        Assert.Empty(h.Errors);
    }

    [Fact]
    public async Task A_job_whose_type_no_longer_loads_is_recorded_failed()
    {
        Func<string, Type> previous = TypeHelper.CurrentTypeResolver;
        await using var h = new Harness();
        try
        {
            string id = h.Client.Create(HangfireJob.FromExpression(() => BrokenJob.Run()), new ScheduledState(TimeSpan.FromHours(1)));
            using (var connection = h.Storage.GetConnection())
            {
                connection.SetJobParameter(id, "RecurringJobId", "\"broken\"");
            }
            TypeHelper.CurrentTypeResolver = name => name.Contains("BrokenJob", StringComparison.Ordinal)
                ? throw new TypeLoadException("BrokenJob is gone")
                : TypeHelper.DefaultTypeResolver(name);
            h.Client.Requeue(id);
            await Eventually("the failed run", async () => (await h.RunsAsync("broken")).Any(r => r.Status == RunStatus.Failed));
            Run run = (await h.RunsAsync("broken"))[0];
            Assert.Equal("hangfire:billing:" + id + ":0", run.Id);
            Assert.Contains("BrokenJob is gone", run.Error, StringComparison.Ordinal);
            await Eventually("the failure alert", () => Task.FromResult(h.Alerts.Types().Contains("failed")));
        }
        finally
        {
            TypeHelper.CurrentTypeResolver = previous;
        }
    }

    [Fact]
    public async Task A_recurring_job_deleted_from_hangfire_is_declared_again_without_its_schedule()
    {
        await using var h = new Harness(start: false);
        h.Recurring.AddOrUpdate("report", () => TestJobs.Nothing(), "0 2 * * *");
        h.Recurring.AddOrUpdate("keep", () => TestJobs.Nothing(), "0 3 * * *");
        await h.Integration.SyncAsync();
        Assert.Contains("\"schedule\":\"0 2 * * *\"", await h.StoredAsync("report"), StringComparison.Ordinal);
        h.Recurring.RemoveIfExists("report");
        await h.Integration.SyncAsync();
        Assert.Equal("{\"description\":\"A scheduled task (no longer scheduled)\",\"tags\":[\"hangfire\",\"hangfire:billing\"],\"name\":\"report\"}", await h.StoredAsync("report"));
        Assert.Contains("\"schedule\":\"0 3 * * *\"", await h.StoredAsync("keep"), StringComparison.Ordinal);
    }

    [Fact]
    public async Task The_check_job_unschedules_a_recurring_job_another_process_declared()
    {
        var store = new MemoryStore();
        await using (var earlier = new Harness(store: store, start: false))
        {
            earlier.Recurring.AddOrUpdate("gone", () => TestJobs.Nothing(), "0 2 * * *");
            await earlier.Integration.SyncAsync();
        }
        await using var h = new Harness(store: store);
        h.Recurring.AddOrUpdate("keep", () => TestJobs.Nothing(), "0 3 * * *");
        CronwatchHangfire.ScheduleCheck(h.Recurring, "* * * * * *");
        await Eventually("the job gone declared without its schedule", async () => (await h.StoredAsync("gone"))?.Contains("no longer scheduled", StringComparison.Ordinal) == true);
        Assert.Contains("\"schedule\":\"0 3 * * *\"", await h.StoredAsync("keep"), StringComparison.Ordinal);
        Assert.Null(await h.StoredAsync(CronwatchHangfire.CheckJobId));
        Assert.Empty(h.Errors);
    }

    [Fact]
    public async Task Two_apps_sharing_a_store_give_their_runs_distinct_ids()
    {
        await using var h = new Harness(start: false);
        await using var other = new CronwatchClient(new CronwatchOptions { Store = h.Store, Alerts = [], ProcessExitHook = false });
        using var search = CronwatchHangfire.Start(other, new CronwatchHangfireOptions { App = "Search API" });
        Assert.Equal("hangfire:billing:7:0", h.Integration.RunId("7", 0));
        Assert.Equal("hangfire:search-api:7:0", search.RunId("7", 0));
        Assert.Equal("hangfire:search-api", search.Watch.AppTag);
    }

    [Fact]
    public async Task Stopping_takes_the_filter_off_hangfire()
    {
        TestJobs.Seen.Clear();
        await using var h = new Harness(workers: 1);
        Assert.Contains(GlobalJobFilters.Filters, f => ReferenceEquals(f.Instance, h.Integration.Filter));
        h.Integration.Dispose();
        Assert.DoesNotContain(GlobalJobFilters.Filters, f => ReferenceEquals(f.Instance, h.Integration.Filter));
        h.Client.Enqueue(() => TestJobs.Import());
        h.Client.Enqueue(() => TestJobs.Look("stopped"));
        await Eventually("the jobs run", () => Task.FromResult(TestJobs.Seen.ContainsKey("stopped")));
        Assert.Empty(await h.RunsAsync("import"));
    }

    [Fact]
    public void Default_options_merge_as_the_sdk_spreads_them()
    {
        JobOptions merged = CronwatchHangfire.Merge(new JobOptions { Grace = "5m", Budget = { ["cost"] = 2 } }, new JobOptions { Timeout = "1h", Grace = "10m", Expect = "done" });
        Assert.Equal("{\"grace\":\"10m\",\"budget\":{\"cost\":2},\"timeout\":\"1h\",\"name\":\"x\",\"expect\":\"contains \\\"done\\\"\"}", merged.Describe("x").ToJson());
    }
}
