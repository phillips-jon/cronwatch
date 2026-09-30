using System.Collections.Generic;
using Cronwatch.Internal;

namespace Cronwatch;

/// <summary>
/// An alert: the SDK's <c>Alert</c>, field for field, with <see cref="Details"/> of the type's own
/// shape.
/// </summary>
public sealed record Alert
{
    /// <summary>What happened.</summary>
    public required AlertType Type { get; init; }

    /// <summary>The run it is about, or null.</summary>
    public Run? Run { get; init; }

    /// <summary>What the type carries.</summary>
    public required AlertDetails Details { get; init; }

    /// <summary>The job's name.</summary>
    public required string Job { get; init; }

    /// <summary>The job's definition as stored.</summary>
    public required Definition Definition { get; init; }

    /// <summary>One line, suitable as a notification title.</summary>
    public required string Title { get; init; }

    /// <summary>A few lines of plain text with the specifics.</summary>
    public required string Message { get; init; }

    /// <summary>A short diagnosis from triage, or null.</summary>
    public string? Triage { get; init; }

    /// <summary>Whether triage was tried (the stored alert then has a <c>triage</c> key, null when it gave nothing).</summary>
    public bool TriageTried { get; init; }

    /// <summary>When it was raised.</summary>
    public required long At { get; init; }

    /// <summary>A copy with triage's answer (null for none), marked tried.</summary>
    public Alert WithTriage(string? diagnosis) => this with { Triage = diagnosis, TriageTried = true };

    /// <summary>The alert as the SDK's JSON object, keys in its order.</summary>
    public JsObject ToValue()
    {
        var o = new JsObject()
            .Set("type", Type.Value)
            .Set("run", Run?.ToValue())
            .Set("details", Details.ToValue())
            .Set("job", Job)
            .Set("definition", Definition.ToObject())
            .Set("title", Title)
            .Set("message", Message)
            .Set("at", At);
        if (TriageTried || Triage != null)
        {
            o.Set("triage", Triage);
        }
        return o;
    }

    /// <summary>The alert's JSON.</summary>
    public string ToJson() => ToValue().ToJson();

    /// <summary>An alert read from JSON.</summary>
    /// <exception cref="JsonException">When it is not an alert.</exception>
    public static Alert FromJson(string text) => FromValue(Json.Parse(text));

    /// <summary>An alert read from a JSON value, leniently.</summary>
    /// <exception cref="JsonException">When it is not an alert.</exception>
    public static Alert FromValue(object? v)
    {
        if (v is not JsObject o)
        {
            throw new JsonException("an alert must be an object, not " + Json.Kind(v));
        }
        var type = new AlertType(Values.String(o, "type"));
        Run? run = null;
        object? r = o.Get("run");
        if (r is JsObject ro)
        {
            var copy = ro.Copy();
            copy.Set("metrics", Metrics.Lenient(copy.Get("metrics")).ToValue());
            run = Run.FromValue(copy);
        }
        else if (r != null)
        {
            run = Run.FromValue(r);
        }
        var details = o.Get("details") as JsObject ?? new JsObject();
        var definition = o.Get("definition") as JsObject ?? new JsObject();
        return new Alert
        {
            Type = type,
            Run = run,
            Details = AlertDetails.FromValue(type, details),
            Job = Values.String(o, "job"),
            Definition = Definition.Of(definition),
            Title = Values.String(o, "title"),
            Message = Values.String(o, "message"),
            Triage = Values.NullableString(o, "triage"),
            TriageTried = o.Has("triage"),
            At = Values.Integer(o, "at"),
        };
    }
}

/// <summary>What each alert type carries: the SDK's <c>AlertDetails</c>.</summary>
public abstract record AlertDetails
{
    private protected AlertDetails()
    {
    }

    /// <summary>The details as the SDK's JSON object.</summary>
    public abstract JsObject ToValue();

    /// <summary>A missed run: when it was due, the deadline, the grace, and the last run's start.</summary>
    public sealed record Missed(long DueAt, double Deadline, double GraceMs, long? LastRunAt) : AlertDetails
    {
        /// <inheritdoc/>
        public override JsObject ToValue() => new JsObject()
            .Set("dueAt", DueAt).Set("deadline", Deadline).Set("graceMs", GraceMs).Set("lastRunAt", LastRunAt);
    }

    /// <summary>A failure or a stuck run: failures in a row and the threshold.</summary>
    public sealed record Failure(long ConsecutiveFailures, long Threshold) : AlertDetails
    {
        /// <inheritdoc/>
        public override JsObject ToValue() => new JsObject()
            .Set("consecutiveFailures", ConsecutiveFailures).Set("threshold", Threshold);
    }

    /// <summary>A slow run: how long it took, the threshold, and where the threshold came from.</summary>
    public sealed record Slow(long DurationMs, double ThresholdMs, string Basis) : AlertDetails
    {
        /// <inheritdoc/>
        public override JsObject ToValue() => new JsObject()
            .Set("durationMs", DurationMs).Set("thresholdMs", ThresholdMs).Set("basis", Basis);
    }

    /// <summary>Metrics over their budgets.</summary>
    public sealed record OverBudget(ValueList<BudgetBreach> Breaches) : AlertDetails
    {
        /// <inheritdoc/>
        public override JsObject ToValue()
        {
            var list = new List<object?>();
            foreach (var b in Breaches)
            {
                list.Add(b.ToValue());
            }
            return new JsObject().Set("breaches", list);
        }
    }

    /// <summary>
    /// Conditions that closed; <c>reason</c> "unscheduled" closes missed alone, <c>since</c> being
    /// when it opened.
    /// </summary>
    public sealed record Recovered(ValueList<Condition> After, string? Reason, long? Since) : AlertDetails
    {
        /// <inheritdoc/>
        public override JsObject ToValue()
        {
            var list = new List<object?>();
            foreach (var c in After)
            {
                list.Add(c.Value);
            }
            var o = new JsObject().Set("after", list);
            if (!string.IsNullOrEmpty(Reason))
            {
                o.Set("reason", Reason);
            }
            if (Since != null)
            {
                o.Set("since", Since.Value);
            }
            return o;
        }
    }

    /// <summary>Details read from JSON for an alert of this type.</summary>
    internal static AlertDetails FromValue(AlertType type, JsObject o)
    {
        if (type == AlertType.Missed)
        {
            return new Missed(Values.Integer(o, "dueAt"), Values.Number(o, "deadline"), Values.Number(o, "graceMs"), Values.NullableInteger(o, "lastRunAt"));
        }
        if (type == AlertType.Slow)
        {
            return new Slow(Values.Integer(o, "durationMs"), Values.Number(o, "thresholdMs"), Values.String(o, "basis"));
        }
        if (type == AlertType.OverBudget)
        {
            var breaches = new List<BudgetBreach>();
            if (o.Get("breaches") is List<object?> list)
            {
                foreach (var b in list)
                {
                    var bo = b as JsObject ?? new JsObject();
                    breaches.Add(new BudgetBreach(Values.String(bo, "metric"), Values.Number(bo, "value"), Values.Number(bo, "limit"), Values.String(bo, "basis")));
                }
            }
            return new OverBudget(ValueList<BudgetBreach>.Of(breaches));
        }
        if (type == AlertType.Recovered)
        {
            var after = new List<Condition>();
            if (o.Get("after") is List<object?> list)
            {
                foreach (var c in list)
                {
                    if (c is string s)
                    {
                        after.Add(new Condition(s));
                    }
                }
            }
            return new Recovered(ValueList<Condition>.Of(after), Values.NullableString(o, "reason"), Values.NullableInteger(o, "since"));
        }
        return new Failure(Values.Integer(o, "consecutiveFailures"), Values.Integer(o, "threshold"));
    }
}

/// <summary>A metric over its budget: the value, the limit, and where the limit came from.</summary>
/// <param name="Metric">The metric's name.</param>
/// <param name="Value">What the run reported.</param>
/// <param name="Limit">The limit it went over.</param>
/// <param name="Basis">Where the limit came from.</param>
public sealed record BudgetBreach(string Metric, double Value, double Limit, string Basis)
{
    /// <summary>The breach as the SDK's JSON object.</summary>
    public JsObject ToValue() => new JsObject().Set("metric", Metric).Set("value", Value).Set("limit", Limit).Set("basis", Basis);
}

/// <summary>A job as the dashboard and the check report it: the SDK's <c>JobSummary</c>.</summary>
public sealed record JobSummary
{
    /// <summary>The job's name.</summary>
    public required string Name { get; init; }

    /// <summary>Its definition.</summary>
    public required Definition Definition { get; init; }

    /// <summary>Its health.</summary>
    public required JobHealth Health { get; init; }

    /// <summary>The conditions open.</summary>
    public ValueList<Condition> Open { get; init; } = ValueList<Condition>.Empty;

    /// <summary>The newest run, or null.</summary>
    public Run? LastRun { get; init; }

    /// <summary>When the schedule says the next run is due; null without a schedule.</summary>
    public long? NextExpectedAt { get; init; }

    /// <summary>Failed runs in a row.</summary>
    public long ConsecutiveFailures { get; init; }

    /// <summary>Silenced until, or null.</summary>
    public long? SilencedUntil { get; init; }

    /// <summary>From the last twenty runs.</summary>
    public required JobStats Stats { get; init; }

    /// <summary>The summary as the SDK's JSON object.</summary>
    public JsObject ToValue()
    {
        var conditions = new List<object?>();
        foreach (var c in Open)
        {
            conditions.Add(c.Value);
        }
        return new JsObject()
            .Set("name", Name)
            .Set("definition", Definition.ToObject())
            .Set("health", Health.Value)
            .Set("open", conditions)
            .Set("lastRun", LastRun?.ToValue())
            .Set("nextExpectedAt", NextExpectedAt)
            .Set("consecutiveFailures", ConsecutiveFailures)
            .Set("silencedUntil", SilencedUntil)
            .Set("stats", Stats.ToValue());
    }

    /// <summary>The summary's JSON.</summary>
    public string ToJson() => ToValue().ToJson();
}

/// <summary>A job's recent numbers: runs of any status, the share that succeeded, and the p50 and p95 of those.</summary>
/// <param name="Runs">How many runs.</param>
/// <param name="OkRate">The share that succeeded.</param>
/// <param name="P50Ms">The median duration of the successful ones, or null.</param>
/// <param name="P95Ms">The 95th percentile, or null.</param>
public sealed record JobStats(long Runs, double OkRate, long? P50Ms, long? P95Ms)
{
    /// <summary>The numbers as the SDK's JSON object.</summary>
    public JsObject ToValue() => new JsObject().Set("runs", Runs).Set("okRate", OkRate).Set("p50Ms", P50Ms).Set("p95Ms", P95Ms);
}

/// <summary>What a check found: the SDK's <c>CheckResult</c>.</summary>
/// <param name="CheckedAt">When it ran.</param>
/// <param name="Jobs">Every job's summary.</param>
/// <param name="Alerts">The alerts it raised.</param>
/// <param name="Pruned">How many old runs it deleted.</param>
public sealed record CheckResult(long CheckedAt, ValueList<JobSummary> Jobs, ValueList<Alert> Alerts, long Pruned)
{
    /// <summary>The result as the SDK's JSON object.</summary>
    public JsObject ToValue()
    {
        var js = new List<object?>();
        foreach (var j in Jobs)
        {
            js.Add(j.ToValue());
        }
        var alerts = new List<object?>();
        foreach (var a in Alerts)
        {
            alerts.Add(a.ToValue());
        }
        return new JsObject().Set("checkedAt", CheckedAt).Set("jobs", js).Set("alerts", alerts).Set("pruned", Pruned);
    }

    /// <summary>The result's JSON.</summary>
    public string ToJson() => ToValue().ToJson();
}

/// <summary>A job's summary with its newest runs, as <c>jobsWithRuns</c> answers.</summary>
/// <param name="Job">The summary.</param>
/// <param name="Runs">The newest runs first.</param>
public sealed record JobWithRuns(JobSummary Job, ValueList<Run> Runs);
