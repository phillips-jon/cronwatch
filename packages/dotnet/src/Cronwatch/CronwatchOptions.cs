using System;
using System.Collections.Generic;
using System.Collections.ObjectModel;
using System.Diagnostics;
using System.Globalization;

namespace Cronwatch;

/// <summary>When alerts are sent.</summary>
public enum Deliver
{
    /// <summary>From the process that produced each alert (the default).</summary>
    Now,

    /// <summary>
    /// Queued in the job's state for the next check in a process that delivers now, for a
    /// process that should not send (a short job on a machine without the channels' network).
    /// </summary>
    AtCheck,
}

/// <summary>
/// The secret a job's handler requires (<c>Authorization: Bearer &lt;secret&gt;</c>): a string
/// converts implicitly, <see cref="None"/> lets anyone run it, and leaving the option unset reads
/// <c>CRON_SECRET</c>. Never printed.
/// </summary>
[DebuggerDisplay("CronSecret")]
public sealed class CronSecret
{
    private CronSecret(string? value)
    {
        Value = value;
    }

    /// <summary>No secret: anyone may run a job's handler.</summary>
    public static CronSecret None { get; } = new(null);

    internal string? Value { get; }

    /// <summary>A secret.</summary>
    public static implicit operator CronSecret(string secret) => new(secret ?? throw new ArgumentNullException(nameof(secret)));

    /// <summary>Says whether a secret is set, never its value.</summary>
    public override string ToString() => Value == null ? "CronSecret(none)" : "CronSecret(set)";
}

/// <summary>Redaction's opt-out.</summary>
public static class Redaction
{
    /// <summary>Stores output and errors as they are, with no secrets taken out.</summary>
    public static Func<string, string> None { get; } = static text => text;
}

/// <summary>
/// The client's options: the SDK's <c>CronWatchOptions</c>, checked when the client is made.
/// Nothing here is printed by <see cref="ToString"/> but what is set.
/// </summary>
[DebuggerDisplay("{ToString(),nq}")]
public sealed class CronwatchOptions
{
    private readonly ChannelList _alerts = new();

    /// <summary>Where jobs, runs and state live. Default: a <see cref="MemoryStore"/>, which forgets on restart.</summary>
    public IStore? Store { get; init; }

    /// <summary>
    /// Where alerts go. Default: the console. Add channels with a collection initializer
    /// (<c>Alerts = { SlackChannel.Webhook(url) }</c>); an empty list set explicitly sends nowhere.
    /// </summary>
    public IList<IChannel> Alerts
    {
        get => _alerts;
        init
        {
            ArgumentNullException.ThrowIfNull(value);
            _alerts.Clear();
            foreach (var c in value)
            {
                _alerts.Add(c);
            }
            _alerts.Touched = true;
        }
    }

    /// <summary>A diagnosis for each alert, or null for none.</summary>
    public ITriage? Triage { get; init; }

    /// <summary>
    /// The one POST every channel and triage make, unless one has a transport of its own. Default:
    /// an <see cref="Cronwatch.Alerts.HttpClientTransport"/> the client makes on its first send and
    /// disposes with itself.
    /// </summary>
    public Cronwatch.Alerts.ITransport? Transport { get; init; }

    /// <summary>Sources synced at the start of every check.</summary>
    public IList<ISource> Sources { get; init; } = new List<ISource>();

    /// <summary>
    /// The secret a job's handler requires: a string, <see cref="Cronwatch.CronSecret.None"/>, or
    /// unset to read <c>CRON_SECRET</c>.
    /// </summary>
    public CronSecret? CronSecret { internal get; init; }

    /// <summary>How long finished runs are kept. Default <c>"30d"</c>.</summary>
    public Duration Retention { get; init; } = "30d";

    /// <summary>Defaults for every job: only <c>Grace</c>, <c>Timeout</c>, <c>Timezone</c> and <c>FailuresBeforeAlert</c>.</summary>
    public JobOptions? Defaults { get; init; }

    /// <summary>
    /// Takes secrets out of output and errors before they are stored. Default: the SDK's patterns;
    /// <see cref="Redaction.None"/> turns it off. A throw falls back to the default.
    /// </summary>
    public Func<string, string>? Redact { get; init; }

    /// <summary>When alerts are sent. Default <see cref="Cronwatch.Deliver.Now"/>.</summary>
    public Deliver Deliver { get; init; } = Deliver.Now;

    /// <summary>
    /// Where the client's own failures go, with where they happened (<c>recording nightly</c>).
    /// Default: a line to standard error. It never stops a job.
    /// </summary>
    public Action<Exception, string>? OnError { get; init; }

    /// <summary>Where the client's warnings go (the in-memory store in production). Default: a line to standard error.</summary>
    public Action<string>? OnWarning { get; init; }

    /// <summary>
    /// The clock and every timer the client arms, and the zone a cron without one is read in.
    /// Default <see cref="TimeProvider.System"/>.
    /// </summary>
    public TimeProvider? Clock { get; init; }

    /// <summary>
    /// Whether runs still open when the process exits are recorded failed (within five seconds).
    /// Default true.
    /// </summary>
    public bool ProcessExitHook { get; init; } = true;

    /// <summary>
    /// The environment when neither <c>CRONWATCH_ENV</c> nor <c>APP_ENV</c> is set; it outranks
    /// .NET's <c>ASPNETCORE_ENVIRONMENT</c> and <c>DOTNET_ENVIRONMENT</c>, which are read, in that
    /// order, only without it. Under <c>AddCronwatch</c> it is <c>Cronwatch:Environment</c>, else
    /// the host's own environment.
    /// </summary>
    public string? Environment { get; init; }

    /// <summary>
    /// Called in the run's own flow as each run's function starts, with the run; what it answers
    /// is disposed when the function ends. <c>Cronwatch.Hosting</c> opens an <c>ILogger</c> scope
    /// here, so every line a job logs carries its name and run id. A throw is reported and the
    /// run goes on without it.
    /// </summary>
    public Func<JobContext, IDisposable?>? RunScope { get; init; }

    internal bool AlertsGiven => _alerts.Touched;

    internal Timings? TimingsOverride { get; init; }

    /// <summary>Names what is set, never a secret's value.</summary>
    public override string ToString() =>
        "CronwatchOptions(store " + (Store == null ? "memory" : Store.GetType().Name)
        + ", " + (AlertsGiven ? _alerts.Count.ToString(CultureInfo.InvariantCulture) : "default") + " channels"
        + ", cronSecret " + (CronSecret == null ? "from CRON_SECRET" : CronSecret.Value == null ? "none" : "set")
        + ", deliver " + Deliver + ")";

    private sealed class ChannelList : Collection<IChannel>
    {
        public bool Touched { get; set; }

        protected override void InsertItem(int index, IChannel item)
        {
            ArgumentNullException.ThrowIfNull(item);
            Touched = true;
            base.InsertItem(index, item);
        }

        protected override void SetItem(int index, IChannel item)
        {
            ArgumentNullException.ThrowIfNull(item);
            Touched = true;
            base.SetItem(index, item);
        }

        protected override void RemoveItem(int index)
        {
            Touched = true;
            base.RemoveItem(index);
        }

        protected override void ClearItems()
        {
            Touched = true;
            base.ClearItems();
        }
    }
}

/// <summary>How long the client waits on each thing; the tests shorten them.</summary>
internal sealed class Timings
{
    public TimeSpan Channel { get; set; } = TimeSpan.FromSeconds(15);

    public TimeSpan Triage { get; set; } = TimeSpan.FromSeconds(25);

    public TimeSpan RetryBudget { get; set; } = TimeSpan.FromSeconds(20);

    public TimeSpan CloseWait { get; set; } = TimeSpan.FromSeconds(5);

    public TimeSpan Shutdown { get; set; } = TimeSpan.FromSeconds(5);

    public TimeSpan FirstCheck { get; set; } = TimeSpan.FromSeconds(1);

    public TimeSpan MinInterval { get; set; } = TimeSpan.FromSeconds(5);

    /// <summary>The SDK's <c>now</c> option, for a seed whose clock goes where no <see cref="DateTimeOffset"/> can.</summary>
    public Func<long>? Now { get; set; }
}
