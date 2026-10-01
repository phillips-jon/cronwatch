using System;
using System.Collections.Generic;
using Cronwatch.Internal;

namespace Cronwatch;

/// <summary>
/// A job's alerting state, as stored: the SDK's <c>JobState</c>. Keys a newer writer added are
/// kept in <see cref="Extra"/>, in their places, and written back.
/// </summary>
public sealed record JobState
{
    private static readonly HashSet<string> KnownKeys = new(StringComparer.Ordinal)
    {
        "job", "open", "consecutiveFailures", "silencedUntil", "lastAlertAt", "pendingRecovery", "undelivered", "sending",
    };

    /// <summary>The job's name.</summary>
    public required string Job { get; init; }

    /// <summary>Conditions currently open, with the time each one opened, in the order they opened.</summary>
    public ValueMap<Condition, long> Open { get; init; } = ValueMap<Condition, long>.Empty;

    /// <summary>Failed runs in a row.</summary>
    public long ConsecutiveFailures { get; init; }

    /// <summary>Alerts are silenced until this time, or null.</summary>
    public long? SilencedUntil { get; init; }

    /// <summary>When an alert last reached at least one channel, or null.</summary>
    public long? LastAlertAt { get; init; }

    /// <summary>
    /// Conditions that alerted and have since closed, waiting for the next successful run's
    /// recovery; null in a state written before the field existed.
    /// </summary>
    public ValueList<Condition>? PendingRecovery { get; init; }

    /// <summary>Alerts no channel accepted, retried at each check; null in a state written before the field existed.</summary>
    public ValueList<Alert>? Undelivered { get; init; }

    /// <summary>
    /// The outbox: alerts written with the state that opened their condition, while the process
    /// that wrote them sends them. Each leaves once that process records how the send went; one
    /// still here after its <see cref="SendingAlert.Until"/> (the process stopped part way) goes
    /// to <see cref="Undelivered"/> at the next check. Null when empty, and in state written
    /// before the field existed; an empty list is written as no key.
    /// </summary>
    public ValueList<SendingAlert>? Sending { get; init; }

    /// <summary>
    /// The version as stored when it is a whole number (any other value reads as null); see
    /// <see cref="CountedVersion"/>.
    /// </summary>
    public long? Version { get; init; }

    /// <summary>Keys this port does not know, <c>version</c> among them, in their places.</summary>
    public JsObject Extra
    {
        get => _extra.Copy();
        init => _extra = (value ?? throw new ArgumentNullException(nameof(value))).Copy();
    }

    private readonly JsObject _extra = new();

    /// <summary>A job's state before anything happened.</summary>
    public static JobState Initial(string job) => new()
    {
        Job = job,
        PendingRecovery = ValueList<Condition>.Empty,
        Undelivered = ValueList<Alert>.Empty,
    };

    /// <summary>When the condition opened, or null when it is not open.</summary>
    public long? OpenAt(Condition condition) => Open.TryGetValue(condition, out long at) ? at : null;

    /// <summary>
    /// The version as the SDK's <c>stateVersion</c> counts it: a whole number from 0 to 2^53 - 1,
    /// else 0.
    /// </summary>
    public long CountedVersion => Version is long v && v >= 0 && v <= Js.MaxSafeInteger ? v : 0;

    /// <summary>The state as the SDK's JSON object, keys in its order.</summary>
    public JsObject ToValue()
    {
        var openObject = new JsObject();
        foreach (var e in Open)
        {
            openObject.Set(e.Key.Value, e.Value);
        }
        var o = new JsObject()
            .Set("job", Job)
            .Set("open", openObject)
            .Set("consecutiveFailures", ConsecutiveFailures)
            .Set("silencedUntil", SilencedUntil)
            .Set("lastAlertAt", LastAlertAt);
        if (PendingRecovery != null)
        {
            var list = new List<object?>();
            foreach (var c in PendingRecovery)
            {
                list.Add(c.Value);
            }
            o.Set("pendingRecovery", list);
        }
        if (Undelivered != null)
        {
            var list = new List<object?>();
            foreach (var a in Undelivered)
            {
                list.Add(a.ToValue());
            }
            o.Set("undelivered", list);
        }
        if (Sending is { Count: > 0 })
        {
            var list = new List<object?>();
            foreach (var e in Sending)
            {
                list.Add(e.ToValue());
            }
            o.Set("sending", list);
        }
        bool wroteVersion = false;
        foreach (var e in _extra)
        {
            if (e.Key == "version")
            {
                if (Version != null)
                {
                    o.Set("version", Version.Value);
                    wroteVersion = true;
                }
                continue;
            }
            o.Set(e.Key, JsonText.Copy(e.Value));
        }
        if (Version != null && !wroteVersion)
        {
            o.Set("version", Version.Value);
        }
        return o;
    }

    /// <summary>The state's JSON.</summary>
    public string ToJson() => ToValue().ToJson();

    /// <summary>A state read from JSON.</summary>
    /// <exception cref="JsonParseException">When it is not a state.</exception>
    public static JobState FromJson(string text) => FromValue(Json.Parse(text));

    /// <summary>A state read from a JSON value, leniently, as the SDK reads a stored state.</summary>
    /// <exception cref="JsonParseException">When it is not an object.</exception>
    public static JobState FromValue(object? v)
    {
        if (v is not JsObject o)
        {
            throw new JsonParseException("a job state must be an object, not " + JsonText.Kind(v));
        }
        var open = new List<KeyValuePair<Condition, long>>();
        if (o.Get("open") is JsObject opened)
        {
            foreach (var e in opened)
            {
                open.Add(new(new Condition(e.Key), JsonText.TryNumber(e.Value, out double n) ? Js.ToLong(n) : 0L));
            }
        }
        List<Condition>? pending = null;
        if (o.Get("pendingRecovery") is List<object?> pl)
        {
            pending = [];
            foreach (var c in pl)
            {
                if (c is string s)
                {
                    pending.Add(new Condition(s));
                }
            }
        }
        List<Alert>? undelivered = null;
        if (o.Get("undelivered") is List<object?> ul)
        {
            undelivered = [];
            foreach (var a in ul)
            {
                try
                {
                    undelivered.Add(Alert.FromValue(a));
                }
                catch (JsonParseException)
                {
                    // Not an alert: it could never be delivered.
                }
            }
        }
        List<SendingAlert>? sending = null;
        if (o.Get("sending") is List<object?> sl && sl.Count > 0)
        {
            sending = [];
            foreach (var e in sl)
            {
                sending.Add(SendingAlert.FromValue(e));
            }
        }
        long? version = null;
        var extra = new JsObject();
        foreach (var e in o)
        {
            if (KnownKeys.Contains(e.Key))
            {
                continue;
            }
            if (e.Key == "version")
            {
                // A version that is not a whole number (1.5, "x") reads as none; one out of range
                // is kept, so the state writes back as it was read. Either counts as 0.
                version = JsonText.TryNumber(e.Value, out double n) && Js.IsInteger(n) ? Js.ToLong(n) : null;
            }
            extra.Set(e.Key, e.Value);
        }
        return new JobState
        {
            Job = Values.String(o, "job"),
            Open = ValueMap<Condition, long>.Of(open),
            ConsecutiveFailures = Evaluate.FailureCount(o.Get("consecutiveFailures")),
            SilencedUntil = Values.NullableInteger(o, "silencedUntil"),
            LastAlertAt = Values.NullableInteger(o, "lastAlertAt"),
            PendingRecovery = pending == null ? null : ValueList<Condition>.Of(pending),
            Undelivered = undelivered == null ? null : ValueList<Alert>.Of(undelivered),
            Sending = sending == null ? null : ValueList<SendingAlert>.Of(sending),
            Version = version,
            Extra = extra,
        };
    }

    /// <summary>Equal when both write the same JSON.</summary>
    public bool Equals(JobState? other) => other is not null && string.Equals(ToJson(), other.ToJson(), StringComparison.Ordinal);

    /// <inheritdoc/>
    public override int GetHashCode() => StringComparer.Ordinal.GetHashCode(ToJson());
}
