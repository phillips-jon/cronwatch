using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;
using Hangfire;
using Hangfire.InMemory;
using Xunit;

namespace Cronwatch.Hangfire.Tests;

/// <summary>A channel that keeps every alert it is sent.</summary>
internal sealed class Capture : IChannel
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

/// <summary>
/// A real Hangfire server on in-memory storage, a client on a memory store, and the integration
/// watching them, with what the client reported.
/// </summary>
internal sealed class Harness : IAsyncDisposable
{
    public Harness(string app = "billing", IStore? store = null, int workers = 2, bool start = true, CronwatchHangfireOptions? options = null)
    {
        Storage = new InMemoryStorage();
        JobStorage.Current = Storage;
        Store = store ?? new MemoryStore();
        Cw = new CronwatchClient(new CronwatchOptions
        {
            Store = Store,
            Alerts = [Alerts],
            ProcessExitHook = false,
            OnError = (e, where) => Errors.Enqueue(where + ": " + e.Message),
            OnWarning = _ => { },
        });
        Integration = CronwatchHangfire.Start(Cw, new CronwatchHangfireOptions
        {
            App = app,
            Storage = Storage,
            JobDefaults = options?.JobDefaults,
            Jobs = options?.Jobs ?? new Dictionary<string, JobOptions>(StringComparer.Ordinal),
            Named = options?.Named ?? new Dictionary<string, string>(StringComparer.Ordinal),
        });
        Client = new BackgroundJobClient(Storage);
        Recurring = new RecurringJobManager(Storage);
        Workers = workers;
        if (start)
        {
            StartServer();
        }
    }

    public InMemoryStorage Storage { get; }

    public IStore Store { get; }

    public CronwatchClient Cw { get; }

    public Capture Alerts { get; } = new();

    public ConcurrentQueue<string> Errors { get; } = new();

    public CronwatchHangfire Integration { get; }

    public BackgroundJobClient Client { get; }

    public RecurringJobManager Recurring { get; }

    public BackgroundJobServer? Server { get; private set; }

    private int Workers { get; }

    public void StartServer()
    {
        Server = new BackgroundJobServer(
            new BackgroundJobServerOptions
            {
                WorkerCount = Workers,
                SchedulePollingInterval = TimeSpan.FromMilliseconds(200),
                ShutdownTimeout = TimeSpan.FromSeconds(10),
                StopTimeout = TimeSpan.FromMilliseconds(500),
                ServerCheckInterval = TimeSpan.FromSeconds(1),
            },
            Storage);
    }

    public void StopServer()
    {
        Server?.Dispose();
        Server = null;
    }

    public async Task<IReadOnlyList<Run>> RunsAsync(string job) => await Cw.RunsAsync(job, 50);

    public async Task<string?> StoredAsync(string name) => (await Store.GetJobAsync(name))?.Definition.ToJson();

    public async ValueTask DisposeAsync()
    {
        StopServer();
        Integration.Dispose();
        await Cw.DisposeAsync();
        Storage.Dispose();
    }

    /// <summary>
    /// Waits up to a minute for <paramref name="condition"/>, polling, and fails with
    /// <paramref name="what"/> if it never holds: an outcome of a real server, never a bound on
    /// how long it took.
    /// </summary>
    public static async Task Eventually(string what, Func<Task<bool>> condition)
    {
        var deadline = DateTime.UtcNow + TimeSpan.FromMinutes(1);
        while (!await condition())
        {
            if (DateTime.UtcNow > deadline)
            {
                Assert.Fail("waited a minute for: " + what);
            }
            await Task.Delay(50);
        }
    }
}
