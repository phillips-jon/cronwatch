using System;
using System.Threading;
using System.Threading.Tasks;
using Microsoft.Extensions.Hosting;

namespace Cronwatch.Hosting;

/// <summary>
/// The check as a hosted service: the SDK's <c>startChecking()</c>, begun once the host has started (so
/// no check runs while the app is still starting) and stopped when it stops, before the container
/// disposes the client.
/// </summary>
internal sealed class CronwatchCheckService(CronwatchClient client, CronwatchHostOptions options, IHostApplicationLifetime? lifetime = null) : IHostedService, IDisposable
{
    private CancellationTokenRegistration _started;

    public Task StartAsync(CancellationToken cancellationToken)
    {
        if (options.NoCheck)
        {
            return Task.CompletedTask;
        }
        Duration every = options.CheckEvery ?? TimeSpan.FromMinutes(1);
        // Read now, so a bad interval stops the host: one thrown from the started callback below
        // is only logged, and the app would run on with no checks at all.
        _ = every.ToMilliseconds("check interval");
        if (lifetime == null)
        {
            client.StartChecking(every);
        }
        else
        {
            _started = lifetime.ApplicationStarted.Register(() => client.StartChecking(every));
        }
        return Task.CompletedTask;
    }

    public async Task StopAsync(CancellationToken cancellationToken)
    {
        await _started.DisposeAsync().ConfigureAwait(false);
        client.Stop();
    }

    public void Dispose() => _started.Dispose();
}
