using System;
using System.Collections.Generic;
using System.Linq;
using Cronwatch.Internal;
using Xunit;

namespace Cronwatch.Tests;

/// <summary>
/// <c>conformance/health.json</c>: health, summaries, percentiles, state normalization, silence,
/// which queued alerts a retry drops, a run's duration and a state's version.
/// </summary>
public class HealthConformanceTests
{
    private static List<Run> Runs(object? v) =>
        v is List<object?> list ? list.Where(r => r != null).Select(Run.FromValue).ToList() : [];

    private static JobState State(object? v) => JobState.FromValue(v);

    private static StoredJob Stored(object? v)
    {
        var o = (JsObject)v!;
        return new StoredJob(Fixtures.String(o, "name")!, EvaluateCases.Definition(o.Get("definition")),
            Fixtures.Integer(o, "createdAt"), Fixtures.Integer(o, "updatedAt"));
    }

    private static List<double> Numbers(object? v)
    {
        var output = new List<double>();
        if (v is List<object?> list)
        {
            foreach (var n in list)
            {
                if (JsonText.TryNumber(n, out double d))
                {
                    output.Add(d);
                }
            }
        }
        return output;
    }

    // What a function answers, or "error: <message>" as the fixture writes a throw.
    private static object? OrError(Func<object?> f)
    {
        try
        {
            return f();
        }
        catch (ArgumentException e)
        {
            return "error: " + e.Message;
        }
    }

    [Fact]
    public void Every_case_answers_as_the_sdk_answers()
    {
        var f = Fixtures.Load("health");
        var fails = new Fixtures.Failures();
        int cases = 0;
        int i = 0;
        foreach (var c in Fixtures.Objects(f, "jobHealth"))
        {
            cases++;
            var got = OrError(() => Evaluate.JobHealthOf(EvaluateCases.Definition(c.Get("definition")), EvaluateCases.Run(c.Get("lastRun")),
                State(c.Get("state")), Fixtures.Integer(c, "now")).Value);
            fails.Same("jobHealth " + i++, got, c.Get("health"));
        }
        i = 0;
        foreach (var c in Fixtures.Objects(f, "summarize"))
        {
            cases++;
            var got = OrError(() => Evaluate.Summarize(Stored(c.Get("stored")), Runs(c.Get("recent")), State(c.Get("state")),
                Fixtures.OptInteger(c, "nextExpectedAt"), Fixtures.Integer(c, "now")).ToValue());
            fails.Same("summarize " + i++, got, c.Get("summary"));
        }
        foreach (var c in Fixtures.Objects(f, "percentile"))
        {
            cases++;
            double p = Fixtures.Number(c, "p");
            fails.Same("percentile(" + Json.Stringify(c.Get("values")) + ", " + Json.Stringify(p) + ")",
                Stats.Percentile(Numbers(c.Get("values")), p), c.Get("percentile"));
        }
        foreach (var c in Fixtures.Objects(f, "median"))
        {
            cases++;
            fails.Same("median(" + Json.Stringify(c.Get("values")) + ")", Stats.Median(Numbers(c.Get("values"))), c.Get("median"));
        }
        i = 0;
        foreach (var c in Fixtures.Objects(f, "normalizeState"))
        {
            cases++;
            // Any stored JSON value: one that is not an object reads as no state.
            fails.Same("normalizeState " + i++, Evaluate.NormalizeStateValue(c.Get("state"), "j").ToValue(), c.Get("normalized"));
        }
        i = 0;
        foreach (var c in Fixtures.Objects(f, "muteOpens"))
        {
            cases++;
            fails.Same("muteOpens " + i++, Evaluate.MuteOpens(State(c.Get("previous")), State(c.Get("next"))).ToValue(), c.Get("muted"));
        }
        i = 0;
        foreach (var c in Fixtures.Objects(f, "isStuck"))
        {
            cases++;
            var got = OrError(() => Evaluate.IsStuck(EvaluateCases.Definition(c.Get("definition")), EvaluateCases.Run(c.Get("run"))!,
                Fixtures.Integer(c, "now")));
            fails.Same("isStuck " + i++, got, c.Get("stuck"));
        }
        i = 0;
        foreach (var c in Fixtures.Objects(f, "unevaluableSummary"))
        {
            cases++;
            fails.Same("unevaluableSummary " + i++,
                Evaluate.UnevaluableSummary(Stored(c.Get("stored")), Runs(c.Get("recent")), State(c.Get("state")), Fixtures.Integer(c, "now")).ToValue(),
                c.Get("summary"));
        }
        i = 0;
        foreach (var c in Fixtures.Objects(f, "applySilence"))
        {
            cases++;
            var e = Fixtures.Object(c, "evaluation");
            var drafts = Fixtures.List(e, "alerts").Select(EvaluateCases.Draft).ToList();
            var output = Evaluate.ApplySilence(State(c.Get("previous")), new Evaluation(State(e.Get("state")), drafts), Fixtures.Integer(c, "now"));
            fails.Same("applySilence " + i++,
                new JsObject().Set("state", output.State.ToValue()).Set("alerts", output.Alerts.Select(d => (object?)d.ToValue()).ToList()),
                c.Get("result"));
        }
        i = 0;
        foreach (var c in Fixtures.Objects(f, "staleAlert"))
        {
            cases++;
            fails.Same("staleAlert " + i++, Evaluate.StaleAlert(Alert.FromValue(c.Get("alert")), State(c.Get("state"))), c.Get("stale"));
        }
        i = 0;
        foreach (var c in Fixtures.Objects(f, "runDuration"))
        {
            cases++;
            fails.Same("runDuration " + i++, Evaluate.RunDuration(Fixtures.Integer(c, "startedAt"), Fixtures.Integer(c, "finishedAt")), c.Get("durationMs"));
        }
        i = 0;
        foreach (var c in Fixtures.Objects(f, "stateVersion"))
        {
            cases++;
            string text = Fixtures.String(c, "state")!;
            object? parsed = Json.Parse(text);
            long fromValue = Evaluate.StateVersion(parsed is JsObject o ? o.Get("version") : null);
            fails.Same("stateVersion " + i, fromValue, c.Get("version"));
            fails.Same("stateVersion " + i++ + ", read as a state", JobState.FromJson(text).CountedVersion, c.Get("version"));
        }
        // failureCount: a state's failures in a row, read from its JSON text, then a failed run from it.
        const long t0 = 1_767_605_400_000;
        var failedDef = EvaluateCases.Definition(Json.Parse("{\"name\":\"j\",\"failuresBeforeAlert\":3}"));
        var failedRun = Run.FromValue(new JsObject()
            .Set("id", "f").Set("job", "j").Set("status", "failed").Set("startedAt", (double)(t0 - 60_000))
            .Set("finishedAt", (double)(t0 - 59_000)).Set("durationMs", 1000.0).Set("error", "Error: boom")
            .Set("output", null).Set("metrics", new JsObject()).Set("trigger", "run"));
        i = 0;
        foreach (var c in Fixtures.Objects(f, "failureCount"))
        {
            cases++;
            string text = Fixtures.String(c, "state")!;
            var normalized = Evaluate.NormalizeState(JobState.FromJson(text), "j");
            fails.Same("failureCount " + i, normalized.ConsecutiveFailures, c.Get("consecutiveFailures"));
            var output = Evaluate.OnRunFinish(failedDef, failedRun, normalized, [], t0);
            fails.Same("failureCount " + i++ + ", then a failed run",
                new JsObject().Set("state", output.State.ToValue()).Set("alerts", output.Alerts.Select(d => (object?)d.ToValue()).ToList()),
                c.Get("failed"));
        }
        // silenceEnd: a duration as parseDuration reads it, then when the silence ends.
        i = 0;
        foreach (var c in Fixtures.Objects(f, "silenceEnd"))
        {
            cases++;
            double ms = Durations.ParseValue(c.Get("duration"), "silence duration");
            fails.Same("silenceEnd " + i++, Evaluate.SilenceEnd(Fixtures.Integer(c, "now"), ms), c.Get("silencedUntil"));
        }
        cases += Delivery(Fixtures.Object(f, "delivery"), fails);
        Assert.Equal(231, cases);
        fails.Check("health");
    }

    private static List<Alert> Alerts(object? v) =>
        v is List<object?> list ? list.Select(Alert.FromValue).ToList() : [];

    /// <summary>
    /// The fixture's value with each alert written as this port writes one (its keys in the
    /// order <see cref="Alert.ToValue"/> gives), so a state is compared key for key while an
    /// alert is compared field for field.
    /// </summary>
    private static object? AlertsAsWritten(object? v)
    {
        switch (v)
        {
            case JsObject o when o.Has("type") && o.Has("details") && o.Has("title"):
                return Alert.FromValue(o).ToValue();
            case JsObject o:
                var copy = new JsObject();
                foreach (var e in o)
                {
                    copy.Set(e.Key, AlertsAsWritten(e.Value));
                }
                return copy;
            case List<object?> list:
                return list.Select(AlertsAsWritten).ToList();
            default:
                return v;
        }
    }

    private static JsObject Result((JobState State, int Dropped) r) =>
        new JsObject().Set("state", r.State.ToValue()).Set("dropped", r.Dropped);

    /// <summary>The <c>delivery</c> section: the outbox and the retry queue, as each write leaves the state.</summary>
    private static int Delivery(JsObject d, Fixtures.Failures fails)
    {
        Assert.Equal(Evaluate.MaxUndelivered, Fixtures.Integer(d, "maxUndelivered"));
        Assert.Equal(Evaluate.SendLeaseMs, Fixtures.Integer(d, "sendLeaseMs"));
        int cases = 0;
        int i = 0;
        foreach (var c in Fixtures.Objects(d, "alertKey"))
        {
            cases++;
            var raw = Fixtures.Object(c, "alert");
            string want = Fixtures.String(c, "key")!;
            // An alert's time is a whole millisecond here, so a fractional one is read as the
            // millisecond it falls in (see DESIGN.md), and its key names that millisecond.
            double at = Fixtures.Number(raw, "at");
            if (!Js.IsInteger(at))
            {
                want = want.Replace("|" + Js.FormatNumber(at) + "|", "|" + Js.FormatLong(Js.ToLong(at)) + "|", StringComparison.Ordinal);
            }
            fails.Same("alertKey " + i++, Evaluate.AlertKey(Alert.FromValue(raw)), want);
        }
        i = 0;
        foreach (var c in Fixtures.Objects(d, "normalizeState"))
        {
            cases++;
            fails.Same("delivery normalizeState " + i++, Evaluate.NormalizeState(State(c.Get("state")), "j").ToValue(), AlertsAsWritten(c.Get("normalized")));
        }
        i = 0;
        foreach (var c in Fixtures.Objects(d, "queueUndelivered"))
        {
            cases++;
            fails.Same("queueUndelivered " + i++, Result(Evaluate.QueueUndelivered(State(c.Get("state")), Alerts(c.Get("alerts")))), AlertsAsWritten(c.Get("result")));
        }
        i = 0;
        foreach (var c in Fixtures.Objects(d, "holdAlerts"))
        {
            cases++;
            var got = Evaluate.HoldAlerts(State(c.Get("state")), Alerts(c.Get("alerts")), Fixtures.Integer(c, "until"), c.Get("deferred") is true);
            fails.Same("holdAlerts " + i++, Result(got), AlertsAsWritten(c.Get("result")));
        }
        i = 0;
        foreach (var c in Fixtures.Objects(d, "releaseSending"))
        {
            cases++;
            fails.Same("releaseSending " + i++, Result(Evaluate.ReleaseSending(State(c.Get("state")), Fixtures.Integer(c, "now"))), AlertsAsWritten(c.Get("result")));
        }
        i = 0;
        foreach (var c in Fixtures.Objects(d, "recordSent"))
        {
            cases++;
            var got = Evaluate.RecordSent(State(c.Get("state")), Alerts(c.Get("delivered")), Alerts(c.Get("failed")), Alerts(c.Get("stale")), Fixtures.Integer(c, "now"));
            fails.Same("recordSent " + i++, Result(got), AlertsAsWritten(c.Get("result")));
        }
        return cases;
    }
}
