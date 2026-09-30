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
                if (Json.TryNumber(n, out double d))
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
        EvaluateTestDeps.Bind();
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
            var input = c.Get("state") == null ? null : State(c.Get("state"));
            fails.Same("normalizeState " + i++, Evaluate.NormalizeState(input, "j").ToValue(), c.Get("normalized"));
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
        Assert.Equal(145, cases);
        fails.Check("health");
    }
}
