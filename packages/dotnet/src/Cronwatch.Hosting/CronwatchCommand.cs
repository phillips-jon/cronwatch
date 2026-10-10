using System;
using System.IO;
using System.Threading;
using System.Threading.Tasks;
using Cronwatch;
using Microsoft.Extensions.DependencyInjection;

namespace Microsoft.Extensions.Hosting;

/// <summary><c>cronwatch check</c> from the app's own command line.</summary>
public static class CronwatchHostExtensions
{
    /// <summary>
    /// Given <c>cronwatch check</c> (<paramref name="args"/> starting with <c>cronwatch</c>),
    /// takes the client from the host's container without starting the host, so no web server,
    /// queue, or hosted job starts, runs one check, prints what it found, and answers the exit
    /// status (0, 1 for a failed check or a client the container cannot make, 2 for a command it
    /// does not know); given anything else, runs the host as <c>RunAsync</c> would and answers 0.
    /// It never ends the process, so <c>Main</c> returns the status:
    /// <code>return await app.RunCronwatchCommandAsync(args);</code>
    /// and a crontab line is <c>dotnet /app/MyApp.dll cronwatch check</c>.
    /// </summary>
    public static Task<int> RunCronwatchCommandAsync(this IHost host, string[] args, CancellationToken cancellationToken = default) =>
        RunCronwatchCommandAsync(host, args, Console.Out, Console.Error, cancellationToken);

    /// <summary>As <see cref="RunCronwatchCommandAsync(IHost, string[], CancellationToken)"/>, printing to the writers given.</summary>
    public static async Task<int> RunCronwatchCommandAsync(this IHost host, string[] args, TextWriter stdout, TextWriter stderr, CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(host);
        ArgumentNullException.ThrowIfNull(args);
        if (args.Length == 0 || args[0] != "cronwatch")
        {
            await host.RunAsync(cancellationToken).ConfigureAwait(false);
            return 0;
        }
        try
        {
            return await CronwatchCli.RunAsync(
                () => host.Services.GetRequiredService<CronwatchClient>(),
                args[1..],
                stdout,
                stderr,
                cancellationToken).ConfigureAwait(false);
        }
        finally
        {
            if (host is IAsyncDisposable ad)
            {
                await ad.DisposeAsync().ConfigureAwait(false);
            }
            else
            {
                host.Dispose();
            }
        }
    }
}
