using System;
using System.Collections.Concurrent;
using System.IO;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Hosting;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Time.Testing;
using Xunit;

namespace Cronwatch.Hosting.Tests;

/// <summary><c>AddCronwatchJob</c> and <c>RunCronwatchCommandAsync</c>, on a fake clock in a real Generic Host.</summary>
public class HostedJobTests
{
    /// <summary>Monday 2026-01-05 09:30:00 UTC.</summary>
    private static readonly DateTimeOffset T0 = new(2026, 1, 5, 9, 30, 0, TimeSpan.Zero);

    private static FakeTimeProvider Clock()
    {
        var clock = new FakeTimeProvider(T0);
        clock.SetLocalTimeZone(TimeZoneInfo.Utc);
        return clock;
    }

    private static CronwatchClient Client(FakeTimeProvider clock, IStore? store = null) => new(new CronwatchOptions
    {
        Store = store ?? new MemoryStore(),
        Clock = clock,
        Alerts = [],
        ProcessExitHook = false,
        OnWarning = _ => { },
    });

    /// <summary>Waits up to thirty seconds for an outcome on the host's own tasks; never a bound on how long something took.</summary>
    private static async Task Eventually(string what, Func<Task<bool>> condition)
    {
        var deadline = DateTime.UtcNow + TimeSpan.FromSeconds(30);
        while (!await condition())
        {
            Assert.True(DateTime.UtcNow < deadline, "waited thirty seconds for: " + what);
            await Task.Delay(10);
        }
    }

    /// <summary>A started host with the client, the jobs a test adds, and every log line kept.</summary>
    private sealed class Made : IAsyncDisposable
    {
        public required IHost Host { get; init; }

        public required CronwatchClient Cw { get; init; }

        public required FakeTimeProvider Clock { get; init; }

        public required ConcurrentQueue<string> Logs { get; init; }

        public required HostedJobs Jobs { get; init; }

        /// <summary>Waits until no run is under way, so the next fire is not skipped.</summary>
        public Task IdleAsync() => Eventually("the runs to end", () => Task.FromResult(Jobs.Running == 0));

        /// <summary>Each job's next fire, as its loop starts waiting for it.</summary>
        public ConcurrentQueue<(string Job, long Fire)> Waits { get; } = new();

        /// <summary>Waits until the job's loop waits for <paramref name="fire"/>, then moves the clock there.</summary>
        public async Task FireAsync(string job, DateTimeOffset fire)
        {
            long ms = fire.ToUnixTimeMilliseconds();
            await Eventually("the loop to wait for " + fire, () => Task.FromResult(Waits.Any(w => w.Job == job && w.Fire == ms)));
            Clock.SetUtcNow(fire);
        }

        public async ValueTask DisposeAsync()
        {
            await Host.StopAsync();
            Host.Dispose();
            await Cw.DisposeAsync();
        }
    }

    private static async Task<Made> StartAsync(Action<IServiceCollection> configure)
    {
        var clock = Clock();
        var cw = Client(clock);
        var logs = new ConcurrentQueue<string>();
        var builder = Host.CreateApplicationBuilder();
        builder.Logging.ClearProviders();
        builder.Logging.AddProvider(new CaptureLogs(logs));
        builder.Services.AddSingleton(cw);
        configure(builder.Services);
        IHost host = builder.Build();
        HostedJobs jobs = host.Services.GetServices<IHostedService>().OfType<HostedJobs>().Single();
        var made = new Made { Host = host, Cw = cw, Clock = clock, Logs = logs, Jobs = jobs };
        jobs.Waiting = (job, fire) => made.Waits.Enqueue((job, fire));
        await host.StartAsync();
        return made;
    }

    private static async Task<Run[]> Runs(CronwatchClient cw, string job) => [.. await cw.RunsAsync(job, 50)];

    /// <summary>A job that counts its runs and the scopes it was resolved from.</summary>
    internal sealed class Counting(Counting.Scoped scoped) : ICronwatchJob
    {
        public static int Runs;

        public Task RunAsync(JobContext job, CancellationToken cancellationToken)
        {
            Interlocked.Increment(ref Runs);
            Assert.Same(job, CronwatchClient.Current);
            job.Log("run " + scoped.Id);
            return Task.CompletedTask;
        }

        internal sealed class Scoped : IDisposable
        {
            public static int Disposed;

            public Guid Id { get; } = Guid.NewGuid();

            public void Dispose() => Interlocked.Increment(ref Disposed);
        }
    }

    [Fact]
    public async Task A_hosted_job_runs_at_its_crons_fire_times_in_a_scope_of_its_own()
    {
        await using var m = await StartAsync(s =>
        {
            s.AddScoped<Counting.Scoped>();
            s.AddCronwatchJob<Counting>("counting", new JobOptions { Schedule = "*/5 * * * *", Timezone = "UTC" });
        });
        int disposedBefore = Counting.Scoped.Disposed;
        await m.FireAsync("counting", T0.AddMinutes(5));
        await Eventually("the first run", async () => (await Runs(m.Cw, "counting")).Length == 1 && (await Runs(m.Cw, "counting"))[0].Status == RunStatus.Ok);
        await m.IdleAsync();
        await m.FireAsync("counting", T0.AddMinutes(10));
        await Eventually("the second run", async () => (await Runs(m.Cw, "counting")).Count(r => r.Status == RunStatus.Ok) == 2);
        Run[] runs = await Runs(m.Cw, "counting");
        Assert.All(runs, r => Assert.Equal("hosting", r.Trigger));
        Assert.NotEqual(runs[0].Output, runs[1].Output);
        await Eventually("both scopes disposed", () => Task.FromResult(Counting.Scoped.Disposed - disposedBefore >= 2));
        Assert.Equal("*/5 * * * *", m.Cw.DefinedJobs.Single(d => d.Name == "counting").Schedule);
    }

    /// <summary>A job that waits at a gate the test opens.</summary>
    internal sealed class Gated : ICronwatchJob
    {
        public static readonly ConcurrentQueue<TaskCompletionSource> Gates = new();

        public async Task RunAsync(JobContext job, CancellationToken cancellationToken)
        {
            var gate = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
            Gates.Enqueue(gate);
            await gate.Task.WaitAsync(cancellationToken);
        }
    }

    [Fact]
    public async Task A_fire_while_the_job_is_still_running_is_skipped_and_logged_once()
    {
        while (Gated.Gates.TryDequeue(out _))
        {
        }
        await using var m = await StartAsync(s => s.AddCronwatchJob<Gated>("gated", new JobOptions { Schedule = "* * * * *" }));
        await m.FireAsync("gated", T0.AddMinutes(1));
        await Eventually("the run to start", () => Task.FromResult(!Gated.Gates.IsEmpty));
        await m.FireAsync("gated", T0.AddMinutes(2));
        await m.FireAsync("gated", T0.AddMinutes(3));
        // The loop waits for the fire after those two only once it has passed them.
        await Eventually("the loop past the skipped fires", () => Task.FromResult(m.Waits.Any(w => w.Fire == T0.AddMinutes(4).ToUnixTimeMilliseconds())));
        Assert.Single(m.Logs, l => l.Contains("gated is still running", StringComparison.Ordinal));
        Assert.Single(await Runs(m.Cw, "gated"));
        Assert.True(Gated.Gates.TryDequeue(out var gate));
        gate.SetResult();
        await Eventually("the run recorded", async () => (await Runs(m.Cw, "gated"))[0].Status == RunStatus.Ok);
        await m.IdleAsync();
        await m.FireAsync("gated", T0.AddMinutes(4));
        await Eventually("the next fire runs again", async () => (await Runs(m.Cw, "gated")).Length == 2);
        Assert.True(Gated.Gates.TryDequeue(out gate));
        gate.SetResult();
    }

    /// <summary>A job that throws.</summary>
    internal sealed class Throwing : ICronwatchJob
    {
        public Task RunAsync(JobContext job, CancellationToken cancellationToken) => throw new InvalidOperationException("the report failed");
    }

    [Fact]
    public async Task A_throw_is_a_failed_run_and_the_next_fire_still_runs()
    {
        await using var m = await StartAsync(s => s.AddCronwatchJob<Throwing>("throwing", new JobOptions { Schedule = "every 10m" }));
        await m.FireAsync("throwing", T0.AddMinutes(10));
        await Eventually("the failed run", async () => (await Runs(m.Cw, "throwing")) is [{ Status.Value: "failed" }]);
        Assert.StartsWith("InvalidOperationException: the report failed", (await Runs(m.Cw, "throwing"))[0].Error, StringComparison.Ordinal);
        // An interval counts from the last fire.
        await m.IdleAsync();
        await m.FireAsync("throwing", T0.AddMinutes(20));
        await Eventually("the second run", async () => (await Runs(m.Cw, "throwing")).Length == 2);
    }

    [Fact]
    public async Task Stopping_the_host_cancels_a_running_job_and_records_it()
    {
        while (Gated.Gates.TryDequeue(out _))
        {
        }
        var m = await StartAsync(s => s.AddCronwatchJob<Gated>("stopped", new JobOptions { Schedule = "* * * * *" }));
        try
        {
            await m.FireAsync("stopped", T0.AddMinutes(1));
            await Eventually("the run to start", () => Task.FromResult(!Gated.Gates.IsEmpty));
            await m.Host.StopAsync();
            // The recording is the client's own task, which the stop does not cut.
            await Eventually("the run recorded", async () => (await Runs(m.Cw, "stopped")).Single().Status != RunStatus.Running);
            Run run = (await Runs(m.Cw, "stopped")).Single();
            Assert.Equal(RunStatus.Failed, run.Status);
            Assert.Contains("canceled", run.Error, StringComparison.Ordinal);
        }
        finally
        {
            m.Host.Dispose();
            await m.Cw.DisposeAsync();
        }
    }

    /// <summary>A job that notes what the flow that started the host left in <see cref="Ambient"/>.</summary>
    internal sealed class Looking : ICronwatchJob
    {
        public static readonly AsyncLocal<string?> Ambient = new();

        public static readonly ConcurrentQueue<string> Seen = new();

        public Task RunAsync(JobContext job, CancellationToken cancellationToken)
        {
            Seen.Enqueue(Ambient.Value ?? "none");
            return Task.CompletedTask;
        }
    }

    [Fact]
    public async Task A_hosted_job_carries_nothing_from_the_flow_that_started_the_host()
    {
        Looking.Seen.Clear();
        Made m;
        // What the host's start had in its flow (a log scope, an activity) must not reach every
        // run for the life of the app.
        Looking.Ambient.Value = "the host's start";
        try
        {
            m = await StartAsync(s => s.AddCronwatchJob<Looking>("looking", new JobOptions { Schedule = "* * * * *" }));
        }
        finally
        {
            Looking.Ambient.Value = null;
        }
        await using (m)
        {
            await m.FireAsync("looking", T0.AddMinutes(1));
            await Eventually("the run", () => Task.FromResult(!Looking.Seen.IsEmpty));
            Assert.Equal(["none"], Looking.Seen);
        }
    }

    [Fact]
    public async Task A_bad_schedule_stops_the_host_from_starting()
    {
        var builder = Host.CreateApplicationBuilder();
        builder.Logging.ClearProviders();
        await using var cw = Client(Clock());
        builder.Services.AddSingleton(cw);
        builder.Services.AddCronwatchJob<Throwing>("bad", new JobOptions { Schedule = "61 * * * *" });
        using IHost host = builder.Build();
        var e = await Assert.ThrowsAsync<CronwatchException>(() => host.StartAsync());
        Assert.Contains("schedule \"61 * * * *\"", e.Message, StringComparison.Ordinal);
        Assert.Throws<ArgumentException>(() => new ServiceCollection().AddCronwatchJob<Throwing>("none", new JobOptions()));
    }

    /// <summary>A hosted service that notes whether it was started.</summary>
    internal sealed class Noting : IHostedService
    {
        public static int Started;

        public Task StartAsync(CancellationToken cancellationToken)
        {
            Interlocked.Increment(ref Started);
            return Task.CompletedTask;
        }

        public Task StopAsync(CancellationToken cancellationToken) => Task.CompletedTask;
    }

    [Fact]
    public async Task The_command_checks_from_the_container_without_starting_the_host()
    {
        var store = new MemoryStore();
        await using (var earlier = Client(Clock(), store))
        {
            await earlier.Job("nightly", new JobOptions { Schedule = "0 2 * * *" }).RunAsync((ctx, ct) => Task.CompletedTask);
        }
        IHost Build(bool withClient)
        {
            var builder = Host.CreateApplicationBuilder();
            builder.Logging.ClearProviders();
            if (withClient)
            {
                builder.Services.AddSingleton(_ => Client(Clock(), store));
            }
            builder.Services.AddHostedService<Noting>();
            return builder.Build();
        }
        int startedBefore = Noting.Started;
        var output = new StringWriter();
        var error = new StringWriter();
        Assert.Equal(0, await Build(true).RunCronwatchCommandAsync(["cronwatch", "check"], output, error));
        Assert.Equal("cronwatch: checked 1 job, sent 0 alerts\n", output.ToString());
        Assert.Equal("", error.ToString());
        Assert.Equal(2, await Build(true).RunCronwatchCommandAsync(["cronwatch", "chek"], output, error));
        Assert.StartsWith("cronwatch: unknown command chek\n", error.ToString(), StringComparison.Ordinal);
        error = new StringWriter();
        Assert.Equal(1, await Build(false).RunCronwatchCommandAsync(["cronwatch", "check"], output, error));
        Assert.StartsWith("cronwatch: the client could not be made: ", error.ToString(), StringComparison.Ordinal);
        Assert.Equal(startedBefore, Noting.Started);

        // Anything else runs the host.
        using var stop = new CancellationTokenSource();
        IHost host = Build(true);
        Task<int> running = host.RunCronwatchCommandAsync(["serve"], output, error, stop.Token);
        await Eventually("the host to start", () => Task.FromResult(Noting.Started > startedBefore));
        await stop.CancelAsync();
        Assert.Equal(0, await running);
    }

    [Fact]
    public async Task A_runs_log_lines_carry_its_job_and_run_in_a_scope()
    {
        var lines = new ConcurrentQueue<string>();
        var builder = Host.CreateApplicationBuilder();
        builder.Logging.ClearProviders();
        builder.Logging.AddProvider(new CaptureLogs(lines));
        builder.Services.AddCronwatch(o =>
        {
            o.Clock = Clock();
            o.ProcessExitHook = false;
            o.NoCheck = true;
            o.OnWarning = _ => { };
        });
        using IHost host = builder.Build();
        var cw = host.Services.GetRequiredService<CronwatchClient>();
        var log = host.Services.GetRequiredService<ILogger<HostedJobTests>>();
        string? runId = null;
        await cw.Job("scoped").RunAsync((job, ct) =>
        {
            runId = job.RunId;
            log.LogInformation("inside");
            return Task.CompletedTask;
        });
        log.LogInformation("outside");
        Assert.Contains("[cronwatch_job=scoped cronwatch_run=" + runId + "] inside", lines);
        Assert.Contains("[] outside", lines);
    }

    private sealed class CaptureLogs(ConcurrentQueue<string> lines) : ILoggerProvider
    {
        public ILogger CreateLogger(string categoryName) => new Logger(lines);

        public void Dispose()
        {
        }

        /// <summary>Writes each line after the scopes open in its flow: <c>[scope] line</c>.</summary>
        private sealed class Logger(ConcurrentQueue<string> lines) : ILogger
        {
            private static readonly AsyncLocal<string?> Scope = new();

            public IDisposable? BeginScope<TState>(TState state)
                where TState : notnull
            {
                string? previous = Scope.Value;
                Scope.Value = state.ToString();
                return new Restore(() => Scope.Value = previous);
            }

            public bool IsEnabled(LogLevel logLevel) => true;

            public void Log<TState>(LogLevel logLevel, EventId eventId, TState state, Exception? exception, Func<TState, Exception?, string> formatter) =>
                lines.Enqueue("[" + Scope.Value + "] " + formatter(state, exception));
        }

        private sealed class Restore(Action restore) : IDisposable
        {
            public void Dispose() => restore();
        }
    }
}
