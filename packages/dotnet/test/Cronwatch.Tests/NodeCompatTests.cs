using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Text;
using System.Threading.Tasks;
using Microsoft.Data.Sqlite;
using Xunit;

namespace Cronwatch.Tests;

/// <summary>
/// A Node process and a .NET process sharing one SQLite file: the SDK's store (from the built
/// packages/sdk/dist) and <see cref="SqlStore"/> replay the same store calls
/// (shared_store.json, the Ruby, Python, Go, Rust, and Java ports' fixture), and each must read
/// what the other wrote exactly as it reads its own, down to the bytes and SQLite type of every
/// column; the tables are the same whoever makes them; and the two take turns on one job's state
/// version. Needs node, the SDK built, and its SQLite driver installed (<c>npm ci &amp;&amp; npm run
/// build</c> at the repository root); skipped, with the reason, without them.
/// </summary>
public class NodeCompatTests
{
    private static readonly string Here = Path.Combine(Fixtures.Repo, "packages", "dotnet", "test", "Cronwatch.Tests");
    private static readonly string Script = Path.Combine(Here, "node_store.mjs");
    private static readonly string FixturePath = Path.Combine(Here, "shared_store.json");
    private static readonly string Dist = Path.Combine(Fixtures.Repo, "packages", "sdk", "dist");

    private static readonly JsObject Fixture = Json.ParseObject(File.ReadAllText(FixturePath, Encoding.UTF8));

    /// <summary>Why the test cannot run here, or null when it can.</summary>
    private static async Task SkipUnlessNodeAsync()
    {
        if (!File.Exists(Path.Combine(Dist, "sqlite.js")))
        {
            Assert.Skip("Node compatibility skipped: packages/sdk/dist is not built (npm ci && npm run build at the repository root)");
        }
        if (!Directory.Exists(Path.Combine(Fixtures.Repo, "node_modules", "better-sqlite3")))
        {
            Assert.Skip("Node compatibility skipped: better-sqlite3 is not installed (npm ci at the repository root)");
        }
        var version = await CronerParityTests.RunAsync("node", "--version");
        if (version is not { Code: 0 })
        {
            Assert.Skip("Node compatibility skipped: node is not installed");
        }
    }

    /// <summary>Runs node_store.mjs and answers what it printed, line endings as \n.</summary>
    private static async Task<string> Node(string action, string file, string prefix, params string[] args)
    {
        var result = await CronerParityTests.RunAsync("node", [Script, Dist, action, file, prefix, .. args]);
        Assert.NotNull(result);
        Assert.True(result.Value.Code == 0, "node " + action + ": " + result.Value.Err);
        return result.Value.Out.Replace("\r\n", "\n", StringComparison.Ordinal);
    }

    private static SqlStore Store(string file, string prefix) => SqlStore.Sqlite(StoreTests.Sqlite(file)).WithPrefix(prefix);

    private static List<string> ReadList(string key) =>
        Fixtures.Object(Fixture, "read").Get(key) is List<object?> list ? list.Select(x => (string)x!).ToList() : [];

    /// <summary>Replays the fixture's store calls, as node_store.mjs <c>write</c> does.</summary>
    private static async Task<string> DotnetWrite(SqlStore store)
    {
        await store.InitAsync();
        var pruned = new List<object?>();
        foreach (JsObject step in Fixtures.Objects(Fixture, "ops"))
        {
            switch (Fixtures.String(step, "op"))
            {
                case "upsertJob":
                    await store.UpsertJobAsync(Definition.Of(Fixtures.Object(step, "definition")), Fixtures.Integer(step, "now"));
                    break;
                case "insertRun":
                    await store.InsertRunAsync(Run.FromValue(step.Get("run")));
                    break;
                case "updateRun":
                    await store.UpdateRunAsync(Run.FromValue(step.Get("run")));
                    break;
                case "setState":
                    await store.SetStateAsync(JobState.FromValue(step.Get("state")));
                    break;
                case "deleteJob":
                    await store.DeleteJobAsync(Fixtures.String(step, "name")!);
                    break;
                case "prune":
                    pruned.Add(await store.PruneAsync(Fixtures.Integer(step, "before")));
                    break;
                default:
                    throw new InvalidOperationException("unknown op " + Fixtures.String(step, "op"));
            }
        }
        return new JsObject().Set("pruned", pruned).ToJson();
    }

    private static JsObject? Stored(StoredJob? j) => j == null
        ? null
        : new JsObject().Set("name", j.Name).Set("definition", j.Definition.ToObject()).Set("createdAt", j.CreatedAt).Set("updatedAt", j.UpdatedAt);

    private static List<object?> Runs(IReadOnlyList<Run> runs) => runs.Select(r => (object?)r.ToValue()).ToList();

    /// <summary>What node_store.mjs <c>read</c> prints, from the .NET store, in the same key order.</summary>
    private static async Task<string> DotnetRead(SqlStore s)
    {
        var jobs = (await s.ListJobsAsync()).Select(j => (object?)Stored(j)).ToList();
        var job = new JsObject();
        var runs = new JsObject();
        var limited = new JsObject();
        var last = new JsObject();
        var state = new JsObject();
        foreach (string name in ReadList("jobs"))
        {
            job.Set(name, Stored(await s.GetJobAsync(name)));
            runs.Set(name, Runs(await s.ListRunsAsync(name, 100)));
            limited.Set(name, Runs(await s.ListRunsAsync(name, 1)));
            last.Set(name, (await s.LastRunAsync(name))?.ToValue());
            state.Set(name, (await s.GetStateAsync(name))?.ToValue());
        }
        var byId = new JsObject();
        foreach (string id in ReadList("runs"))
        {
            byId.Set(id, (await s.GetRunAsync(id))?.ToValue());
        }
        return new JsObject()
            .Set("jobs", jobs)
            .Set("job", job)
            .Set("runs", runs)
            .Set("limited", limited)
            .Set("last", last)
            .Set("state", state)
            .Set("running", Runs(await s.RunningRunsAsync()))
            .Set("run", byId)
            .ToJson();
    }

    private static async Task<List<string>> Query(string file, string sql, string? param = null)
    {
        var output = new List<string>();
        await using var c = new SqliteConnection("Data Source=" + file + ";Pooling=False");
        await c.OpenAsync();
        using var cmd = c.CreateCommand();
        cmd.CommandText = sql;
        if (param != null)
        {
            cmd.Parameters.AddWithValue("$p", param);
        }
        await using var reader = await cmd.ExecuteReaderAsync();
        while (await reader.ReadAsync())
        {
            var values = new List<string>();
            for (int i = 0; i < reader.FieldCount; i++)
            {
                values.Add(reader.IsDBNull(i) ? "NULL" : Convert.ToString(reader.GetValue(i), CultureInfo.InvariantCulture)!);
            }
            output.Add(string.Join(" | ", values));
        }
        return output;
    }

    private static string Typed(params string[] columns) => string.Join(", ", columns.Select(c => "quote(" + c + "), typeof(" + c + ")"));

    /// <summary>Every row of the three tables with each value's SQLite type, the JSON as the text held.</summary>
    private static async Task<List<string>> RawRows(string file, string p)
    {
        var output = new List<string>();
        output.AddRange(await Query(file, "SELECT " + Typed("name", "definition", "created_at", "updated_at") + " FROM " + p + "jobs ORDER BY created_at, name"));
        output.AddRange(await Query(file, "SELECT " + Typed("rowid", "id", "job", "status", "started_at", "finished_at", "duration_ms", "error", "output", "metrics", "trigger") + " FROM " + p + "runs ORDER BY rowid"));
        output.AddRange(await Query(file, "SELECT " + Typed("job", "state") + " FROM " + p + "state ORDER BY job"));
        return output;
    }

    private static async Task<List<string>> SchemaOf(string file, string p) =>
        (await Query(file, "SELECT type || '|' || name || '|' || tbl_name || '|' || coalesce(sql, '') FROM sqlite_master WHERE name LIKE $p ORDER BY name", p + "%"))
        .Select(row => row.Replace(p, "PREFIX_", StringComparison.Ordinal))
        .ToList();

    [Fact]
    public async Task Dotnet_reads_what_node_wrote()
    {
        await SkipUnlessNodeAsync();
        using var dir = new TempDir();
        string file = dir.File("shared.db");
        Assert.Equal("{\"pruned\":[1]}", await Node("write", file, "cw_", FixturePath));
        var s = Store(file, "cw_");
        await using (s)
        {
            await s.InitAsync();
            string nodeView = await Node("read", file, "cw_", FixturePath);
            Assert.DoesNotContain("never stored", nodeView, StringComparison.Ordinal);
            Assert.Equal(nodeView, await DotnetRead(s));
        }
    }

    [Fact]
    public async Task Node_reads_what_dotnet_wrote_and_the_rows_are_the_same()
    {
        await SkipUnlessNodeAsync();
        using var dir = new TempDir();
        string nodeFile = dir.File("node.db");
        string dotnetFile = dir.File("dotnet.db");
        string written = await Node("write", nodeFile, "cw_", FixturePath);
        var s = Store(dotnetFile, "cw_");
        await using (s)
        {
            Assert.Equal(written, await DotnetWrite(s));
        }
        Assert.Equal(await Node("read", nodeFile, "cw_", FixturePath), await Node("read", dotnetFile, "cw_", FixturePath));
        var dotnetRows = await RawRows(dotnetFile, "cw_");
        Assert.NotEmpty(dotnetRows);
        Assert.Equal(await RawRows(nodeFile, "cw_"), dotnetRows);
    }

    [Fact]
    public async Task The_tables_are_the_same_whoever_creates_them()
    {
        await SkipUnlessNodeAsync();
        using var dir = new TempDir();
        string file = dir.File("both.db");
        await Node("write", file, "node_", FixturePath);
        var s = Store(file, "dotnet_");
        await using (s)
        {
            await s.InitAsync();
        }
        var dotnet = await SchemaOf(file, "dotnet_");
        Assert.Equal(5, dotnet.Count);
        Assert.Equal(await SchemaOf(file, "node_"), dotnet);
    }

    private static JobState V(long version, long failures, string job) => JobState.FromJson(
        "{\"job\":\"" + job + "\",\"open\":{},\"consecutiveFailures\":" + failures.ToString(CultureInfo.InvariantCulture)
        + ",\"silencedUntil\":null,\"lastAlertAt\":null,\"version\":" + version.ToString(CultureInfo.InvariantCulture) + "}");

    private static async Task<(bool Written, string State)> NodeCas(string file, JobState state, long expected)
    {
        var o = Json.ParseObject(await Node("cas", file, "cw_", state.ToJson(), expected.ToString(CultureInfo.InvariantCulture)));
        return (o.Get("written") is true, Json.Stringify(o.Get("state")));
    }

    [Fact]
    public async Task Node_and_dotnet_take_turns_on_one_jobs_state_version()
    {
        await SkipUnlessNodeAsync();
        using var dir = new TempDir();
        string file = dir.File("versions.db");
        var s = Store(file, "cw_");
        await using (s)
        {
            await s.InitAsync();
            Assert.True(await s.CompareAndSetStateAsync(V(1, 1, "v"), 0), ".NET writes the first version");
            Assert.False((await NodeCas(file, V(1, 9, "v"), 0)).Written, "Node's write from before is refused");
            var fresh = await NodeCas(file, V(2, 2, "v"), 1);
            Assert.True(fresh.Written && fresh.State.Contains("\"version\":2", StringComparison.Ordinal), "Node's fresh write " + fresh);
            Assert.False(await s.CompareAndSetStateAsync(V(2, 7, "v"), 1), ".NET's stale write is refused");
            Assert.True(await s.CompareAndSetStateAsync(V(3, 3, "v"), 2), ".NET writes the next version");
            var stale = await NodeCas(file, V(3, 0, "v"), 2);
            Assert.False(stale.Written, "Node's stale write is refused");
            Assert.Equal((await s.GetStateAsync("v"))!.ToJson(), stale.State);
            // State written before versions existed counts as 0 for both.
            await s.SetStateAsync(JobState.FromJson("{\"job\":\"old\",\"open\":{},\"consecutiveFailures\":4,\"silencedUntil\":null,\"lastAlertAt\":null}"));
            Assert.True((await NodeCas(file, V(1, 5, "old"), 0)).Written, "Node writes over it");
            Assert.Equal(1L, (await s.GetStateAsync("old"))?.Version);
        }
    }

    /// <summary>
    /// A .NET client finishes a run of a job Node wrote and checks every job; then a Node client
    /// takes a turn on the same file; each reads the other's run and state, and the .NET client
    /// checks again with nothing to report.
    /// </summary>
    [Fact]
    public async Task Node_carries_on_from_dotnet_and_dotnet_from_node()
    {
        await SkipUnlessNodeAsync();
        using var dir = new TempDir();
        string file = dir.File("turns.db");
        await Node("write", file, "cw_", FixturePath);
        var clock = Support.Clock(1_767_606_100_000L);
        var errors = new List<string>();
        var s = Store(file, "cw_");
        await using var cw = new CronwatchClient(new CronwatchOptions
        {
            Store = s,
            Alerts = [],
            CronSecret = CronSecret.None,
            Clock = clock,
            OnError = (e, where) =>
            {
                lock (errors)
                {
                    errors.Add(where + ": " + e.Message);
                }
            },
            ProcessExitHook = false,
        });
        var job = cw.Job("every-5", new JobOptions { Schedule = "every 5m", Timeout = "2m", MaxDuration = "90s" });
        await job.RunAsync((ctx, ct) =>
        {
            ctx.Log("from dotnet");
            return Task.CompletedTask;
        });
        clock.Advance(10 * Support.Min);
        var result = await cw.CheckAsync();
        Assert.Contains(result.Jobs, j => j.Name == "nightly-report");
        Assert.Equal("from dotnet", (await s.LastRunAsync("every-5"))!.Output);
        string raw = await Node("read", file, "cw_", FixturePath);
        var last = (JsObject)((JsObject)Json.ParseObject(raw).Get("last")!).Get("every-5")!;
        Assert.Equal("from dotnet", last.Get("output"));
        Assert.Equal(raw, await DotnetRead(s));

        long now = clock.Advance(10 * Support.Min);
        string nodeRun = await Node("run", file, "cw_", now.ToString(CultureInfo.InvariantCulture));
        Assert.Contains("\"every-5\"", nodeRun, StringComparison.Ordinal);
        Assert.Equal("from node", (await s.LastRunAsync("every-5"))!.Output);
        Assert.Equal(await Node("read", file, "cw_", FixturePath), await DotnetRead(s));
        Assert.NotEmpty((await cw.CheckAsync()).Jobs);
        Assert.Empty(errors);
    }
}
