using System;
using System.Collections.Concurrent;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;
using Cronwatch.Bridge;
using Microsoft.Extensions.DependencyInjection;
using Quartz;
using Xunit;
using static Cronwatch.Quartz.Tests.QuartzSupport;

namespace Cronwatch.Quartz.Tests;

/// <summary>A real Quartz.NET 4 scheduler on the RAM store, watched: jobs declared from its triggers and firings recorded as runs.</summary>
public class CronwatchQuartzTests
{
    private static readonly TimeSpan Settle = TimeSpan.FromSeconds(30);

    [Fact]
    public async Task Jobs_are_declared_from_their_triggers()
    {
        await using var m = Client();
        IScheduler scheduler = await BuildAsync();
        try
        {
            TimeZoneInfo ny = TimeZoneInfo.FindSystemTimeZoneById("America/New_York");
            await scheduler.AddJob(JobBuilder.Create<NoopJob>().WithIdentity("zoned").StoreDurably().Build(), default, default);
            await scheduler.ScheduleJob(Cron("zoned", "zoned", "0 0 2 * * ?", ny), default, default);
            await scheduler.ScheduleJob(JobBuilder.Create<NoopJob>().WithIdentity("yearly").Build(), Cron("yearly", "yearly", "0 30 4 * * ? *"), default, default);
            await scheduler.ScheduleJob(JobBuilder.Create<NoopJob>().WithIdentity("nightly", "reports").Build(), Cron(new JobKey("nightly", "reports"), "nightly", "0 15 3 ? * *"), default, default);
            await scheduler.ScheduleJob(JobBuilder.Create<NoopJob>().WithIdentity("weekday").Build(), Cron("weekday", "weekday", "0 0 9 ? * 2"), default, default);
            ITrigger simple = TriggerBuilder.Create(TimeProvider.System).WithIdentity("simple").ForJob("simple").StartAt(DateTimeOffset.UtcNow.AddDays(1))
                .WithSchedule(SimpleScheduleBuilder.Create().WithInterval(TimeSpan.FromMinutes(90)).RepeatForever()).Build();
            await scheduler.ScheduleJob(JobBuilder.Create<NoopJob>().WithIdentity("simple").Build(), simple, default, default);
            ITrigger fast = TriggerBuilder.Create(TimeProvider.System).WithIdentity("fast").ForJob("fast").StartAt(DateTimeOffset.UtcNow.AddDays(1))
                .WithSchedule(SimpleScheduleBuilder.Create().WithInterval(TimeSpan.FromMilliseconds(500)).RepeatForever()).Build();
            await scheduler.ScheduleJob(JobBuilder.Create<NoopJob>().WithIdentity("fast").Build(), fast, default, default);
            await scheduler.ScheduleJob(JobBuilder.Create<NoopJob>().WithIdentity("two").Build(), [Cron("two", "two-a", "0 0 1 * * ?"), Cron("two", "two-b", "0 0 2 * * ?")], default, default);

            var options = new CronwatchQuartzOptions { App = "billing", JobDefaults = new JobOptions { Grace = "5m" } };
            options.Jobs["reports.nightly"] = new JobOptions { Expect = "Report written" };
            await using CronwatchQuartz q = await CronwatchQuartz.WatchAsync(m.Cw, scheduler, options);
            Assert.True(await q.SettleAsync(Settle));
            Assert.Equal(
                "{\"grace\":\"5m\",\"schedule\":\"0 0 2 * * *\",\"timezone\":\"America/New_York\",\"tags\":[\"quartz\",\"quartz:billing\"],\"name\":\"zoned\"}",
                await Stored(m.Store, "zoned"));
            Assert.Equal(
                "{\"grace\":\"5m\",\"schedule\":\"0 30 4 * * *\",\"timezone\":\"UTC\",\"tags\":[\"quartz\",\"quartz:billing\"],\"name\":\"yearly\"}",
                await Stored(m.Store, "yearly"));
            Assert.Equal(
                "{\"grace\":\"5m\",\"schedule\":\"0 15 3 * * *\",\"timezone\":\"UTC\",\"tags\":[\"quartz\",\"quartz:billing\"],\"name\":\"reports.nightly\",\"expect\":\"contains \\\"Report written\\\"\"}",
                await Stored(m.Store, "reports.nightly"));
            Assert.Equal("{\"grace\":\"5m\",\"schedule\":\"every 1h30m\",\"tags\":[\"quartz\",\"quartz:billing\"],\"name\":\"simple\"}", await Stored(m.Store, "simple"));
            Assert.Equal("{\"grace\":\"5m\",\"tags\":[\"quartz\",\"quartz:billing\"],\"name\":\"weekday\"}", await Stored(m.Store, "weekday"));
            Assert.Equal("{\"grace\":\"5m\",\"tags\":[\"quartz\",\"quartz:billing\"],\"name\":\"fast\"}", await Stored(m.Store, "fast"));
            Assert.Equal("{\"grace\":\"5m\",\"tags\":[\"quartz\",\"quartz:billing\"],\"name\":\"two\"}", await Stored(m.Store, "two"));
            string errors = string.Join("\n", m.Errors);
            Assert.Contains("declaring Quartz job \"weekday\": cronwatch: Quartz job \"weekday\" is \"0 0 9 * * 2\" in UTC, but after a run at", errors, StringComparison.Ordinal);
            Assert.Contains("repeats every 500ms, more often than CronWatch's shortest schedule of one second", errors, StringComparison.Ordinal);
            Assert.Contains("\"two\" is run by 2 Quartz entries on different schedules", errors, StringComparison.Ordinal);

            // Each cron is walked once for its job, expression, zone and year: another read walks
            // nothing, and reports nothing again.
            int walks = q.Checks.Walks;
            int reported = m.Errors.Count;
            await q.SyncAsync();
            Assert.Equal(walks, q.Checks.Walks);
            Assert.Equal(reported, m.Errors.Count);
        }
        finally
        {
            await scheduler.Shutdown(false, default);
        }
    }

    [Fact]
    public async Task A_firing_is_a_run_and_current_inside_the_job_with_the_container()
    {
        await using var m = Client();
        var services = new ServiceCollection();
        services.AddSingleton(m.Cw);
        services.AddQuartz(q =>
        {
            q.ConfigureScheduler(o => o.InstanceName = "di-" + Guid.NewGuid().ToString("N"));
            q.UseCronwatch(o => o.App = "billing");
        });
        await using ServiceProvider provider = services.BuildServiceProvider();
        IScheduler scheduler = await provider.GetRequiredService<ISchedulerFactory>().GetScheduler(default);
        try
        {
            await scheduler.Start(default);
            JobContext? seen = null;
            await scheduler.ScheduleJob(Job("report", ctx =>
            {
                seen = CronwatchClient.Current;
                CronwatchClient.Current!.Log("Report written");
                return default;
            }), Once("report"), default, default);
            await Eventually("the run", async () => (await Runs(m.Cw, "report")) is [{ Status.Value: "ok" }]);
            Run run = (await Runs(m.Cw, "report"))[0];
            Assert.Equal("Report written", run.Output);
            Assert.Equal("quartz", run.Trigger);
            Assert.StartsWith("quartz:billing:NON_CLUSTERED.", run.Id, StringComparison.Ordinal);
            Assert.Equal(run.Id, seen!.RunId);
            Assert.Null(CronwatchClient.Current);
        }
        finally
        {
            await scheduler.Shutdown(true, default);
        }
    }

    [Fact]
    public async Task A_job_failing_twice_through_refires_then_succeeding_alerts_once_and_recovers()
    {
        await using var m = Client();
        IScheduler scheduler = await BuildAsync(q => q.UseCronwatch(m.Cw));
        try
        {
            await scheduler.Start(default);
            await scheduler.ScheduleJob(Job("flaky", ctx =>
            {
                if (ctx.RefireCount < 2)
                {
                    throw new JobExecutionException("attempt " + ctx.RefireCount + " failed") { RefireImmediately = true };
                }
                CronwatchClient.Current!.Log("third time");
                return default;
            }), Once("flaky"), default, default);
            await Eventually("three runs", async () => (await Runs(m.Cw, "flaky")).Count(r => r.Status != RunStatus.Running) == 3);
            var runs = await Runs(m.Cw, "flaky");
            Assert.Equal(["failed", "failed", "ok"], runs.Select(r => r.Status.Value).ToList());
            Assert.Equal("JobExecutionException: attempt 0 failed", Line(runs[0].Error));
            Assert.Equal("JobExecutionException: attempt 1 failed", Line(runs[1].Error));
            Assert.EndsWith(":0", runs[0].Id, StringComparison.Ordinal);
            Assert.EndsWith(":2", runs[2].Id, StringComparison.Ordinal);
            Assert.Equal("third time", runs[2].Output);
            await Eventually("the alerts", () => m.Alerts.Types().Count == 2);
            Assert.Equal(["failed", "recovered"], m.Alerts.Types());
        }
        finally
        {
            await scheduler.Shutdown(true, default);
        }
    }

    private static string Line(string? text) => text == null ? "" : text.Split('\n')[0];

    [Fact]
    public async Task A_throw_is_a_failed_run_with_the_jobs_own_exception()
    {
        await using var m = Client();
        IScheduler scheduler = await BuildAsync(q => q.UseCronwatch(m.Cw));
        try
        {
            await scheduler.Start(default);
            await scheduler.ScheduleJob(Job("broken", _ => throw new InvalidOperationException("db down")), Once("broken"), default, default);
            await Eventually("the failed run", async () => (await Runs(m.Cw, "broken")) is [{ Status.Value: "failed" }]);
            Assert.Equal("InvalidOperationException: db down", Line((await Runs(m.Cw, "broken"))[0].Error));
        }
        finally
        {
            await scheduler.Shutdown(true, default);
        }
    }

    private sealed class Veto(ConcurrentQueue<string> vetoed) : ITriggerListener
    {
        public string Name => "veto";

        public ValueTask<bool> VetoJobExecution(ITrigger trigger, IJobExecutionContext context, CancellationToken cancellationToken)
        {
            vetoed.Enqueue(trigger.Key.Name);
            return ValueTask.FromResult(true);
        }
    }

    [Fact]
    public async Task A_vetoed_firing_opens_nothing()
    {
        await using var m = Client();
        var vetoed = new ConcurrentQueue<string>();
        IScheduler scheduler = await BuildAsync(q => q.UseCronwatch(m.Cw));
        try
        {
            scheduler.ListenerManager.AddTriggerListener(new Veto(vetoed), [Matchers.AllTriggers()]);
            await scheduler.Start(default);
            await scheduler.ScheduleJob(Job("vetoed", _ => default), Once("vetoed"), default, default);
            await Eventually("the veto", () => !vetoed.IsEmpty);
            Assert.Empty(await m.Cw.RunsAsync("vetoed", 10));
        }
        finally
        {
            await scheduler.Shutdown(true, default);
        }
    }

    private sealed class Thrower : IJobListener
    {
        public string Name => "thrower";

        public ValueTask JobToBeExecuted(IJobExecutionContext context, CancellationToken cancellationToken) => throw new InvalidOperationException("listener fell over");
    }

    private sealed class Errors(ConcurrentQueue<string> seen) : ISchedulerListener
    {
        public string Name => "errors";

        public ValueTask SchedulerError(IScheduler scheduler, SchedulerErrorContext error, CancellationToken cancellationToken)
        {
            seen.Enqueue(error.Message);
            return default;
        }
    }

    [Fact]
    public async Task A_firing_a_listener_after_ours_stopped_is_given_back()
    {
        await using var m = Client();
        var errors = new ConcurrentQueue<string>();
        int ran = 0;
        IScheduler scheduler = await BuildAsync(q => q.UseCronwatch(m.Cw));
        try
        {
            await scheduler.Start(default);
            scheduler.ListenerManager.AddJobListener(new Thrower(), [Matchers.AllJobs()]);
            scheduler.ListenerManager.AddSchedulerListener(new Errors(errors));
            await scheduler.ScheduleJob(Job("stopped", _ =>
            {
                Interlocked.Increment(ref ran);
                return default;
            }), Once("stopped"), default, default);
            await Eventually("the error", () => errors.Any(e => e.StartsWith("Unable to notify JobListener(s)", StringComparison.Ordinal)));
            await Eventually("the run given back", async () => (await m.Cw.RunsAsync("stopped", 10)).Count == 0 && m.Cw.DefinedJobs.Any(d => d.Name == "stopped"));
            Assert.Equal(0, Volatile.Read(ref ran));
            Assert.Empty(m.Alerts.Types());
        }
        finally
        {
            await scheduler.Shutdown(true, default);
        }
    }

    [Fact]
    public async Task Without_the_container_the_job_reads_its_run_from_the_context()
    {
        await using var m = Client();
        IScheduler scheduler = await BuildAsync();
        try
        {
            await using CronwatchQuartz q = await CronwatchQuartz.WatchAsync(m.Cw, scheduler);
            await scheduler.Start(default);
            JobContext? before = null;
            await scheduler.ScheduleJob(Job("plain", ctx =>
            {
                before = CronwatchClient.Current;
                using (ctx.CronwatchRun()?.MakeCurrent())
                {
                    CronwatchClient.Current!.Log("made current");
                }
                return default;
            }), Once("plain"), default, default);
            await Eventually("the run", async () => (await Runs(m.Cw, "plain")) is [{ Status.Value: "ok" }]);
            Assert.Null(before);
            Assert.Equal("made current", (await Runs(m.Cw, "plain"))[0].Output);
        }
        finally
        {
            await scheduler.Shutdown(true, default);
        }
    }

    [Fact]
    public async Task A_job_deleted_at_run_time_is_declared_again_without_its_schedule()
    {
        await using var m = Client();
        IScheduler scheduler = await BuildAsync();
        try
        {
            await scheduler.ScheduleJob(JobBuilder.Create<NoopJob>().WithIdentity("gone").Build(), Cron("gone", "gone", "0 0 2 * * ?"), default, default);
            await scheduler.ScheduleJob(JobBuilder.Create<NoopJob>().WithIdentity("kept").Build(), Cron("kept", "kept", "0 0 3 * * ?"), default, default);
            await using CronwatchQuartz q = await CronwatchQuartz.WatchAsync(m.Cw, scheduler, new CronwatchQuartzOptions { App = "billing" });
            await scheduler.Start(default);
            Assert.True(await q.SettleAsync(Settle));
            Assert.Contains("\"schedule\":\"0 0 2 * * *\"", await Stored(m.Store, "gone"), StringComparison.Ordinal);
            await scheduler.DeleteJob(new JobKey("gone"), default);
            await Eventually("the job declared again", async () =>
            {
                await q.SettleAsync(Settle);
                return (await Stored(m.Store, "gone"))!.Contains("no longer scheduled", StringComparison.Ordinal);
            });
            Assert.Equal(
                "{\"description\":\"A scheduled task (no longer scheduled)\",\"tags\":[\"quartz\",\"quartz:billing\"],\"name\":\"gone\"}",
                await Stored(m.Store, "gone"));
            Assert.Contains("\"schedule\":\"0 0 3 * * *\"", await Stored(m.Store, "kept"), StringComparison.Ordinal);
        }
        finally
        {
            await scheduler.Shutdown(true, default);
        }
    }

    [Fact]
    public async Task The_check_job_unschedules_a_job_the_scheduler_dropped()
    {
        var store = new MemoryStore();
        await using (var earlier = Client(store))
        {
            earlier.Cw.Job("dropped", new JobOptions { Schedule = "0 1 * * *", Tags = ["quartz", "quartz:billing"] });
            earlier.Cw.Job("other-app", new JobOptions { Schedule = "0 1 * * *", Tags = ["quartz", "quartz:search"] });
            await earlier.Cw.CheckAsync();
        }
        await using var m = Client(store);
        IScheduler scheduler = await BuildAsync(q => q.UseCronwatch(m.Cw, o =>
        {
            o.App = "billing";
            o.ScheduleCheck = true;
        }));
        try
        {
            await scheduler.ScheduleJob(JobBuilder.Create<NoopJob>().WithIdentity("kept").Build(), Cron("kept", "kept", "0 0 3 * * ?"), default, default);
            await scheduler.Start(default);
            await Eventually("the check's sync", async () => (await Stored(store, "dropped"))!.Contains("no longer scheduled", StringComparison.Ordinal));
            Assert.Contains("\"schedule\":\"0 1 * * *\"", await Stored(store, "other-app"), StringComparison.Ordinal);
            Assert.Null(await Stored(store, "cronwatch.cronwatch-check"));
            Assert.Empty(await m.Cw.RunsAsync("cronwatch.cronwatch-check", 10));
        }
        finally
        {
            await scheduler.Shutdown(true, default);
        }
    }

    [Fact]
    public async Task Two_apps_and_two_instances_sharing_a_store_never_share_a_run_id()
    {
        var store = new MemoryStore();
        await using var a = Client(store);
        await using var b = Client(store);
        await using var c = Client(store);
        IScheduler billing = await BuildAsync(q => q.UseCronwatch(a.Cw, o => o.App = "billing"));
        IScheduler search = await BuildAsync(q => q.UseCronwatch(b.Cw, o => o.App = "search"));
        IScheduler billing2 = await BuildAsync(q => q.UseCronwatch(c.Cw, o => o.App = "billing"));
        try
        {
            foreach (IScheduler s in new[] { billing, search, billing2 })
            {
                await s.Start(default);
                await s.ScheduleJob(Job("shared", _ => default), Once("shared"), default, default);
            }
            await Eventually("three runs", async () => (await a.Cw.RunsAsync("shared", 10)).Count(r => r.Status == RunStatus.Ok) == 3);
            var ids = (await a.Cw.RunsAsync("shared", 10)).Select(r => r.Id).ToList();
            Assert.Equal(3, ids.Distinct(StringComparer.Ordinal).Count());
            Assert.Equal(2, ids.Count(id => id.StartsWith("quartz:billing:", StringComparison.Ordinal)));
            Assert.Single(ids, id => id.StartsWith("quartz:search:", StringComparison.Ordinal));
        }
        finally
        {
            foreach (IScheduler s in new[] { billing, search, billing2 })
            {
                await s.Shutdown(true, default);
            }
        }
    }

    [Fact]
    public async Task Stopping_takes_the_listeners_off_the_scheduler()
    {
        await using var m = Client();
        IScheduler scheduler = await BuildAsync();
        try
        {
            CronwatchQuartz q = await CronwatchQuartz.WatchAsync(m.Cw, scheduler);
            Assert.Contains(scheduler.ListenerManager.GetJobListeners(), l => l.Name == CronwatchQuartz.ListenerName);
            await q.DisposeAsync();
            Assert.DoesNotContain(scheduler.ListenerManager.GetJobListeners(), l => l.Name == CronwatchQuartz.ListenerName);
            Assert.DoesNotContain(scheduler.ListenerManager.GetSchedulerListeners(), l => l.Name == CronwatchQuartz.ListenerName);
            Assert.False(scheduler.Context.ContainsKey(CronwatchQuartz.ContextKey));
            await scheduler.Start(default);
            var ran = new TaskCompletionSource();
            await scheduler.ScheduleJob(Job("after", _ =>
            {
                ran.TrySetResult();
                return default;
            }), Once("after"), default, default);
            await ran.Task.WaitAsync(TimeSpan.FromSeconds(60));
            Assert.Empty(await m.Cw.RunsAsync("after", 10));
        }
        finally
        {
            await scheduler.Shutdown(true, default);
        }
    }

    [Fact]
    public async Task A_scheduler_shutting_down_stops_the_watch_cleanly()
    {
        await using var m = Client();
        IScheduler scheduler = await BuildAsync(q => q.UseCronwatch(m.Cw));
        await scheduler.Start(default);
        await scheduler.ScheduleJob(Job("once", _ => default), Once("once"), default, default);
        await Eventually("the run", async () => (await Runs(m.Cw, "once")) is [{ Status.Value: "ok" }]);
        Assert.True(scheduler.Context.ContainsKey(CronwatchQuartz.ContextKey));
        await scheduler.Shutdown(true, default);
        Assert.Empty(m.Errors);
        Assert.False(scheduler.Context.ContainsKey(CronwatchQuartz.ContextKey));
    }

    [Fact]
    public void A_cron_is_read_as_croner_reads_it()
    {
        long now = DateTimeOffset.Parse("2026-09-01T00:00:00Z", System.Globalization.CultureInfo.InvariantCulture).ToUnixTimeMilliseconds();
        Assert.Equal("0 0 2 * * *", CronwatchQuartz.CronOf("x", "0 0 2 * * ?", TimeZoneInfo.Utc, "UTC", now));
        Assert.Equal("0 0 2 * * *", CronwatchQuartz.CronOf("x", "0 0 2 ? * * *", TimeZoneInfo.Utc, "UTC", now));
        Assert.Equal("*/5 * * * * *", CronwatchQuartz.CronOf("x", "*/5 * * * * ?", TimeZoneInfo.Utc, "UTC", now));
        // A year field that names years is kept, and croner reads it as Quartz does.
        Assert.Equal("0 0 2 * * * 2031", CronwatchQuartz.CronOf("x", "0 0 2 ? * * 2031", TimeZoneInfo.Utc, "UTC", now));
        var e = Assert.Throws<ScheduleException>(() => CronwatchQuartz.CronOf("x", "nonsense", TimeZoneInfo.Utc, "UTC", now));
        Assert.Contains("which Quartz cannot read", e.Message, StringComparison.Ordinal);
    }

    [Fact]
    public void Small_parts()
    {
        Assert.Equal("nightly", CronwatchQuartz.NameOf(new JobKey("nightly")));
        Assert.Equal("reports.nightly", CronwatchQuartz.NameOf(new JobKey("nightly", "reports")));
        var root = new InvalidOperationException("root");
        Assert.Same(root, CronwatchQuartz.FailureOf(new JobExecutionException("outer", new SchedulerException("middle", root))));
        var own = new JobExecutionException("own");
        Assert.Same(own, CronwatchQuartz.FailureOf(own));
        Assert.Null(CronwatchQuartz.FailureOf(null));
        Assert.Equal(1_780_000_000_000L, CronwatchQuartz.OriginalFireTime("1780000000000"));
        Assert.Equal(1_780_000_000_000L, CronwatchQuartz.OriginalFireTime(DateTimeOffset.FromUnixTimeMilliseconds(1_780_000_000_000L)));
        Assert.Equal(1_780_000_000_000L, CronwatchQuartz.OriginalFireTime(DateTimeOffset.FromUnixTimeMilliseconds(1_780_000_000_000L).ToString("O", System.Globalization.CultureInfo.InvariantCulture)));
        Assert.Null(CronwatchQuartz.OriginalFireTime("not a time"));
        JobOptions merged = CronwatchQuartz.Merged(new JobOptions { Grace = "5m", Timeout = "1h" }, new JobOptions { Timeout = "2h", Description = "Nightly", Expect = "done" });
        Assert.Equal("{\"grace\":\"5m\",\"timeout\":\"2h\",\"description\":\"Nightly\",\"name\":\"x\",\"expect\":\"contains \\\"done\\\"\"}", merged.Describe("x").ToJson());
        Assert.Equal("America/New_York", CronwatchQuartz.IanaId(TimeZoneInfo.FindSystemTimeZoneById("America/New_York")));
        // A Windows zone id, as Quartz on Windows names a trigger's zone, is converted.
        TimeZoneInfo windows = TimeZoneInfo.CreateCustomTimeZone("Eastern Standard Time", TimeSpan.FromHours(-5), "Eastern", "Eastern");
        Assert.Equal("America/New_York", CronwatchQuartz.IanaId(windows));
        Assert.Null(CronwatchQuartz.IanaId(TimeZoneInfo.CreateCustomTimeZone("Nowhere Standard Time", TimeSpan.FromHours(3), "Nowhere", "Nowhere")));
    }
}
