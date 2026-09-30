using System.Collections.Generic;

namespace Cronwatch.Internal;

/// <summary>
/// A job's state being worked out: the fields of a <see cref="JobState"/>, open to change, as the
/// SDK's functions change a cloned state object. Used by one thread at a time.
/// </summary>
internal sealed class MutableState
{
    public string Job;
    public readonly OrderedDictionary<Condition, long> Open;
    public long ConsecutiveFailures;
    public long? SilencedUntil;
    public long? LastAlertAt;
    public List<Condition>? PendingRecovery;
    public List<Alert>? Undelivered;
    public List<SendingAlert>? Sending;
    public long? Version;
    public readonly JsObject Extra;

    private MutableState(JobState s)
    {
        Job = s.Job;
        Open = new OrderedDictionary<Condition, long>();
        foreach (var e in s.Open)
        {
            Open[e.Key] = e.Value;
        }
        ConsecutiveFailures = Evaluate.FailureCount(s.ConsecutiveFailures);
        SilencedUntil = s.SilencedUntil;
        LastAlertAt = s.LastAlertAt;
        PendingRecovery = s.PendingRecovery == null ? null : [.. s.PendingRecovery];
        Undelivered = s.Undelivered == null ? null : [.. s.Undelivered];
        Sending = s.Sending == null ? null : [.. s.Sending];
        Version = s.Version;
        Extra = s.Extra;
    }

    /// <summary>A changeable copy of the state.</summary>
    public static MutableState Of(JobState s) => new(s);

    /// <summary>The pending recoveries, made present.</summary>
    public List<Condition> Pending() => PendingRecovery ??= [];

    /// <summary>The queued alerts, made present.</summary>
    public List<Alert> Queued() => Undelivered ??= [];

    /// <summary>The state as it now stands.</summary>
    public JobState ToState() => new()
    {
        Job = Job,
        Open = ValueMap<Condition, long>.Of(Open),
        ConsecutiveFailures = ConsecutiveFailures,
        SilencedUntil = SilencedUntil,
        LastAlertAt = LastAlertAt,
        PendingRecovery = PendingRecovery == null ? null : ValueList<Condition>.Of(PendingRecovery),
        Undelivered = Undelivered == null ? null : ValueList<Alert>.Of(Undelivered),
        // Absent when empty: the key is there only while it holds an alert.
        Sending = Sending is { Count: > 0 } ? ValueList<SendingAlert>.Of(Sending) : null,
        Version = Version,
        Extra = Extra,
    };
}
