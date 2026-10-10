using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;
using Quartz;
using Xunit;

namespace Cronwatch.Quartz.Tests;

/// <summary>What the Quartz tests share: a client that keeps its alerts and errors, schedulers of unique names, and a job whose behaviour a test gives.</summary>
internal static class QuartzSupport
{
    /// <summary>A channel that keeps every alert it is sent.</summary>
    public sealed class Capture : IChannel
    {
        public ConcurrentQueue<Alert> Alerts { get; } = new();

        public string Name => "capture";

        public Task SendAsync(Alert alert, ChannelContext context, CancellationToken cancellationToken)
        {
            Alerts.Enqueue(alert);
            return Task.CompletedTask;
        }

        public List<string> Types() => Alerts.Select(a => a.Type.Value).ToList();
    }

    /// <summary>A test's client, what it sent, and what it reported.</summary>
    public sealed record Made(CronwatchClient Cw, IStore Store, Capture Alerts, ConcurrentQueue<string> Errors) : IAsyncDisposable
    {
        public ValueTask DisposeAsync() => Cw.DisposeAsync();
    }

    public static Made Client(IStore? store = null)
    {
        store ??= new MemoryStore();
        var capture = new Capture();
        var errors = new ConcurrentQueue<string>();
        var cw = new CronwatchClient(new CronwatchOptions
        {
            Store = store,
            Alerts = [capture],
            CronSecret = CronSecret.None,
            ProcessExitHook = false,
            OnError = (e, where) => errors.Enqueue(where + ": " + e.Message),
            OnWarning = _ => { },
        });
        return new Made(cw, store, capture, errors);
    }

    /// <summary>A scheduler of a name of its own, on the RAM store, built with <paramref name="configure"/>.</summary>
    public static async Task<IScheduler> BuildAsync(Action<IQuartzBuilder>? configure = null)
    {
        return await QuartzSchedulerBuilder.Create(q =>
        {
            q.ConfigureScheduler(o =>
            {
                o.InstanceName = "test-" + Guid.NewGuid().ToString("N");
                o.IdleWaitTime = TimeSpan.FromSeconds(1);
            });
            configure?.Invoke(q);
        }).BuildScheduler(default);
    }

    private static readonly ConcurrentDictionary<string, Func<IJobExecutionContext, ValueTask>> Behaviours = new(StringComparer.Ordinal);

    /// <summary>A job of <paramref name="key"/> that runs <paramref name="behaviour"/>.</summary>
    public static IJobDetail Job(JobKey key, Func<IJobExecutionContext, ValueTask> behaviour) =>
        JobBuilder.Create<DelegateJob>().WithIdentity(key).UsingJobData("behaviour", Behaviour(behaviour)).Build();

    /// <summary>The id a <see cref="DelegateJob"/>'s data names to run <paramref name="behaviour"/>.</summary>
    public static string Behaviour(Func<IJobExecutionContext, ValueTask> behaviour)
    {
        string id = Guid.NewGuid().ToString("N");
        Behaviours[id] = behaviour;
        return id;
    }

    public static IJobDetail Job(string name, Func<IJobExecutionContext, ValueTask> behaviour) => Job(new JobKey(name), behaviour);

    /// <summary>A trigger that fires once, now.</summary>
    public static ITrigger Once(string name) => TriggerBuilder.Create(TimeProvider.System).WithIdentity(name).ForJob(name).StartNow().Build();

    /// <summary>A cron trigger that fires far from now, for a job only declared.</summary>
    public static ITrigger Cron(string job, string trigger, string expression, TimeZoneInfo? zone = null) => Cron(new JobKey(job), trigger, expression, zone);

    public static ITrigger Cron(JobKey job, string trigger, string expression, TimeZoneInfo? zone = null) =>
        TriggerBuilder.Create(TimeProvider.System).WithIdentity(trigger).ForJob(job)
            .WithSchedule(CronScheduleBuilder.Create(expression).InTimeZone(zone ?? TimeZoneInfo.Utc)).Build();

    /// <summary>A job that runs the behaviour its data names.</summary>
    public sealed class DelegateJob : IJob
    {
        public ValueTask Execute(IJobExecutionContext context, CancellationToken cancellationToken) =>
            Behaviours[(string)context.MergedJobDataMap["behaviour"]!](context);
    }

    /// <summary>A job that does nothing, for jobs only declared.</summary>
    public sealed class NoopJob : IJob
    {
        public ValueTask Execute(IJobExecutionContext context, CancellationToken cancellationToken) => default;
    }

    /// <summary>
    /// Waits up to a minute for <paramref name="condition"/>, polling, and fails with
    /// <paramref name="what"/> if it never holds. A bound on an outcome, never on how long
    /// something took.
    /// </summary>
    public static async Task Eventually(string what, Func<Task<bool>> condition)
    {
        var deadline = DateTime.UtcNow + TimeSpan.FromSeconds(60);
        while (!await condition())
        {
            Assert.True(DateTime.UtcNow < deadline, "waited a minute for: " + what);
            await Task.Delay(20);
        }
    }

    public static Task Eventually(string what, Func<bool> condition) => Eventually(what, () => Task.FromResult(condition()));

    /// <summary>A job's runs, oldest first.</summary>
    public static async Task<List<Run>> Runs(CronwatchClient cw, string name)
    {
        var runs = (await cw.RunsAsync(name, 100)).ToList();
        runs.Reverse();
        return runs;
    }

    public static async Task<string?> Stored(IStore store, string name) => (await store.GetJobAsync(name))?.Definition.ToJson();
}
