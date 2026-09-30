using System;
using System.Collections.Generic;
using System.Diagnostics;
using Cronwatch.Web;

namespace Cronwatch.Hosting;

/// <summary>
/// The client's options as <c>AddCronwatch</c> takes them: <see cref="CronwatchOptions"/>'s, set
/// in a callback, over what the <c>Cronwatch</c> section of the app's configuration says
/// (<c>Retention</c>, <c>Token</c>, <c>CheckEvery</c>, <c>Environment</c>), with what the host
/// gives besides: the app's <c>ILogger</c> for errors and warnings, the host's environment, and
/// every <see cref="IChannel"/> in the container as a channel. <see cref="ToString"/> never shows
/// a secret.
/// </summary>
[DebuggerDisplay("{ToString(),nq}")]
public sealed class CronwatchHostOptions
{
    private readonly List<IChannel> _alerts = [];
    private readonly List<ISource> _sources = [];

    /// <summary>Where jobs, runs and state live. Default: a <see cref="MemoryStore"/>.</summary>
    public IStore? Store { get; set; }

    /// <summary>
    /// Where alerts go. Default: every <see cref="IChannel"/> registered in the container, else the
    /// console. Once one is added here, these are the channels.
    /// </summary>
    public IList<IChannel> Alerts => _alerts;

    /// <summary>A diagnosis for each alert, or null for none.</summary>
    public ITriage? Triage { get; set; }

    /// <summary>Sources synced at the start of every check.</summary>
    public IList<ISource> Sources => _sources;

    /// <summary>The secret a job's handler requires; unset reads <c>CRON_SECRET</c>.</summary>
    public CronSecret? CronSecret { internal get; set; }

    /// <summary>How long finished runs are kept. Default: <c>Cronwatch:Retention</c>, else <c>"30d"</c>.</summary>
    public Duration? Retention { get; set; }

    /// <summary>Defaults for every job: only <c>Grace</c>, <c>Timeout</c>, <c>Timezone</c> and <c>FailuresBeforeAlert</c>.</summary>
    public JobOptions? Defaults { get; set; }

    /// <summary>Takes secrets out of output and errors before they are stored (see <see cref="CronwatchOptions.Redact"/>).</summary>
    public Func<string, string>? Redact { get; set; }

    /// <summary>When alerts are sent. Default <see cref="Cronwatch.Deliver.Now"/>.</summary>
    public Deliver Deliver { get; set; } = Deliver.Now;

    /// <summary>Where the client's own failures go. Default: the app's <c>ILogger</c>, at <c>Error</c>.</summary>
    public Action<Exception, string>? OnError { get; set; }

    /// <summary>Where the client's warnings go. Default: the app's <c>ILogger</c>, at <c>Warning</c>.</summary>
    public Action<string>? OnWarning { get; set; }

    /// <summary>The clock. Default: a <see cref="TimeProvider"/> in the container, else the system's.</summary>
    public TimeProvider? Clock { get; set; }

    /// <summary>Whether runs still open when the process exits are recorded failed. Default true.</summary>
    public bool ProcessExitHook { get; set; } = true;

    /// <summary>
    /// The environment when none of CronWatch's variables is set. Default:
    /// <c>Cronwatch:Environment</c>, else the host's environment name.
    /// </summary>
    public string? Environment { get; set; }

    /// <summary>
    /// How often the hosted check runs, from when the host has started. Default:
    /// <c>Cronwatch:CheckEvery</c>, else a minute. <see cref="NoCheck"/> runs none, for an app
    /// whose checks run in another process.
    /// </summary>
    public Duration? CheckEvery { get; set; }

    /// <summary>Runs no hosted check.</summary>
    public bool NoCheck { get; set; }

    /// <summary>
    /// The dashboard's token for <c>MapCronwatch</c> and <c>UseCronwatch</c> when they are given no
    /// options of their own. Default: <c>Cronwatch:Token</c>, else <c>CRONWATCH_TOKEN</c>.
    /// </summary>
    public DashboardToken? Token { internal get; set; }

    internal bool AlertsGiven => _alerts.Count > 0;

    /// <summary>Names what is set, never a secret's value.</summary>
    public override string ToString() =>
        "CronwatchHostOptions(store " + (Store == null ? "memory" : Store.GetType().Name)
        + ", " + (AlertsGiven ? _alerts.Count + " channels" : "channels from the container")
        + ", cronSecret " + (CronSecret == null ? "from CRON_SECRET" : CronSecret.ToString())
        + ", token " + (Token == null ? "from configuration" : Token.ToString())
        + (NoCheck ? ", no check" : "") + ")";
}
