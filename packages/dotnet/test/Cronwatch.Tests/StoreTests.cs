using System.Collections.Generic;
using System.Data.Common;
using System.IO;
using System.Linq;
using System.Threading.Tasks;
using Cronwatch.StoreTesting;
using Microsoft.Data.Sqlite;
using Xunit;

#pragma warning disable CS0618 // StoreReplay and FinishOnce, deprecated, still run the port's own replay and finish-once checks

namespace Cronwatch.Tests;

public class StoreTests
{
    private static string StoreFixture => File.ReadAllText(Path.Combine(Fixtures.ConformanceDir, "store.json"));

    internal static DbDataSource Sqlite(string file) =>
        SqliteFactory.Instance.CreateDataSource("Data Source=" + file + ";Pooling=False");

    [Fact]
    public Task Memory_store_passes_the_contract() => StoreContract.RunAsync(new MemoryStore());

    [Fact]
    public async Task Memory_store_replays_store_json()
    {
        int cases = await StoreReplay.RunAsync(StoreFixture, () => new MemoryStore());
        Assert.True(cases >= 28);
        var store = new MemoryStore();
        int foreign = await StoreReplay.ForeignVersionsAsync(StoreFixture, store, text => store.SetStateAsync(JobState.FromJson(text)));
        Assert.Equal(16, foreign);
    }

    [Fact]
    public async Task Sqlite_store_passes_the_contract()
    {
        using var dir = new TempDir();
        await using var store = SqlStore.Sqlite(Sqlite(dir.File("cw.db")));
        await StoreContract.RunAsync(store);
    }

    [Fact]
    public async Task Sqlite_store_replays_store_json()
    {
        using var dir = new TempDir();
        int n = 0;
        var opened = new List<SqlStore>();
        int cases;
        try
        {
            cases = await StoreReplay.RunAsync(StoreFixture, () =>
            {
                var fresh = SqlStore.Sqlite(Sqlite(dir.File("r" + ++n + ".db")));
                opened.Add(fresh);
                return fresh;
            });
        }
        finally
        {
            // The replay disposes each store when its cases pass; one it stopped at is closed here.
            foreach (var fresh in opened)
            {
                await fresh.DisposeAsync();
            }
        }
        Assert.True(cases >= 28);
        var source = Sqlite(dir.File("foreign.db"));
        var store = SqlStore.Sqlite(source);
        await using (store)
        {
            int foreign = await StoreReplay.ForeignVersionsAsync(StoreFixture, store, async text =>
            {
                await using var c = await source.OpenConnectionAsync();
                using var cmd = c.CreateCommand();
                cmd.CommandText = "INSERT INTO cronwatch_state (job, state) VALUES ('v', $s)";
                var p = cmd.CreateParameter();
                p.ParameterName = "$s";
                p.Value = text;
                cmd.Parameters.Add(p);
                await cmd.ExecuteNonQueryAsync();
            });
            Assert.Equal(16, foreign);
        }
    }

    [Fact]
    public async Task Sqlite_store_is_in_wal_mode_with_the_sdks_pragmas()
    {
        using var dir = new TempDir();
        var store = SqlStore.Sqlite(Sqlite(dir.File("cw.db")));
        await using (store)
        {
            await store.InitAsync();
            Assert.Equal("wal", await store.PragmaValueAsync("journal_mode"));
            Assert.Equal("5000", await store.PragmaValueAsync("busy_timeout"));
            Assert.Equal("1", await store.PragmaValueAsync("synchronous"));
        }
    }

    [Fact]
    public async Task A_prefix_is_checked_with_the_sdks_message()
    {
        using var dir = new TempDir();
        var e = Assert.Throws<CronwatchException>(() => SqlStore.Sqlite(Sqlite(dir.File("cw.db"))).WithPrefix("Bad"));
        Assert.Equal(CronwatchErrorKind.Invalid, e.Kind);
        Assert.Equal(
            "cronwatch: invalid table prefix \"Bad\". Use lowercase letters, digits, and underscores, not starting with a digit, at most 47 characters.",
            e.Message);
        var store = SqlStore.Sqlite(Sqlite(dir.File("p.db"))).WithPrefix("cw_");
        await using (store)
        {
            await store.InitAsync();
            await store.UpsertJobAsync(Definition.FromJson("{\"name\":\"a\"}"), 1);
            Assert.Equal("a", (await store.ListJobsAsync()).Single().Name);
        }
    }

    [Fact]
    public void The_store_names_its_database_from_the_connection()
    {
        using var dir = new TempDir();
        Assert.Equal("sqlite", SqlStore.For(Sqlite(dir.File("cw.db"))).Dialect);
    }

    [Fact]
    public async Task A_lone_surrogate_is_written_as_u_fffd()
    {
        using var dir = new TempDir();
        var store = SqlStore.Sqlite(Sqlite(dir.File("cw.db")));
        await using (store)
        {
            await store.InitAsync();
            await store.InsertRunAsync(Run.Running("r1", "a", 1, "x\ud83dy"));
            Assert.Equal("x�y", (await store.GetRunAsync("r1"))!.Trigger);
        }
    }
}
