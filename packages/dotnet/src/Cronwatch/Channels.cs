using System;
using System.Collections.Generic;
using System.Threading;
using System.Threading.Tasks;

namespace Cronwatch;

/// <summary>
/// Where alerts go: the SDK's <c>AlertChannel</c>. A send that throws is that channel's failure
/// only, reported to the client's error handler; the alert is queued for the next check when no
/// channel accepted it.
/// </summary>
/// <remarks>
/// Each send is given 15 seconds, after which its token is cancelled. A channel that ignores its
/// token keeps its task until it returns, harmlessly.
/// </remarks>
public interface IChannel
{
    /// <summary>The channel's name, as the error handler reports it.</summary>
    string Name { get; }

    /// <summary>Sends the alert; completes once it went out (to at least one recipient), throws when it went nowhere.</summary>
    Task SendAsync(Alert alert, ChannelContext context, CancellationToken cancellationToken);
}

/// <summary>What the client hands a channel with each alert.</summary>
public sealed class ChannelContext
{
    private readonly Action<Exception> _report;

    /// <summary>A context reporting to <paramref name="report"/>.</summary>
    public ChannelContext(Action<Exception> report)
    {
        _report = report ?? throw new ArgumentNullException(nameof(report));
    }

    /// <summary>
    /// Reports a problem that did not stop the alert going out, such as one of several recipients
    /// refusing it. Goes to the client's error handler.
    /// </summary>
    public void ReportError(Exception error) => _report(error);

    /// <summary>Reports a problem, as a message.</summary>
    public void ReportError(string message) => _report(new CronwatchException(message));

    /// <summary>Names the type only.</summary>
    public override string ToString() => "ChannelContext";
}

/// <summary>Channels made from functions.</summary>
public static class Channel
{
    /// <summary>A channel named <paramref name="name"/> that sends with <paramref name="send"/>: the SDK's <c>custom()</c>.</summary>
    public static IChannel Create(string name, Func<Alert, ChannelContext, CancellationToken, Task> send) =>
        new FunctionChannel(name ?? throw new ArgumentNullException(nameof(name)), send ?? throw new ArgumentNullException(nameof(send)));

    private sealed class FunctionChannel(string name, Func<Alert, ChannelContext, CancellationToken, Task> send) : IChannel
    {
        public string Name => name;

        public Task SendAsync(Alert alert, ChannelContext context, CancellationToken cancellationToken) => send(alert, context, cancellationToken);

        public override string ToString() => "Channel(" + name + ")";
    }
}

/// <summary>
/// The default channel: the SDK's <c>consoleChannel()</c>. A recovery is written to standard
/// output and anything else to standard error, where <c>console.info</c> and
/// <c>console.error</c> write, each ending <c>\n</c> on every system.
/// </summary>
public sealed class ConsoleChannel : IChannel
{
    /// <inheritdoc/>
    public string Name => "console";

    /// <inheritdoc/>
    public async Task SendAsync(Alert alert, ChannelContext context, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(alert);
        string line = "[cronwatch] " + alert.Title + "\n" + alert.Message + (string.IsNullOrEmpty(alert.Triage) ? "" : "\nTriage: " + alert.Triage);
        var output = alert.Type == AlertType.Recovered ? Console.Out : Console.Error;
        await output.WriteAsync((line + "\n").AsMemory(), cancellationToken).ConfigureAwait(false);
        await output.FlushAsync(cancellationToken).ConfigureAwait(false);
    }

    /// <summary>Names the channel.</summary>
    public override string ToString() => "ConsoleChannel";
}

/// <summary>What triage is given: the alert and the job's recent runs.</summary>
/// <param name="Alert">The alert to diagnose.</param>
/// <param name="RecentRuns">The job's newest runs, newest first.</param>
public sealed record TriageContext(Alert Alert, IReadOnlyList<Run> RecentRuns);

/// <summary>
/// A short diagnosis added to each alert but recoveries: the SDK's <c>triage</c>. Tried once per
/// alert, within 25 seconds, after which its token is cancelled; a throw or an empty answer gives
/// none.
/// </summary>
public interface ITriage
{
    /// <summary>The diagnosis, or null for none.</summary>
    Task<string?> TriageAsync(TriageContext context, CancellationToken cancellationToken);
}

/// <summary>
/// Something that learns of runs from outside the app's own code (the pg_cron source), synced at
/// the start of every check: the SDK's <c>sources</c>.
/// </summary>
public interface ISource
{
    /// <summary>The source's name, as the error handler reports it.</summary>
    string Name { get; }

    /// <summary>Declares jobs and records runs through the client, answering any alerts that raised.</summary>
    Task<IReadOnlyList<Alert>?> SyncAsync(CronwatchClient client, CancellationToken cancellationToken);
}
