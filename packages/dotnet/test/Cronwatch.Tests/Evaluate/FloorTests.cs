using System.Collections.Generic;
using System.Linq;
using Cronwatch.Internal;
using Xunit;
using static Cronwatch.Tests.Support;

namespace Cronwatch.Tests;

/// <summary>The SDK's <c>evaluate.test.ts</c> "floors" test, ported.</summary>
public class FloorTests
{
    private static Run Ok(long at, params (string Metric, double Value)[] metrics) => new()
    {
        Id = "r" + at,
        Job = "j",
        Status = RunStatus.Ok,
        StartedAt = at,
        FinishedAt = at + 1000,
        DurationMs = 1000,
        Metrics = Metrics.Of(metrics.Select(m => new KeyValuePair<string, double>(m.Metric, m.Value))),
        Trigger = "run",
    };

    private static List<string> Types(Evaluation e) => e.Alerts.Select(a => a.Type.Value).ToList();

    private static List<BudgetBreach> Breaches(AlertDraft a) => [.. Assert.IsType<AlertDetails.UnderFloor>(a.Details).Breaches];

    [Fact]
    public void A_floor_or_0_after_five_runs_that_all_reported_more()
    {
        var floored = Definition.FromJson("{\"name\":\"j\",\"floor\":{\"rows\":10}}");
        var shortfall = Evaluate.OnRunFinish(floored, Ok(T0, ("rows", 9)), Evaluate.EmptyState("j"), [], T0 + 1000);
        Assert.Equal(["under_floor"], Types(shortfall));
        Assert.Equal([new BudgetBreach("rows", 9, 10, "floor")], Breaches(shortfall.Alerts[0]));
        var back = Evaluate.OnRunFinish(floored, Ok(T0 + Hour, ("rows", 10)), shortfall.State, [], T0 + Hour + 1000);
        Assert.Equal(["recovered"], Types(back));
        Assert.Null(back.State.UnderFloor);

        var bare = Definition.FromJson("{\"name\":\"j\"}");
        var history = new[] { 1, 2, 3, 4, 5 }.Select(i => Ok(T0 - (i * Hour), ("rows", 100 * i), ("errors", 0))).ToList();
        // Four runs are not a baseline.
        Assert.Empty(Evaluate.OnRunFinish(bare, Ok(T0, ("rows", 0)), Evaluate.EmptyState("j"), history.Skip(1).ToList(), T0).Alerts);
        // A metric that is always 0 never alerts.
        Assert.Empty(Evaluate.OnRunFinish(bare, Ok(T0, ("rows", 1), ("errors", 0)), Evaluate.EmptyState("j"), history, T0).Alerts);
        var zero = Evaluate.OnRunFinish(bare, Ok(T0, ("rows", 0), ("errors", 0)), Evaluate.EmptyState("j"), history, T0);
        Assert.Equal([new BudgetBreach("rows", 0, 100, "the last 5 runs all reported more than 0, the lowest 100")], Breaches(zero.Alerts[0]));
        Assert.Equal(["rows"], zero.State.UnderFloor!);
        Assert.Equal("[\"rows\"]", Json.Stringify(zero.State.ToValue().Get("underFloor")));

        // A job that keeps writing nothing stays open, past the point where its zeros are all the history there is.
        var state = zero.State;
        var runs = new List<Run>(history);
        for (int i = 1; i <= 30; i++)
        {
            runs.Insert(0, Ok(T0 + ((i - 1) * Hour), ("rows", 0), ("errors", 0)));
            var next = Evaluate.OnRunFinish(bare, Ok(T0 + (i * Hour), ("rows", 0), ("errors", 0)), state, runs.Take(25).ToList(), T0 + (i * Hour));
            Assert.Empty(next.Alerts);
            Assert.Equal(T0, next.State.OpenAt(Condition.UnderFloor));
            state = next.State;
        }
        var recovered = Evaluate.OnRunFinish(bare, Ok(T0 + (31 * Hour), ("rows", 5), ("errors", 0)), state, runs.Take(25).ToList(), T0 + (31 * Hour));
        Assert.Equal(["recovered"], Types(recovered));
        Assert.Equal([Condition.UnderFloor], Assert.IsType<AlertDetails.Recovered>(recovered.Alerts[0].Details).After);

        // A metric that has reported 0 before is judged as usual for it, and a floor of 0 turns the check off.
        var mixed = history.Take(4).Append(Ok(T0 - (6 * Hour), ("rows", 0))).ToList();
        Assert.Empty(Evaluate.OnRunFinish(bare, Ok(T0, ("rows", 0)), Evaluate.EmptyState("j"), mixed, T0).Alerts);
        var off = Definition.FromJson("{\"name\":\"j\",\"floor\":{\"rows\":0}}");
        Assert.Empty(Evaluate.OnRunFinish(off, Ok(T0, ("rows", 0)), Evaluate.EmptyState("j"), history, T0).Alerts);
    }
}
