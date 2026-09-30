using System;
using System.Collections.Generic;
using System.Linq;
using Cronwatch.Internal;
using Xunit;

namespace Cronwatch.Tests;

/// <summary>What the evaluate, format and health replays share: reading their fixtures' values.</summary>
internal static class EvaluateCases
{
    public static Definition Definition(object? v) => Cronwatch.Definition.Of(v as JsObject ?? new JsObject());

    public static Run? Run(object? v) => v == null ? null : Cronwatch.Run.FromValue(v);

    public static AlertDraft Draft(object? v)
    {
        var o = (JsObject)v!;
        var type = new AlertType(Fixtures.String(o, "type")!);
        return new AlertDraft(type, Run(o.Get("run")), AlertDetails.FromValue(type, Fixtures.Object(o, "details")));
    }
}

/// <summary>
/// <c>conformance/evaluate.json</c>: each scenario plays a job's life through the pure functions
/// the way the client does (a run's start and finish, a check with stuck runs first and then
/// missed, a silence, a changed definition), and every event's alerts and state must be the
/// SDK's, byte for byte.
/// </summary>
public class EvaluateConformanceTests
{
    /// <summary><c>scripts/conformance.mjs</c>'s <c>Sim</c>: one job, its runs and its state.</summary>
    private sealed class Sim
    {
        private Definition _def;
        private StoredJob _stored;
        private JobState _state;
        private readonly List<Run> _runs = [];

        public Sim(Definition def, long createdAt)
        {
            _def = def;
            _stored = new StoredJob(def.Name, def, createdAt, createdAt);
            _state = Evaluate.EmptyState(def.Name);
        }

        // The runs newest first, ties broken by insertion (the list's own order).
        private List<Run> Sorted() =>
            _runs.Select((r, i) => (r, i)).OrderByDescending(x => x.r.StartedAt).ThenByDescending(x => x.i).Select(x => x.r).ToList();

        private List<object?> Settle(JobState previous, Evaluation e, long now)
        {
            var settled = Evaluate.ApplySilence(previous, e, now);
            _state = settled.State;
            return settled.Alerts.Select(d => (object?)AlertFormat.ComposeAlert(d, _def, now).ToValue()).ToList();
        }

        private List<object?> FinishRun(Run run, long now)
        {
            var history = Sorted().Where(r => r.Id != run.Id).ToList();
            var previous = _state;
            return Settle(previous, Evaluate.OnRunFinish(_def, run, previous, history, now), now);
        }

        private int Index(string id) => _runs.FindIndex(r => r.Id == id) is int i and >= 0 ? i : throw new InvalidOperationException("no run " + id);

        public JsObject? Play(JsObject ev)
        {
            long at = Fixtures.Integer(ev, "at");
            string op = Fixtures.String(ev, "op")!;
            switch (op)
            {
                case "start":
                    _runs.Add(Cronwatch.Run.Running(Fixtures.String(ev, "id")!, _def.Name, at, "run"));
                    _state = Evaluate.OnRunStart(_state);
                    return new JsObject().Set("state", _state.ToValue());
                case "finish":
                    {
                        int i = Index(Fixtures.String(ev, "id")!);
                        var run = _runs[i];
                        if (run.Status == RunStatus.Ok || run.Status == RunStatus.Failed)
                        {
                            return new JsObject()
                                .Set("alerts", new List<object?>())
                                .Set("state", _state.ToValue())
                                .Set("ignored", "was already finished as " + run.Status.Value);
                        }
                        bool marked = run.Status == RunStatus.Timeout;
                        var metrics = ev.Has("metrics") ? Metrics.FromValue(ev.Get("metrics")) : Metrics.Empty;
                        run = run with
                        {
                            Status = new RunStatus(Fixtures.String(ev, "status")!),
                            FinishedAt = at,
                            DurationMs = Evaluate.RunDuration(run.StartedAt, at),
                            Error = Fixtures.String(ev, "error"),
                            Output = Fixtures.String(ev, "output"),
                            Metrics = metrics,
                        };
                        _runs[i] = run;
                        if (marked && run.Status != RunStatus.Ok)
                        {
                            return new JsObject().Set("alerts", new List<object?>()).Set("state", _state.ToValue());
                        }
                        var alerts = FinishRun(run, at);
                        return new JsObject().Set("alerts", alerts).Set("state", _state.ToValue());
                    }
                case "check":
                    {
                        long now = at;
                        var alerts = new List<object?>();
                        var running = _runs.Select((r, i) => (r, i)).Where(x => x.r.Status == RunStatus.Running)
                            .OrderBy(x => x.r.StartedAt).ThenBy(x => x.i).Select(x => x.i).ToList();
                        foreach (int i in running)
                        {
                            var r = _runs[i];
                            if (!Evaluate.IsStuck(_def, r, now))
                            {
                                continue;
                            }
                            double timeout = Evaluate.TimeoutMs(_def);
                            r = r with
                            {
                                Status = RunStatus.Timeout,
                                FinishedAt = now,
                                DurationMs = Evaluate.RunDuration(r.StartedAt, now),
                                Error = "Still running after " + EvaluateDeps.FormatDuration(timeout) + "; marked as timed out",
                            };
                            _runs[i] = r;
                            alerts.AddRange(FinishRun(r, now));
                        }
                        var recent = Sorted().Take(Evaluate.BaselineWindow).ToList();
                        var previous = _state;
                        var outcome = Evaluate.OnCheck(_def, _stored, recent.Count == 0 ? null : recent[0], previous, now);
                        alerts.AddRange(Settle(previous, outcome.Evaluation, now));
                        var summary = Evaluate.Summarize(_stored, recent, _state, outcome.NextExpectedAt, now);
                        return new JsObject()
                            .Set("alerts", alerts)
                            .Set("state", _state.ToValue())
                            .Set("nextExpectedAt", outcome.NextExpectedAt)
                            .Set("dueAt", outcome.DueAt)
                            .Set("summary", summary.ToValue());
                    }
                case "silence":
                    _state = _state with { SilencedUntil = Fixtures.Integer(ev, "until") };
                    return new JsObject().Set("state", _state.ToValue());
                case "unsilence":
                    _state = _state with { SilencedUntil = null };
                    return new JsObject().Set("state", _state.ToValue());
                case "define":
                    _def = EvaluateCases.Definition(ev.Get("definition"));
                    _stored = _stored with { Definition = _def };
                    return null;
                default:
                    throw new InvalidOperationException("unknown op " + op);
            }
        }
    }

    // Plays every scenario, answering the names of those that need a cron schedule.
    private static List<string> Replay(Fixtures.Failures fails, out int played)
    {
        var f = Fixtures.Load("evaluate");
        var scenarios = Fixtures.Objects(f, "scenarios");
        Assert.Equal(50, scenarios.Count);
        var skipped = new List<string>();
        played = 0;
        foreach (var sc in scenarios)
        {
            string name = Fixtures.String(sc, "name")!;
            var sim = new Sim(EvaluateCases.Definition(sc.Get("definition")), Fixtures.Integer(sc, "createdAt"));
            int i = 0;
            bool cron = false;
            foreach (var ev in Fixtures.Objects(sc, "events"))
            {
                string what = name + ": event " + i++ + " (" + Fixtures.String(ev, "op") + ")";
                try
                {
                    var got = EvaluateDeps.InZone(TimeZoneInfo.Utc, () => sim.Play(ev));
                    if (got != null)
                    {
                        fails.Same(what, got, ev.Get("expect"));
                    }
                }
                catch (Exception e)
                {
                    fails.Fail(what + ": " + e);
                    break;
                }
            }
            if (cron)
            {
                skipped.Add(name);
            }
            else
            {
                played++;
            }
        }
        return skipped;
    }

    [Fact]
    public void Every_scenario_plays_as_the_sdk_plays_it()
    {
        var fails = new Fixtures.Failures();
        var skipped = Replay(fails, out int played);
        Assert.True(played > 0, "no scenarios replayed");
        Assert.Equal(50, played);
        Assert.Empty(skipped);
        fails.Check("evaluate");
    }
}
