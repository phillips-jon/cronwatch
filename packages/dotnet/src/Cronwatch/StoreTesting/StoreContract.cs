using System;
using System.Threading.Tasks;
using static Cronwatch.StoreTesting.Checks;

namespace Cronwatch.StoreTesting;

/// <summary>
/// The test every CronWatch store passes: the SDK's <c>store-conformance.ts</c>, step for step.
/// The memory store and <see cref="SqlStore"/> pass it; run it against a store of the app's own
/// from any test framework:
/// <code>
/// [Fact]
/// public Task MyStorePassesTheContract() => StoreContract.RunAsync(new MyStore(EmptyDatabase()));
/// </code>
/// It throws a <see cref="StoreContractException"/> at the first thing the store gets wrong, and
/// depends on no test framework. See <see cref="StoreReplay"/> for the SDK's recorded cases.
/// </summary>
public static class StoreContract
{
    /// <summary>
    /// A run as the contract writes them: finished ten milliseconds after it started unless it is
    /// running, with one metric, <c>n</c>, of 1.
    /// </summary>
    public static Run NewRun(string id, string job, RunStatus status, long startedAt)
    {
        bool finished = status != RunStatus.Running;
        return new Run
        {
            Id = id,
            Job = job,
            Status = status,
            StartedAt = startedAt,
            FinishedAt = finished ? startedAt + 10 : null,
            DurationMs = finished ? 10 : null,
            Metrics = Metrics.Of([new("n", 1)]),
            Trigger = "run",
        };
    }

    private static Run With(Run r, string? error, string? output, Metrics? metrics) =>
        r with { Error = error, Output = output, Metrics = metrics ?? r.Metrics };

    private static JobState State(string text) => JobState.FromJson(text);

    /// <summary>
    /// Runs the contract against <paramref name="store"/>, which must be empty, and disposes it at
    /// the end when it is disposable.
    /// </summary>
    /// <exception cref="StoreContractException">At the first thing the store gets wrong.</exception>
    public static async Task RunAsync(IStore store)
    {
        ArgumentNullException.ThrowIfNull(store);
        await Must("init", () => store.InitAsync()).ConfigureAwait(false);
        Eq("no job yet", await Get("getJob", () => store.GetJobAsync("a")).ConfigureAwait(false), null);
        await Must("upsertJob", () => store.UpsertJobAsync(Definition.FromJson("{\"name\":\"a\",\"schedule\":\"every 5m\"}"), 100)).ConfigureAwait(false);
        await Must("upsertJob again", () => store.UpsertJobAsync(Definition.FromJson("{\"name\":\"a\",\"schedule\":\"every 10m\",\"tags\":[\"x\"]}"), 200)).ConfigureAwait(false);
        foreach (string name in new[] { "b", "B", "_c" })
        {
            await Must("upsertJob " + name, () => store.UpsertJobAsync(Definition.FromJson("{\"name\":\"" + name + "\"}"), 300)).ConfigureAwait(false);
        }
        StoredJob a = await Get("getJob", () => store.GetJobAsync("a")).ConfigureAwait(false)
            ?? throw new StoreContractException("job a was not stored");
        Eq("createdAt survives upsert", a.CreatedAt, 100L);
        Eq("updatedAt", a.UpdatedAt, 200L);
        SameJson("definition", a.Definition.ToJson(), "{\"name\":\"a\",\"schedule\":\"every 10m\",\"tags\":[\"x\"]}");
        var jobs = await Get("listJobs", () => store.ListJobsAsync()).ConfigureAwait(false);
        EqList("byte order, not locale", System.Linq.Enumerable.Select(jobs, j => j.Name), "B", "_c", "a", "b");

        foreach (Run r in new[]
        {
            NewRun("r1", "a", RunStatus.Ok, 1000),
            NewRun("r2", "a", RunStatus.Failed, 2000),
            NewRun("r3", "a", RunStatus.Running, 3000),
            NewRun("r4", "b", RunStatus.Ok, 1500),
            NewRun("rb", "B", RunStatus.Running, 2000),
            NewRun("rc", "_c", RunStatus.Running, 2000),
        })
        {
            await Must("insertRun " + r.Id, () => store.InsertRunAsync(r)).ConfigureAwait(false);
        }
        EqList("newest first", Ids(await Get("listRuns", () => store.ListRunsAsync("a", 10)).ConfigureAwait(false)), "r3", "r2", "r1");
        EqList("limit", Ids(await Get("listRuns", () => store.ListRunsAsync("a", 2)).ConfigureAwait(false)), "r3", "r2");
        Run? last = await Get("lastRun", () => store.LastRunAsync("a")).ConfigureAwait(false);
        Eq("last run", last?.Id, "r3");
        Eq("no last run", await Get("lastRun", () => store.LastRunAsync("none")).ConfigureAwait(false), null);
        EqList("oldest first, then insertion order", Ids(await Get("runningRuns", () => store.RunningRunsAsync()).ConfigureAwait(false)), "rb", "rc", "r3");
        Run r1 = await Get("getRun", () => store.GetRunAsync("r1")).ConfigureAwait(false)
            ?? throw new StoreContractException("run r1 was not stored");
        SameJson("metrics", r1.Metrics.ToJson(), "{\"n\":1}");
        Eq("durationMs", r1.DurationMs, 10L);

        Run updated = With(NewRun("r3", "a", RunStatus.Ok, 3000), null, "line1\nline2", Metrics.Of([new("cost", 0.25)]));
        await Must("updateRun", () => store.UpdateRunAsync(updated)).ConfigureAwait(false);
        Run r3 = await Get("getRun", () => store.GetRunAsync("r3")).ConfigureAwait(false)
            ?? throw new StoreContractException("run r3 was lost");
        Eq("status", r3.Status, RunStatus.Ok);
        Eq("output", r3.Output, "line1\nline2");
        SameJson("updated metrics", r3.Metrics.ToJson(), "{\"cost\":0.25}");
        EqList("running after update", Ids(await Get("runningRuns", () => store.RunningRunsAsync()).ConfigureAwait(false)), "rb", "rc");

        bool refused = false;
        try
        {
            await store.InsertRunAsync(NewRun("r3", "a", RunStatus.Running, 3000)).ConfigureAwait(false);
        }
        catch (Exception)
        {
            refused = true;
        }
        Eq("an id already recorded is refused", refused, true);
        await Must("upsertJob q", () => store.UpsertJobAsync(Definition.FromJson("{\"name\":\"q\"}"), 300)).ConfigureAwait(false);
        await Must("insertRun rx", () => store.InsertRunAsync(NewRun("rx", "q", RunStatus.Running, 2500))).ConfigureAwait(false);

        // updateRunIf writes only over a row whose status is one of those given, and says whether
        // it did.
        if (store is IConditionalRunStore conditional)
        {
            RunStatus[] running = [RunStatus.Running];
            RunStatus[] both = [RunStatus.Running, RunStatus.Timeout];
            Run first = With(NewRun("rx", "q", RunStatus.Failed, 2500), "first", null, null);
            Eq("first finish", await Get("updateRunIf", () => conditional.UpdateRunIfAsync(first, running)).ConfigureAwait(false), true);
            Run second = With(NewRun("rx", "q", RunStatus.Ok, 2500), null, "second", null);
            Eq("a second finish over the first is refused", await Get("updateRunIf", () => conditional.UpdateRunIfAsync(second, running)).ConfigureAwait(false), false);
            Run? kept = await Get("getRun", () => store.GetRunAsync("rx")).ConfigureAwait(false);
            Eq("first error kept", kept?.Error, "first");
            Run late = With(NewRun("rx", "q", RunStatus.Ok, 2500), null, "late", null);
            Eq("not over failed", await Get("updateRunIf", () => conditional.UpdateRunIfAsync(late, both)).ConfigureAwait(false), false);
            await Must("updateRun", () => store.UpdateRunAsync(With(NewRun("rx", "q", RunStatus.Timeout, 2500), "stuck", null, null))).ConfigureAwait(false);
            Run lateAgain = With(NewRun("rx", "q", RunStatus.Ok, 2500), null, "late", Metrics.Of([new("m", 2)]));
            Eq("any of the statuses given", await Get("updateRunIf", () => conditional.UpdateRunIfAsync(lateAgain, both)).ConfigureAwait(false), true);
            SameJson(
                "late finish",
                JsonOf(await Get("getRun", () => store.GetRunAsync("rx")).ConfigureAwait(false)),
                "{\"id\":\"rx\",\"job\":\"q\",\"status\":\"ok\",\"startedAt\":2500,\"finishedAt\":2510,\"durationMs\":10,\"error\":null,\"output\":\"late\",\"metrics\":{\"m\":2},\"trigger\":\"run\"}");
            Run missing = NewRun("missing", "q", RunStatus.Ok, 1);
            Eq("a run that is not there is not written", await Get("updateRunIf", () => conditional.UpdateRunIfAsync(missing, running)).ConfigureAwait(false), false);
            Eq("still missing", await Get("getRun", () => store.GetRunAsync("missing")).ConfigureAwait(false), null);
            Run failed = NewRun("rx", "q", RunStatus.Failed, 2500);
            Eq("no statuses, no write", await Get("updateRunIf", () => conditional.UpdateRunIfAsync(failed, Array.Empty<RunStatus>())).ConfigureAwait(false), false);
            Run? stillOk = await Get("getRun", () => store.GetRunAsync("rx")).ConfigureAwait(false);
            Eq("still ok", stillOk?.Status, RunStatus.Ok);
        }

        // deleteRunIf, for a store that has it, takes back only a run still of the job and in the
        // status given.
        await Must("insertRun rd", () => store.InsertRunAsync(NewRun("rd", "q", RunStatus.Running, 2600))).ConfigureAwait(false);
        if (store is IRunDeletingStore deleting)
        {
            Eq("not another job's", await Get("deleteRunIf", () => deleting.DeleteRunIfAsync("rd", "a", RunStatus.Running)).ConfigureAwait(false), false);
            Eq("not in another status", await Get("deleteRunIf", () => deleting.DeleteRunIfAsync("rd", "q", RunStatus.Ok)).ConfigureAwait(false), false);
            Eq("not a finished run", await Get("deleteRunIf", () => deleting.DeleteRunIfAsync("rx", "q", RunStatus.Running)).ConfigureAwait(false), false);
            Eq("taken back", await Get("deleteRunIf", () => deleting.DeleteRunIfAsync("rd", "q", RunStatus.Running)).ConfigureAwait(false), true);
            Eq("gone", await Get("getRun", () => store.GetRunAsync("rd")).ConfigureAwait(false), null);
            Eq("only once", await Get("deleteRunIf", () => deleting.DeleteRunIfAsync("rd", "q", RunStatus.Running)).ConfigureAwait(false), false);
            Eq("the finished run kept", await Get("getRun", () => store.GetRunAsync("rx")).ConfigureAwait(false) != null, true);
        }
        await Must("deleteJob q", () => store.DeleteJobAsync("q")).ConfigureAwait(false);

        // Forgetting a job while one of its runs is in flight: the run finishing later changes
        // nothing.
        await Must("deleteJob B", () => store.DeleteJobAsync("B")).ConfigureAwait(false);
        await Must("updateRun", () => store.UpdateRunAsync(With(NewRun("rb", "B", RunStatus.Ok, 2000), null, "late", null))).ConfigureAwait(false);
        Eq("forgotten run stays gone", await Get("getRun", () => store.GetRunAsync("rb")).ConfigureAwait(false), null);
        EqList("no runs of a forgotten job", Ids(await Get("listRuns", () => store.ListRunsAsync("B", 10)).ConfigureAwait(false)));
        EqList("running after forgetting", Ids(await Get("runningRuns", () => store.RunningRunsAsync()).ConfigureAwait(false)), "rc");
        await Must("deleteJob _c", () => store.DeleteJobAsync("_c")).ConfigureAwait(false);

        Eq("no state yet", await Get("getState", () => store.GetStateAsync("a")).ConfigureAwait(false), null);
        await Must("setState", () => store.SetStateAsync(State("{\"job\":\"a\",\"open\":{\"failed\":5},\"consecutiveFailures\":2,\"silencedUntil\":null,\"lastAlertAt\":6}"))).ConfigureAwait(false);
        const string plain = "{\"job\":\"a\",\"open\":{},\"consecutiveFailures\":0,\"silencedUntil\":99,\"lastAlertAt\":6}";
        await Must("setState", () => store.SetStateAsync(State(plain))).ConfigureAwait(false);
        SameJson("state", JsonOf(await Get("getState", () => store.GetStateAsync("a")).ConfigureAwait(false)), plain);
        const string full = "{\"job\":\"a\",\"open\":{\"stuck\":7},\"consecutiveFailures\":1,\"silencedUntil\":null,"
            + "\"lastAlertAt\":6,\"pendingRecovery\":[\"missed\"],\"undelivered\":[{\"type\":\"failed\","
            + "\"run\":null,\"details\":{\"consecutiveFailures\":1,\"threshold\":1},\"job\":\"a\","
            + "\"definition\":{\"name\":\"a\"},\"title\":\"a failed\",\"message\":\"boom\",\"at\":7,"
            + "\"triage\":null}]}";
        await Must("setState", () => store.SetStateAsync(State(full))).ConfigureAwait(false);
        SameJson("pendingRecovery and undelivered round-trip", JsonOf(await Get("getState", () => store.GetStateAsync("a")).ConfigureAwait(false)), full);
        await Must("setState", () => store.SetStateAsync(State(plain))).ConfigureAwait(false);

        // compareAndSetState writes only over the version it was told to expect.
        if (store is IStateCasStore cas)
        {
            await CasIs(cas, "no row matches only version 0", V(2, 0), 1, false).ConfigureAwait(false);
            Eq("nothing written", await Get("getState", () => store.GetStateAsync("v")).ConfigureAwait(false), null);
            await CasIs(cas, "no row counts as version 0", V(1, 0), 0, true).ConfigureAwait(false);
            await CasIs(cas, "a write from a stale read is refused", V(1, 9), 0, false).ConfigureAwait(false);
            await CasIs(cas, "the version read", V(2, 1), 1, true).ConfigureAwait(false);
            await CasIs(cas, "an older version", V(3, 0), 1, false).ConfigureAwait(false);
            SameJson("state after writes", JsonOf(await Get("getState", () => store.GetStateAsync("v")).ConfigureAwait(false)), V(2, 1).ToJson());
            await Must("setState", () => store.SetStateAsync(State("{\"job\":\"w\",\"open\":{},\"consecutiveFailures\":3,\"silencedUntil\":null,\"lastAlertAt\":null}"))).ConfigureAwait(false);
            JobState w1 = State("{\"job\":\"w\",\"open\":{},\"consecutiveFailures\":0,\"silencedUntil\":null,\"lastAlertAt\":null,\"version\":1}");
            await CasIs(cas, "state written before versions counts as 0", w1, 1, false).ConfigureAwait(false);
            await CasIs(cas, "from 0", w1, 0, true).ConfigureAwait(false);
            JobState? w = await Get("getState", () => store.GetStateAsync("w")).ConfigureAwait(false);
            Eq("version", w?.Version, 1L);
            await Must("deleteJob v", () => store.DeleteJobAsync("v")).ConfigureAwait(false);
            await CasIs(cas, "a forgotten job's state is not written back", V(3, 0), 2, false).ConfigureAwait(false);
            Eq("gone", await Get("getState", () => store.GetStateAsync("v")).ConfigureAwait(false), null);
            await Must("deleteJob w", () => store.DeleteJobAsync("w")).ConfigureAwait(false);
        }

        await Must("insertRun r5", () => store.InsertRunAsync(NewRun("r5", "a", RunStatus.Running, 500))).ConfigureAwait(false);
        Eq("r1 and r2 pruned; running r5 kept, and b's r4 kept as b's newest run", await Get("prune", () => store.PruneAsync(2500)).ConfigureAwait(false), 2L);
        EqList("a after prune", Ids(await Get("listRuns", () => store.ListRunsAsync("a", 10)).ConfigureAwait(false)), "r3", "r5");
        EqList("b after prune", Ids(await Get("listRuns", () => store.ListRunsAsync("b", 10)).ConfigureAwait(false)), "r4");
        Eq("however old, each job keeps its newest run, and running runs stay", await Get("prune", () => store.PruneAsync(1_000_000)).ConfigureAwait(false), 0L);

        await Must("deleteJob a", () => store.DeleteJobAsync("a")).ConfigureAwait(false);
        Eq("job deleted", await Get("getJob", () => store.GetJobAsync("a")).ConfigureAwait(false), null);
        EqList("runs deleted", Ids(await Get("listRuns", () => store.ListRunsAsync("a", 10)).ConfigureAwait(false)));
        Eq("state deleted", await Get("getState", () => store.GetStateAsync("a")).ConfigureAwait(false), null);
        StoredJob? b = await Get("getJob", () => store.GetJobAsync("b")).ConfigureAwait(false);
        Eq("b kept", b?.Name, "b");
        if (store is IAsyncDisposable disposable)
        {
            await Must("dispose", async () => await disposable.DisposeAsync().ConfigureAwait(false)).ConfigureAwait(false);
        }
    }

    private static JobState V(long version, long failures) => State(
        "{\"job\":\"v\",\"open\":{},\"consecutiveFailures\":" + failures.ToString(System.Globalization.CultureInfo.InvariantCulture)
        + ",\"silencedUntil\":null,\"lastAlertAt\":null,\"version\":" + version.ToString(System.Globalization.CultureInfo.InvariantCulture) + "}");

    private static async Task CasIs(IStateCasStore store, string what, JobState st, long expected, bool want) =>
        Eq(what, await Get(what, () => store.CompareAndSetStateAsync(st, expected)).ConfigureAwait(false), want);
}
