using System;
using Cronwatch.Internal;

namespace Cronwatch;

/// <summary>
/// One run of a job, as stored: the SDK's <c>Run</c>, field for field. Times are epoch
/// milliseconds.
/// </summary>
public sealed record Run
{
    /// <summary>The run's id, unique in the store.</summary>
    public required string Id { get; init; }

    /// <summary>The job's name.</summary>
    public required string Job { get; init; }

    /// <summary>The run's status.</summary>
    public required RunStatus Status { get; init; }

    /// <summary>When it started.</summary>
    public required long StartedAt { get; init; }

    /// <summary>When it finished, or null while it runs.</summary>
    public long? FinishedAt { get; init; }

    /// <summary>How long it took, or null while it runs.</summary>
    public long? DurationMs { get; init; }

    /// <summary>The error, <c>Name: message</c>, and frames, or null.</summary>
    public string? Error { get; init; }

    /// <summary>What it logged, or the string it returned, capped; or null.</summary>
    public string? Output { get; init; }

    /// <summary>The metrics it reported.</summary>
    public Metrics Metrics { get; init; } = Metrics.Empty;

    /// <summary>What started it: <c>run</c>, <c>handler</c>, or a value of the caller's.</summary>
    public required string Trigger { get; init; }

    /// <summary>A run that has just started.</summary>
    public static Run Running(string id, string job, long startedAt, string trigger) => new()
    {
        Id = id,
        Job = job,
        Status = RunStatus.Running,
        StartedAt = startedAt,
        Trigger = trigger,
    };

    /// <summary>The run as the SDK's JSON object, keys in its order.</summary>
    public JsObject ToValue() => new JsObject()
        .Set("id", Id)
        .Set("job", Job)
        .Set("status", Status.Value)
        .Set("startedAt", StartedAt)
        .Set("finishedAt", FinishedAt)
        .Set("durationMs", DurationMs)
        .Set("error", Error)
        .Set("output", Output)
        .Set("metrics", Metrics.ToValue())
        .Set("trigger", Trigger);

    /// <summary>The run's JSON.</summary>
    public string ToJson() => ToValue().ToJson();

    /// <summary>A run read from JSON.</summary>
    /// <exception cref="JsonParseException">When it is not a run.</exception>
    public static Run FromJson(string text) => FromValue(Json.Parse(text));

    /// <summary>A run read from a JSON value.</summary>
    /// <exception cref="JsonParseException">When it is not a run.</exception>
    public static Run FromValue(object? v)
    {
        if (v is not JsObject o)
        {
            throw new JsonParseException("a run must be an object, not " + JsonText.Kind(v));
        }
        return new Run
        {
            Id = Values.String(o, "id"),
            Job = Values.String(o, "job"),
            Status = new RunStatus(Values.String(o, "status")),
            StartedAt = Values.Integer(o, "startedAt"),
            FinishedAt = Values.NullableInteger(o, "finishedAt"),
            DurationMs = Values.NullableInteger(o, "durationMs"),
            Error = Values.NullableString(o, "error"),
            Output = Values.NullableString(o, "output"),
            Metrics = Metrics.FromValue(o.Get("metrics")),
            Trigger = Values.String(o, "trigger"),
        };
    }
}

/// <summary>
/// A job's definition as stored: the SDK's <c>StoredJobDefinition</c>, its fields in the order
/// they were given, with fields a newer writer added kept.
/// </summary>
public sealed class Definition : IEquatable<Definition>
{
    private readonly JsObject _fields;

    private Definition(JsObject fields)
    {
        _fields = fields;
    }

    /// <summary>A definition of these fields (copied).</summary>
    public static Definition Of(JsObject fields)
    {
        ArgumentNullException.ThrowIfNull(fields);
        return new Definition(fields.Copy());
    }

    /// <summary>A definition over fields the caller gives up.</summary>
    internal static Definition Own(JsObject fields) => new(fields);

    /// <summary>
    /// What a SQL store reads for a stored definition that is not a JSON object (text that does not
    /// parse, <c>null</c>, a string, a number, a list): <c>{ name }</c>, marked so that the client
    /// reports the job and shows it as failing, without evaluating it.
    /// </summary>
    internal static Definition UnreadableFor(string name) => new(new JsObject().Set("name", name)) { Unreadable = true };

    /// <summary>Whether this stands for a stored definition that was not a JSON object.</summary>
    internal bool Unreadable { get; private init; }

    /// <summary>A definition read from JSON.</summary>
    /// <exception cref="JsonParseException">When it is not an object.</exception>
    public static Definition FromJson(string text) => new(Json.ParseObject(text));

    /// <summary>The job's name.</summary>
    public string Name => _fields.Get("name") as string ?? "";

    /// <summary>The schedule, or null.</summary>
    public string? Schedule => _fields.Get("schedule") as string;

    /// <summary>The zone, or null.</summary>
    public string? Timezone => _fields.Get("timezone") as string;

    /// <summary>The description, or null.</summary>
    public string? Description => _fields.Get("description") as string;

    /// <summary>The expect rule as stored, or null.</summary>
    public string? Expect => _fields.Get("expect") as string;

    /// <summary>The tags that are strings.</summary>
    public ValueList<string> Tags
    {
        get
        {
            var output = new System.Collections.Generic.List<string>();
            if (_fields.Get("tags") is System.Collections.Generic.List<object?> list)
            {
                foreach (var t in list)
                {
                    if (t is string s)
                    {
                        output.Add(s);
                    }
                }
            }
            return ValueList<string>.Of(output);
        }
    }

    /// <summary>A field's value (a copy), or null.</summary>
    public object? Get(string key) => JsonText.Copy(_fields.Get(key));

    /// <summary>Whether the field is there.</summary>
    public bool Has(string key) => _fields.Has(key);

    /// <summary>The field names in order.</summary>
    public System.Collections.Generic.IReadOnlyList<string> Keys => _fields.Keys;

    /// <summary>The fields as a JSON object (a copy).</summary>
    public JsObject ToObject() => _fields.Copy();

    /// <summary>The fields without copying, for the port's own readers.</summary>
    internal JsObject Fields => _fields;

    /// <summary>The definition's JSON.</summary>
    public string ToJson() => _fields.ToJson();

    /// <summary>The definition's JSON.</summary>
    public override string ToString() => ToJson();

    /// <inheritdoc/>
    public bool Equals(Definition? other) => other is not null && _fields.Equals(other._fields);

    /// <inheritdoc/>
    public override bool Equals(object? obj) => obj is Definition d && Equals(d);

    /// <inheritdoc/>
    public override int GetHashCode() => _fields.GetHashCode();
}

/// <summary>A job as stored: its name, definition, and when it was first and last written.</summary>
/// <param name="Name">The job's name.</param>
/// <param name="Definition">Its definition.</param>
/// <param name="CreatedAt">When it was first written.</param>
/// <param name="UpdatedAt">When it was last written.</param>
public sealed record StoredJob(string Name, Definition Definition, long CreatedAt, long UpdatedAt);
