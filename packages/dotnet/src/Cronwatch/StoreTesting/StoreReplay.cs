using System;
using System.Collections.Generic;
using System.Threading.Tasks;
using Cronwatch.Internal;
using static Cronwatch.StoreTesting.Checks;

namespace Cronwatch.StoreTesting;

/// <summary>
/// Replays the store cases of the repository's <c>conformance/store.json</c>, which the SDK's
/// memory store answered, against a store: prune scripts, compare-and-set steps, conditional run
/// updates and text written without NUL (<see cref="RunAsync"/>), and states another process wrote
/// with a version that is not a whole number (<see cref="ForeignVersionsAsync"/>). The caller reads
/// the fixture and passes its text, since a published package cannot reach the repository:
/// <code>
/// string fixture = File.ReadAllText("conformance/store.json");
/// int cases = await StoreReplay.RunAsync(fixture, () => new MyStore(EmptyDatabase()));
/// </code>
/// Each method throws a <see cref="StoreContractException"/> at the first case the store answers
/// differently.
/// </summary>
public static class StoreReplay
{
    private static List<JsObject> Objects(object? v)
    {
        var output = new List<JsObject>();
        if (v is List<object?> list)
        {
            foreach (var x in list)
            {
                if (x is JsObject o)
                {
                    output.Add(o);
                }
            }
        }
        return output;
    }

    private static JsObject Field(JsObject o, string key) =>
        o.Get(key) as JsObject ?? throw new StoreContractException("the fixture has no object " + key);

    private static long Number(JsObject o, string key) => Json.TryNumber(o.Get(key), out double n) ? Js.ToLong(n) : -1;

    private static List<RunStatus> Statuses(object? v)
    {
        var from = new List<RunStatus>();
        if (v is List<object?> list)
        {
            foreach (var s in list)
            {
                from.Add(new RunStatus(Convert.ToString(s, System.Globalization.CultureInfo.InvariantCulture) ?? ""));
            }
        }
        return from;
    }

    private static T Capable<T>(IStore store, string what)
        where T : class =>
        store as T ?? throw new StoreContractException("the store does not implement " + typeof(T).Name + ", which " + what + " needs");

    private static async Task CloseAsync(IStore store)
    {
        if (store is IAsyncDisposable d)
        {
            await Must("dispose", async () => await d.DisposeAsync().ConfigureAwait(false)).ConfigureAwait(false);
        }
    }

    /// <summary>
    /// Replays the prune, compare-and-set, conditional update and NUL cases against stores from
    /// <paramref name="fresh"/>, each of which must be empty; each is disposed when its cases are
    /// done.
    /// </summary>
    /// <returns>How many cases were replayed.</returns>
    /// <exception cref="StoreContractException">At the first case the store answers differently from the SDK's.</exception>
    public static async Task<int> RunAsync(string fixture, Func<IStore> fresh)
    {
        ArgumentNullException.ThrowIfNull(fresh);
        JsObject fix = Json.ParseObject(fixture);
        int cases = 0;
        foreach (JsObject script in Objects(fix.Get("prune")))
        {
            string name = Convert.ToString(script.Get("name"), System.Globalization.CultureInfo.InvariantCulture) ?? "";
            IStore store = fresh();
            await Must("init", () => store.InitAsync()).ConfigureAwait(false);
            foreach (JsObject ev in Objects(script.Get("events")))
            {
                if (ev.Get("insert") is List<object?> inserts)
                {
                    foreach (var r in inserts)
                    {
                        Run run = Run.FromValue(r);
                        await Must(name + ": insertRun", () => store.InsertRunAsync(run)).ConfigureAwait(false);
                    }
                    continue;
                }
                long before = Number(ev, "prune");
                Eq(name + ": pruned", await Get(name + ": prune", () => store.PruneAsync(before)).ConfigureAwait(false), Number(ev, "pruned"));
                foreach (var e in Field(ev, "remaining"))
                {
                    var want = new List<string>();
                    if (e.Value is List<object?> list)
                    {
                        foreach (var id in list)
                        {
                            want.Add(Convert.ToString(id, System.Globalization.CultureInfo.InvariantCulture) ?? "");
                        }
                    }
                    string job = e.Key;
                    EqList(name + ": " + job + " kept", Ids(await Get("listRuns", () => store.ListRunsAsync(job, 100)).ConfigureAwait(false)), [.. want]);
                }
                cases++;
            }
            await CloseAsync(store).ConfigureAwait(false);
        }

        IStore states = fresh();
        var cas = Capable<ICompareAndSetStateStore>(states, "compareAndSetState");
        await Must("init", () => states.InitAsync()).ConfigureAwait(false);
        int i = 0;
        foreach (JsObject step in Objects(fix.Get("compareAndSetState")))
        {
            string what = "compareAndSetState step " + i;
            if (step.Has("cas"))
            {
                JobState st = JobState.FromValue(step.Get("cas"));
                long expected = Number(step, "expected");
                Eq(what + ": wrote", (object)await Get(what, () => cas.CompareAndSetStateAsync(st, expected)).ConfigureAwait(false), step.Get("written"));
            }
            else if (step.Has("set"))
            {
                JobState st = JobState.FromValue(step.Get("set"));
                await Must(what, () => states.SetStateAsync(st)).ConfigureAwait(false);
            }
            else
            {
                string job = Convert.ToString(step.Get("forget"), System.Globalization.CultureInfo.InvariantCulture) ?? "";
                await Must(what, () => states.DeleteJobAsync(job)).ConfigureAwait(false);
            }
            foreach (var e in Field(step, "states"))
            {
                string job = e.Key;
                SameJson(what + ", state of " + job, JsonOf(await Get(what, () => states.GetStateAsync(job)).ConfigureAwait(false)), Json.Stringify(e.Value));
            }
            cases++;
            i++;
        }
        await CloseAsync(states).ConfigureAwait(false);

        IStore runs = fresh();
        var conditional = Capable<IUpdateRunIfStore>(runs, "updateRunIf");
        await Must("init", () => runs.InitAsync()).ConfigureAwait(false);
        await Must("insertRun u1", () => runs.InsertRunAsync(Run.Running("u1", "a", 1000, "run"))).ConfigureAwait(false);
        i = 0;
        foreach (JsObject step in Objects(fix.Get("updateRunIf")))
        {
            string what = "updateRunIf step " + i;
            if (step.Has("set"))
            {
                Run r = Run.FromValue(step.Get("set"));
                await Must(what, () => runs.UpdateRunAsync(r)).ConfigureAwait(false);
            }
            else if (step.Has("insert"))
            {
                Run r = Run.FromValue(step.Get("insert"));
                string outcome;
                try
                {
                    await runs.InsertRunAsync(r).ConfigureAwait(false);
                    outcome = "inserted";
                }
                catch (Exception)
                {
                    outcome = "refused";
                }
                Eq(what, (object)outcome, step.Get("outcome"));
            }
            else
            {
                var from = Statuses(step.Get("from"));
                Run r = Run.FromValue(step.Get("run"));
                Eq(what + ": wrote", (object)await Get(what, () => conditional.UpdateRunIfAsync(r, from)).ConfigureAwait(false), step.Get("outcome"));
            }
            SameJson(what, JsonOf(await Get(what, () => runs.GetRunAsync("u1")).ConfigureAwait(false)), Json.Stringify(step.Get("stored")));
            cases++;
            i++;
        }
        await CloseAsync(runs).ConfigureAwait(false);
        cases += await NulAsync(fix, fresh).ConfigureAwait(false);
        if (cases == 0)
        {
            throw new StoreContractException("no cases replayed");
        }
        return cases;
    }

    // The nul steps: text is written without U+0000, which Postgres refuses (a run's trigger,
    // output, error and metric names, and every key and string of a definition and a state).
    private static async Task<int> NulAsync(JsObject fix, Func<IStore> fresh)
    {
        IStore store = fresh();
        await Must("init", () => store.InitAsync()).ConfigureAwait(false);
        int cases = 0;
        foreach (JsObject step in Objects(fix.Get("nul")))
        {
            string what = "nul step " + cases;
            string want = Json.Stringify(step.Get("stored"));
            if (step.Has("upsertJob"))
            {
                Definition d = Definition.Of(Field(step, "upsertJob"));
                long now = Number(step, "now");
                await Must(what, () => store.UpsertJobAsync(d, now)).ConfigureAwait(false);
                StoredJob? j = await Get(what, () => store.GetJobAsync("nul")).ConfigureAwait(false);
                string got = j == null
                    ? "null"
                    : new JsObject()
                        .Set("name", j.Name)
                        .Set("definition", Json.Parse(j.Definition.ToJson()))
                        .Set("createdAt", j.CreatedAt)
                        .Set("updatedAt", j.UpdatedAt)
                        .ToJson();
                SameJson(what, got, want);
            }
            else if (step.Has("setState") || step.Has("compareAndSetState"))
            {
                if (step.Has("setState"))
                {
                    JobState st = JobState.FromValue(step.Get("setState"));
                    await Must(what, () => store.SetStateAsync(st)).ConfigureAwait(false);
                }
                else
                {
                    var cas = Capable<ICompareAndSetStateStore>(store, "compareAndSetState");
                    JobState st = JobState.FromValue(step.Get("compareAndSetState"));
                    long expected = Number(step, "expected");
                    Eq(what + ": wrote", (object)await Get(what, () => cas.CompareAndSetStateAsync(st, expected)).ConfigureAwait(false), step.Get("written"));
                }
                SameJson(what, JsonOf(await Get(what, () => store.GetStateAsync("nul")).ConfigureAwait(false)), want);
            }
            else
            {
                if (step.Has("insertRun"))
                {
                    Run r = Run.FromValue(step.Get("insertRun"));
                    await Must(what, () => store.InsertRunAsync(r)).ConfigureAwait(false);
                }
                else if (step.Has("updateRun"))
                {
                    Run r = Run.FromValue(step.Get("updateRun"));
                    await Must(what, () => store.UpdateRunAsync(r)).ConfigureAwait(false);
                }
                else
                {
                    var conditional = Capable<IUpdateRunIfStore>(store, "updateRunIf");
                    Run r = Run.FromValue(step.Get("updateRunIf"));
                    var from = Statuses(step.Get("from"));
                    Eq(what + ": wrote", (object)await Get(what, () => conditional.UpdateRunIfAsync(r, from)).ConfigureAwait(false), step.Get("written"));
                }
                SameJson(what, JsonOf(await Get(what, () => store.GetRunAsync("n1")).ConfigureAwait(false)), want);
            }
            cases++;
        }
        await CloseAsync(store).ConfigureAwait(false);
        if (cases == 0)
        {
            throw new StoreContractException("no nul cases");
        }
        return cases;
    }

    /// <summary>
    /// Replays the <c>foreignVersion</c> cases against <paramref name="store"/>, which holds its
    /// states as JSON text: for each, job <c>v</c> is deleted, <paramref name="writeRaw"/> puts the
    /// case's state text in the state table as it is (its version <c>1.5</c>, <c>"x"</c> or
    /// <c>2.0</c>), and each compare-and-set step must be refused or written as the SDK's was. The
    /// store is not disposed.
    /// </summary>
    /// <returns>How many cases were replayed.</returns>
    /// <exception cref="StoreContractException">At the first step the store answers differently from the SDK's.</exception>
    public static async Task<int> ForeignVersionsAsync(string fixture, IStore store, Func<string, Task> writeRaw)
    {
        ArgumentNullException.ThrowIfNull(store);
        ArgumentNullException.ThrowIfNull(writeRaw);
        JsObject fix = Json.ParseObject(fixture);
        var cas = Capable<ICompareAndSetStateStore>(store, "compareAndSetState");
        await Must("init", () => store.InitAsync()).ConfigureAwait(false);
        int cases = 0;
        foreach (JsObject c in Objects(fix.Get("foreignVersion")))
        {
            string stored = Convert.ToString(c.Get("stored"), System.Globalization.CultureInfo.InvariantCulture) ?? "";
            await Must("deleteJob v", () => store.DeleteJobAsync("v")).ConfigureAwait(false);
            await Must("writing " + stored, () => writeRaw(stored)).ConfigureAwait(false);
            foreach (JsObject step in Objects(c.Get("steps")))
            {
                JobState st = JobState.FromValue(step.Get("cas"));
                long expected = Number(step, "expected");
                string what = stored + " expecting " + expected.ToString(System.Globalization.CultureInfo.InvariantCulture);
                Eq(what + ": wrote", (object)await Get(what, () => cas.CompareAndSetStateAsync(st, expected)).ConfigureAwait(false), step.Get("written"));
                if (step.Has("state"))
                {
                    SameJson(what, JsonOf(await Get(what, () => store.GetStateAsync("v")).ConfigureAwait(false)), Json.Stringify(step.Get("state")));
                }
            }
            cases++;
        }
        if (cases == 0)
        {
            throw new StoreContractException("no foreignVersion cases");
        }
        return cases;
    }
}
