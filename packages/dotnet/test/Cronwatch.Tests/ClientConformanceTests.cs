using System;
using System.Collections.Generic;
using System.Linq;
using System.Threading.Tasks;
using Xunit;
using static Cronwatch.Tests.Support;

namespace Cronwatch.Tests;

/// <summary>
/// Replays conformance/client.json, the client driven through its public API on a fixed clock:
/// the run ids a run's start, <c>ResumeAsync</c> and <c>RecordRunAsync</c> take
/// (<c>runIds</c>), and stored data a newer release wrote kept through a check, a silence, an
/// unsilence, a summary and a run (<c>unknownFields</c>), over the memory store, SQLite, and
/// Postgres when <c>CRONWATCH_TEST_PG</c> is set.
/// </summary>
public class ClientConformanceTests
{
    private static readonly JsObject Fixture = Fixtures.Load("client");

    [Fact]
    public void Every_section_is_replayed() => DurationConformanceTests.Known(Fixture, "runIds", "unknownFields");

    [Fact]
    public async Task Run_ids_are_held_as_the_sdk_holds_them()
    {
        var failures = new Fixtures.Failures();
        var cases = Fixtures.Objects(Fixture, "runIds");
        foreach (string method in new[] { "start", "resume", "recordRun" })
        {
            await using var m = Make(clock: Clock(T0));
            Job job = m.Cw.Job("j");
            foreach (JsObject c in cases.Where(c => Fixtures.String(c, "method") == method))
            {
                string id = Fixtures.String(c, "id")!;
                var got = new JsObject().Set("method", method).Set("id", id);
                try
                {
                    switch (method)
                    {
                        case "start":
                            await (await job.StartAsync(new StartOptions { Id = id })).FinishAsync();
                            break;
                        case "resume":
                            await job.ResumeAsync(id);
                            break;
                        default:
                            await m.Cw.RecordRunAsync(new Run
                            {
                                Id = id,
                                Job = "j",
                                Status = RunStatus.Ok,
                                StartedAt = T0 - 1000,
                                FinishedAt = T0,
                                DurationMs = 1000,
                                Trigger = "run",
                            });
                            break;
                    }
                    got.Set("ok", true);
                }
                catch (CronwatchException e)
                {
                    got.Set("error", e.Message);
                }
                failures.Same("runIds " + method + " " + Json.Quote(id), got, c);
            }
            Assert.Empty(m.Errors.Entries);
        }
        failures.Check("client");
        Assert.Equal(36, failures.Compared);
    }

    [Fact]
    public Task Unknown_fields_are_kept_over_the_memory_store() => ReplayUnknownFieldsAsync(new MemoryStore());

    [Fact]
    public async Task Unknown_fields_are_kept_over_sqlite()
    {
        using var dir = new TempDir();
        await using var store = SqlStore.Sqlite(StoreTests.Sqlite(dir.File("cw.db")));
        await ReplayUnknownFieldsAsync(store);
    }

    [Fact]
    public async Task Unknown_fields_are_kept_over_postgres()
    {
        string url = Databases.Require(Databases.PgVariable);
        await using var source = Databases.Postgres(url);
        string prefix = Databases.Prefix("unknown");
        try
        {
            await ReplayUnknownFieldsAsync(SqlStore.Postgres(source).WithPrefix(prefix));
        }
        finally
        {
            await Databases.ExecAsync(source, "DROP TABLE IF EXISTS " + prefix + "jobs, " + prefix + "runs, " + prefix + "state");
        }
    }

    private static async Task ReplayUnknownFieldsAsync(IStore store)
    {
        JsObject f = Fixtures.Object(Fixture, "unknownFields");
        JsObject seed = Fixtures.Object(f, "seed");
        await store.InitAsync();
        await store.UpsertJobAsync(Definition.Of(Fixtures.Object(seed, "definition")), Fixtures.Integer(seed, "createdAt"));
        await store.SetStateAsync(JobState.FromValue(seed.Get("state")));
        foreach (object? run in Fixtures.List(seed, "runs"))
        {
            await store.InsertRunAsync(Run.FromValue(run));
        }

        await using var m = Make(store: store, clock: Clock(T0));
        var failures = new Fixtures.Failures();
        int sent = 0;
        foreach (JsObject step in Fixtures.Objects(f, "steps"))
        {
            string op = Fixtures.String(step, "op")!;
            switch (op)
            {
                case "check":
                    m.Clock.Set(Fixtures.Integer(step, "at"));
                    await m.Cw.CheckAsync();
                    break;
                case "silence":
                    m.Clock.Set(Fixtures.Integer(step, "at"));
                    await m.Cw.SilenceAsync("keep", Fixtures.String(step, "for")!);
                    break;
                case "unsilence":
                    m.Clock.Set(Fixtures.Integer(step, "at"));
                    await m.Cw.UnsilenceAsync("keep");
                    break;
                case "summary":
                    m.Clock.Set(Fixtures.Integer(step, "at"));
                    JobSummary summary = (await m.Cw.JobSummaryAsync("keep"))!;
                    failures.Same(op + " summary", Canonical(summary.ToValue(), sortOpen: true), Canonical(step.Get("summary"), sortOpen: true));
                    break;
                case "declareAndRun":
                    var declared = Fixtures.Object(step, "declared");
                    Assert.Equal("{\"timeout\":\"5m\",\"tags\":[\"a\"]}", declared.ToJson());
                    Job job = m.Cw.Job("keep", new JobOptions { Timeout = "5m", Tags = ["a"] });
                    m.Clock.Set(Fixtures.Integer(step, "startedAt"));
                    RunHandle handle = await job.StartAsync(new StartOptions { Id = Fixtures.String(step, "id")! });
                    m.Clock.Set(Fixtures.Integer(step, "finishedAt"));
                    await handle.FinishAsync(Fixtures.String(step, "output"));
                    break;
                default:
                    failures.Fail("unknownFields: an op this replay does not know: " + op);
                    continue;
            }
            JsObject expect = Fixtures.Object(step, "expect");
            StoredJob? stored = await store.GetJobAsync("keep");
            JobState? state = await store.GetStateAsync("keep");
            var runs = await store.ListRunsAsync("keep", 10);
            var alerts = m.Alerts.List().Skip(sent).Select(a => (object?)a.ToValue()).ToList();
            sent += alerts.Count;
            object? job1 = stored == null ? null : new JsObject()
                .Set("name", stored.Name)
                .Set("definition", stored.Definition.ToObject())
                .Set("createdAt", stored.CreatedAt)
                .Set("updatedAt", stored.UpdatedAt);
            failures.Same(op + " job", Canonical(job1), Canonical(expect.Get("job")));
            failures.Same(op + " state", Canonical(state?.ToValue()), Canonical(expect.Get("state")));
            failures.Same(op + " runs", Canonical(runs.Select(r => (object?)r.ToValue()).ToList()), Canonical(expect.Get("runs")));
            failures.Same(op + " alerts", Canonical(alerts), Canonical(expect.Get("alerts")));
            failures.Same(op + " errors", m.Errors.Entries.Select(e => (object?)(e.Where + ": " + e.Error.Message)).ToList(), expect.Get("errors"));
        }
        failures.Check("client");
        Assert.Equal(26, failures.Compared);
    }

    /// <summary>
    /// The value with every object's keys sorted, so two are compared as JSON values whatever
    /// order a store keeps; with <paramref name="sortOpen"/> a summary's <c>open</c> is sorted
    /// too, compared as a set.
    /// </summary>
    private static object? Canonical(object? v, bool sortOpen = false)
    {
        switch (v)
        {
            case JsObject o:
                var output = new JsObject();
                foreach (string key in o.Keys.OrderBy(k => k, StringComparer.Ordinal))
                {
                    object? value = Canonical(o.Get(key));
                    if (sortOpen && key == "open" && value is List<object?> list)
                    {
                        value = list.OrderBy(x => x as string, StringComparer.Ordinal).ToList();
                    }
                    output.Set(key, value);
                }
                return output;
            case List<object?> list:
                return list.Select(x => Canonical(x)).ToList();
            default:
                return v;
        }
    }
}
