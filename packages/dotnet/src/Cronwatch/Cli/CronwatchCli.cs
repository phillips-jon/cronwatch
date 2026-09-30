using System;
using System.Collections.Generic;
using System.IO;
using System.Threading;
using System.Threading.Tasks;
using Cronwatch.Internal;

namespace Cronwatch;

/// <summary>
/// A check from a crontab line: the second of the two lines a plain crontab runs, beside the job
/// itself. The check needs the same store and channels as the job, which only the app knows, so
/// this is called from the app's own program with the app's factory for its client:
/// <code>
/// if (args is ["cronwatch", .. var rest])
/// {
///     return await CronwatchCli.RunAsync(MakeClient, rest, Console.Out, Console.Error);
/// }
/// </code>
/// and the crontab line is <c>dotnet /app/MyApp.dll cronwatch check</c>. <c>check</c> makes the
/// client, runs one check, prints <c>cronwatch: checked 3 jobs, sent 1 alert</c> (or the failure,
/// to standard error), and disposes the client. It never ends the process: the caller returns the
/// status from <c>Main</c>.
/// </summary>
public static class CronwatchCli
{
    private const string Usage = "usage: cronwatch check\n\n  check    run one check: missed and stuck runs, retries, pruning\n";

    /// <summary>
    /// Runs the command in <paramref name="args"/> and answers its exit status (0, 1 for a failed
    /// check or a factory that throws, 2 for a command it does not know), printing to
    /// <paramref name="stdout"/> and <paramref name="stderr"/>. <paramref name="factory"/> is called
    /// for a client, which is disposed at the end.
    /// </summary>
    public static async Task<int> RunAsync(Func<CronwatchClient> factory, IReadOnlyList<string> args, TextWriter stdout, TextWriter stderr, CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(factory);
        ArgumentNullException.ThrowIfNull(args);
        ArgumentNullException.ThrowIfNull(stdout);
        ArgumentNullException.ThrowIfNull(stderr);
        if (args.Count == 1 && (args[0] == "help" || args[0] == "--help"))
        {
            await stdout.WriteAsync(Usage.AsMemory(), cancellationToken).ConfigureAwait(false);
            return 0;
        }
        if (args.Count != 1 || args[0] != "check")
        {
            string first = args.Count == 0 ? "cronwatch: no command given\n" : "cronwatch: unknown command " + string.Join(" ", args) + "\n";
            await stderr.WriteAsync((first + Usage).AsMemory(), cancellationToken).ConfigureAwait(false);
            return 2;
        }
        CronwatchClient cw;
        try
        {
            cw = factory() ?? throw new InvalidOperationException("the factory answered null");
        }
        catch (Exception e)
        {
            await stderr.WriteAsync(("cronwatch: the client could not be made: " + Describe(e) + "\n").AsMemory(), cancellationToken).ConfigureAwait(false);
            return 1;
        }
        await using (cw.ConfigureAwait(false))
        {
            CheckResult result;
            try
            {
                result = await cw.CheckAsync(cancellationToken).ConfigureAwait(false);
            }
            catch (Exception e)
            {
                await stderr.WriteAsync(("cronwatch: the check failed: " + Describe(e) + "\n").AsMemory(), CancellationToken.None).ConfigureAwait(false);
                return 1;
            }
            int jobs = result.Jobs.Count;
            int alerts = result.Alerts.Count;
            await stdout.WriteAsync(
                ("cronwatch: checked " + Js.FormatLong(jobs) + " job" + Plural(jobs) + ", sent " + Js.FormatLong(alerts) + " alert" + Plural(alerts) + "\n").AsMemory(),
                CancellationToken.None).ConfigureAwait(false);
            return 0;
        }
    }

    private static string Plural(int n) => n == 1 ? "" : "s";

    private static string Describe(Exception e) => string.IsNullOrEmpty(e.Message) ? OutputText.ErrorName(e) : e.Message;
}
