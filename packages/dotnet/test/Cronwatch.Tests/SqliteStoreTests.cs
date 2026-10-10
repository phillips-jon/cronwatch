using System;
using System.Collections.Generic;
using System.Data.Common;
using System.IO;
using System.Linq;
using System.Threading.Tasks;
using System.Transactions;
using Cronwatch.Internal;
using Cronwatch.StoreTesting;
using Microsoft.Data.Sqlite;
using Xunit;

#pragma warning disable CS0618 // StoreReplay and FinishOnce, deprecated, still run the port's own replay and finish-once checks

namespace Cronwatch.Tests;

/// <summary>The SQL store on SQLite beyond the contract: the SDK's schema, rows of other shapes, the multi-process scenarios, and the app's transactions.</summary>
public class SqliteStoreTests
{
    private static DbDataSource Source(string file) => StoreTests.Sqlite(file);

    /// <summary>Runs statements on a connection of its own, as another process would.</summary>
    internal static async Task Exec(string file, params string[] statements)
    {
        await using var c = new SqliteConnection("Data Source=" + file + ";Pooling=False");
        await c.OpenAsync();
        foreach (string statement in statements)
        {
            using var cmd = c.CreateCommand();
            cmd.CommandText = statement;
            await cmd.ExecuteNonQueryAsync();
        }
    }

    /// <summary>The first column of every row of a query, as text.</summary>
    internal static async Task<List<string>> Column(string file, string query)
    {
        await using var c = new SqliteConnection("Data Source=" + file + ";Pooling=False");
        await c.OpenAsync();
        using var cmd = c.CreateCommand();
        cmd.CommandText = query;
        await using var reader = await cmd.ExecuteReaderAsync();
        var output = new List<string>();
        while (await reader.ReadAsync())
        {
            output.Add(reader.IsDBNull(0) ? "" : Convert.ToString(reader.GetValue(0), System.Globalization.CultureInfo.InvariantCulture)!);
        }
        return output;
    }

    [Fact]
    public async Task The_store_passes_the_contract_in_memory_with_a_prefix()
    {
        await StoreContract.RunAsync(SqlStore.Sqlite(SqliteFactory.Instance.CreateDataSource("Data Source=:memory:")));
        using var dir = new TempDir();
        await using var store = SqlStore.Sqlite(Source(dir.File("contract.db"))).WithPrefix("cw_");
        await StoreContract.RunAsync(store);
    }

    [Fact]
    public async Task The_tables_are_the_sdks_text_for_text()
    {
        using var dir = new TempDir();
        string file = dir.File("schema.db");
        var store = SqlStore.Sqlite(Source(file)).WithPrefix("cw_");
        await using (store)
        {
            await store.InitAsync();
            await store.InitAsync();
        }
        var sql = await Column(file, "SELECT sql FROM sqlite_master WHERE name LIKE 'cw_%' AND sql IS NOT NULL ORDER BY name");
        // SQLite keeps each statement's text from CREATE on, with IF NOT EXISTS taken out.
        var want = SqlText.SchemaText(SqlDialect.Sqlite, "cw_").Split(';')
            .Where(s => !string.IsNullOrWhiteSpace(s))
            .Select(s => s.TrimStart().Replace(" IF NOT EXISTS", "", StringComparison.Ordinal))
            .Order(StringComparer.Ordinal)
            .ToList();
        Assert.Equal(want, sql.Order(StringComparer.Ordinal).ToList());
        Assert.Contains("CREATE INDEX cw_runs_running ON cw_runs (status) WHERE status = 'running'", sql);
        Assert.Equal(["wal"], await Column(file, "PRAGMA journal_mode"));
    }

    [Fact]
    public void The_sqlite_statements_are_numbered_in_sqlites_own_form()
    {
        var sql = new SqlText.Statements(SqlDialect.Sqlite, "cronwatch_");
        Assert.Equal(
            "INSERT INTO cronwatch_jobs (name, definition, created_at, updated_at) VALUES (?1, ?2, ?3, ?4)\n"
            + "      ON CONFLICT (name) DO UPDATE SET definition = excluded.definition, updated_at = excluded.updated_at",
            sql.UpsertJob);
        Assert.Equal("SELECT * FROM cronwatch_runs WHERE job = ?1 ORDER BY started_at DESC, rowid DESC LIMIT ?2", sql.ListRuns);
        Assert.Equal(
            "UPDATE cronwatch_runs SET status = ?1, finished_at = ?2, duration_ms = ?3, error = ?4, output = ?5, metrics = ?6 WHERE id = ?7 AND status IN (?8, ?9)",
            sql.UpdateRunIf(2));
        Assert.Equal("SELECT * FROM cronwatch_jobs ORDER BY name", sql.ListJobs);
    }

    [Fact]
    public void The_postgres_statements_are_numbered_and_cast_json_to_jsonb()
    {
        var sql = new SqlText.Statements(SqlDialect.Postgres, "cronwatch_");
        Assert.Equal(
            "INSERT INTO cronwatch_jobs (name, definition, created_at, updated_at) VALUES ($1, $2::jsonb, $3, $4)\n"
            + "      ON CONFLICT (name) DO UPDATE SET definition = excluded.definition, updated_at = excluded.updated_at",
            sql.UpsertJob);
        Assert.Equal(
            "INSERT INTO cronwatch_runs (id, job, status, started_at, finished_at, duration_ms, error, output, metrics, trigger)\n"
            + "      VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9::jsonb, $10)",
            sql.InsertRun);
        Assert.Equal(
            "UPDATE cronwatch_runs SET status = $1, finished_at = $2, duration_ms = $3, error = $4, output = $5, metrics = $6::jsonb WHERE id = $7 AND status IN ($8)",
            sql.UpdateRunIf(1));
        Assert.Equal(
            "UPDATE cronwatch_state SET state = $1::jsonb WHERE job = $2 AND CASE WHEN jsonb_typeof(state->'version') <> 'number' THEN 0 "
            + "WHEN (state->>'version')::numeric % 1 = 0 AND (state->>'version')::numeric BETWEEN 0 AND 9007199254740991 "
            + "THEN (state->>'version')::numeric::bigint ELSE 0 END = $3",
            sql.CasUpdate);
        Assert.Equal("SELECT * FROM cronwatch_jobs ORDER BY name COLLATE \"C\"", sql.ListJobs);
        Assert.Equal("SELECT * FROM cronwatch_runs WHERE job = $1 ORDER BY started_at DESC, seq DESC LIMIT $2", sql.ListRuns);
        Assert.Contains("seq BIGSERIAL,", SqlText.SchemaText(SqlDialect.Postgres, "cronwatch_"), StringComparison.Ordinal);
    }

    [Fact]
    public async Task A_busy_database_is_retried_while_switching_to_wal()
    {
        using var dir = new TempDir();
        string file = dir.File("busy.db");
        await Exec(file, "CREATE TABLE t (x INTEGER)");
        // Another connection holds a write lock for a moment; the store retries rather than fail.
        await using (var other = new SqliteConnection("Data Source=" + file + ";Pooling=False"))
        {
            await other.OpenAsync();
            var tx = (SqliteTransaction)await other.BeginTransactionAsync();
            using (var cmd = other.CreateCommand())
            {
                cmd.Transaction = tx;
                cmd.CommandText = "INSERT INTO t VALUES (1)";
                await cmd.ExecuteNonQueryAsync();
            }
            var release = Task.Run(async () =>
            {
                await Task.Delay(300);
                await tx.CommitAsync();
            });
            var store = SqlStore.Sqlite(Source(file));
            await using (store)
            {
                await store.InitAsync();
            }
            await release;
            await tx.DisposeAsync();
        }
        Assert.Equal(["wal"], await Column(file, "PRAGMA journal_mode"));
    }

    [Fact]
    public void Busy_codes_are_recognised()
    {
        Assert.True(SqlStore.Busy(new SqliteException("SQLite Error 5: 'database is locked'.", 5)));
        Assert.True(SqlStore.Busy(new SqliteException("SQLite Error 261: 'x'.", 261)));
        Assert.True(SqlStore.Busy(new SqliteException("SQLite Error 6: 'database table is locked'.", 6)));
        Assert.False(SqlStore.Busy(new SqliteException("SQLite Error 1: 'no such table: t'.", 1)));
        Assert.False(SqlStore.Busy(new SqliteException("SQLite Error 19: 'UNIQUE constraint failed'.", 19)));
    }

    [Fact]
    public async Task Runs_that_started_together_keep_their_insertion_order_and_names_sort_by_byte()
    {
        var store = SqlStore.Sqlite(SqliteFactory.Instance.CreateDataSource("Data Source=:memory:"));
        await using (store)
        {
            await store.InitAsync();
            foreach (string id in new[] { "b", "a", "c" })
            {
                await store.InsertRunAsync(StoreContract.MakeRun(id, "j", RunStatus.Running, 1000));
            }
            Assert.Equal(["c", "a", "b"], (await store.ListRunsAsync("j", 10)).Select(r => r.Id));
            Assert.Equal(["b", "a", "c"], (await store.RunningRunsAsync()).Select(r => r.Id));
            foreach (string name in new[] { "b", "\u00e9", "B", "a", "_z", "Z" })
            {
                await store.UpsertJobAsync(Definition.FromJson("{\"name\":\"" + name + "\"}"), 1);
            }
            Assert.Equal(["B", "Z", "_z", "a", "b", "\u00e9"], (await store.ListJobsAsync()).Select(j => j.Name));
        }
    }

    [Fact]
    public async Task Text_drops_nuls_and_a_lone_surrogate_is_written_as_the_replacement_character()
    {
        using var dir = new TempDir();
        string file = dir.File("text.db");
        var store = SqlStore.Sqlite(Source(file));
        await using (store)
        {
            await store.InitAsync();
            await store.InsertRunAsync(new Run
            {
                Id = "t1",
                Job = "j",
                Status = RunStatus.Ok,
                StartedAt = 1,
                FinishedAt = 2,
                DurationMs = 1,
                Error = "a\0b",
                Output = "x\ud83dy \ud83d\ude00",
                Metrics = Metrics.Of([new("n\0m", 1)]),
                Trigger = "r\0un",
            });
            Run back = (await store.GetRunAsync("t1"))!;
            Assert.Equal("ab", back.Error);
            Assert.Equal("x\ufffdy \ud83d\ude00", back.Output);
            Assert.Equal("{\"nm\":1}", back.Metrics.ToJson());
            Assert.Equal("run", back.Trigger);
        }
        // The bytes the file holds are the ones better-sqlite3 writes for the same string.
        Assert.Equal(["78EFBFBD7920F09F9880"], await Column(file, "SELECT hex(output) FROM cronwatch_runs WHERE id = 't1'"));
    }

    [Fact]
    public async Task A_foreign_metric_that_is_no_finite_number_is_left_off_the_job_page()
    {
        using var dir = new TempDir();
        string file = dir.File("metrics.db");
        await using var w = new Web.WebKit(new Cronwatch.Web.RoutesOptions { Token = "tok" }, SqlStore.Sqlite(Source(file)));
        await w.Ok("odd");
        await Exec(
            file,
            "INSERT INTO cronwatch_runs (id, job, status, started_at, finished_at, duration_ms, metrics, trigger) VALUES "
            + "('m', 'odd', 'ok', 5, 6, 1, '{\"rows\":null,\"label\":\"abc\",\"cost\":1.25,\"n\":3}', 'source')");
        Cronwatch.Web.CronwatchResponse page = await w.Get("/cronwatch/jobs/odd", Web.WebKit.Auth);
        Web.WebKit.Status("job page", page, 200);
        string text = page.Text();
        int cost = text.IndexOf("<span class=\"k\">cost</span> 1.2500", StringComparison.Ordinal);
        Assert.True(cost >= 0, "cost is shown");
        Assert.True(text.IndexOf("<span class=\"k\">n</span> 3", StringComparison.Ordinal) > cost, "then n");
        Assert.DoesNotContain("<span class=\"k\">rows</span>", text, StringComparison.Ordinal);
        Assert.DoesNotContain("<span class=\"k\">label</span>", text, StringComparison.Ordinal);
        Assert.Equal("{\"cost\":1.25,\"n\":3}", (await w.Cw.GetRunAsync("m"))!.Metrics.ToJson());
    }

    [Fact]
    public async Task Rows_of_another_shape_are_read_as_the_sdk_reads_them()
    {
        using var dir = new TempDir();
        string file = dir.File("foreign.db");
        var store = SqlStore.Sqlite(Source(file));
        await using (store)
        {
            await store.InitAsync();
            await Exec(
                file,
                "INSERT INTO cronwatch_jobs (name, definition, created_at, updated_at) VALUES ('odd', '[1]', 1, 2)",
                "INSERT INTO cronwatch_runs (id, job, status, started_at, metrics) VALUES ('x', 'odd', 'running', 5.0, '{\"a\":\"text\",\"b\":2}')");
            StoredJob job = (await store.GetJobAsync("odd"))!;
            // A definition that is not an object reads as its name alone, marked unreadable.
            Assert.Equal("{\"name\":\"odd\"}", job.Definition.ToJson());
            Assert.True(job.Definition.Unreadable);
            Assert.Equal(2, job.UpdatedAt);
            Run running = Assert.Single(await store.RunningRunsAsync());
            Assert.Equal("{\"b\":2}", running.Metrics.ToJson());
            Assert.Equal(5, running.StartedAt);
            Assert.Equal("run", running.Trigger);

            // Text that is not UTF-8 reads with U+FFFD rather than failing every read of the job's runs.
            await Exec(file, "INSERT INTO cronwatch_runs (id, job, status, started_at, output, trigger) VALUES ('y', 'odd', 'ok', 6, CAST(x'61ff62' AS TEXT), 'run')");
            Assert.Equal("a\ufffdb", (await store.ListRunsAsync("odd", 10))[0].Output);

            // A start at the lowest BIGINT, and times and durations stored as text or real, read
            // as whole numbers held at the ends of the range.
            await Exec(
                file,
                "INSERT INTO cronwatch_runs (id, job, status, started_at, finished_at, duration_ms, trigger) VALUES ('far', 'odd', 'ok', -9223372036854775808, ' 7 ', 1e300, 'run')");
            Run far = (await store.GetRunAsync("far"))!;
            Assert.Equal(long.MinValue, far.StartedAt);
            Assert.Equal(7L, far.FinishedAt);
            Assert.Equal(long.MaxValue, far.DurationMs);
            Assert.Equal(Metrics.Empty, far.Metrics);

            // A state that is not JSON, or not an object, reads as none, and the next write
            // replaces it.
            await Exec(file, "INSERT INTO cronwatch_state (job, state) VALUES ('bad', 'not json'), ('five', '5')");
            Assert.Null(await store.GetStateAsync("bad"));
            Assert.Null(await store.GetStateAsync("five"));
            Assert.True(await store.CompareAndSetStateAsync(JobState.Initial("bad") with { Version = 1 }, 0));
            Assert.Equal(1L, (await store.GetStateAsync("bad"))!.Version);
            Assert.Null(await store.GetStateAsync("other"));
            await store.SetStateAsync(JobState.Initial("ok"));
            Assert.NotNull(await store.GetStateAsync("ok"));
        }
    }

    [Fact]
    public async Task The_store_opens_again_after_it_is_disposed()
    {
        using var dir = new TempDir();
        var store = SqlStore.Sqlite(Source(dir.File("reopen.db")));
        await using (store)
        {
            await store.InitAsync();
            await store.UpsertJobAsync(Definition.FromJson("{\"name\":\"a\"}"), 1);
            await store.DisposeAsync();
            Assert.Equal("a", (await store.ListJobsAsync())[0].Name);
        }
    }

    [Fact]
    public async Task A_check_over_foreign_rows_reports_nothing_and_sends_the_sdks_alert()
    {
        using var dir = new TempDir();
        string file = dir.File("far.db");
        var store = SqlStore.Sqlite(Source(file));
        await using (store)
        {
            await ForeignRowChecks.CheckOverForeignRowsAsync(store, "cronwatch_", sql => Exec(file, sql));
        }
        int n = 0;
        foreach (string start in ForeignRowChecks.FarStarts)
        {
            string each = dir.File("cron" + n++ + ".db");
            var cron = SqlStore.Sqlite(Source(each));
            await using (cron)
            {
                await ForeignRowChecks.CronOverForeignRowAsync(cron, "cronwatch_", start, sql => Exec(each, sql));
            }
        }
    }

    private sealed class Shared(TempDir dir, string name) : FinishOnce.IShared
    {
        public IStore Open() => SqlStore.Sqlite(Source(dir.File(name)));

        public Task DoneAsync()
        {
            SqliteConnection.ClearAllPools();
            foreach (string f in new[] { name, name + "-wal", name + "-shm" })
            {
                File.Delete(dir.File(f));
            }
            return Task.CompletedTask;
        }
    }

    private sealed class SharedMemory : FinishOnce.IShared
    {
        private readonly MemoryStore _store = new();

        public IStore Open() => _store;

        public Task DoneAsync() => Task.CompletedTask;
    }

    [Fact]
    public async Task A_run_is_finished_once_by_several_clients_on_one_sqlite_file()
    {
        using var dir = new TempDir();
        int n = 0;
        await FinishOnce.RunAsync(() => new Shared(dir, "shared" + n++ + ".db"));
    }

    [Fact]
    public Task A_run_is_finished_once_by_several_clients_on_one_memory_store() =>
        FinishOnce.RunAsync(() => new SharedMemory());

    [Fact]
    public async Task A_client_end_to_end_on_sqlite()
    {
        using var dir = new TempDir();
        await using var m = Support.Make(store: SqlStore.Sqlite(Source(dir.File("e2e.db"))));
        var job = m.Cw.Job("nightly", new JobOptions { Schedule = "every 1h", Grace = "5m", Budget = { ["cost"] = 2 } });
        await job.RunAsync((ctx, ct) =>
        {
            ctx.Log("wrote 3 files");
            ctx.Metric("cost", 3);
            return Task.CompletedTask;
        });
        await Assert.ThrowsAsync<InvalidOperationException>(() => job.RunAsync((ctx, ct) => throw new InvalidOperationException("disk full")));
        m.Clock.Advance(2 * Support.Hour);
        var result = await m.Cw.CheckAsync();
        Assert.Equal(["over_budget", "failed", "missed"], m.Alerts.Types());
        var summary = Assert.Single(result.Jobs);
        Assert.Equal("nightly", summary.Name);
        var runs = await m.Cw.RunsAsync("nightly");
        Assert.Equal([RunStatus.Failed, RunStatus.Ok], runs.Select(r => r.Status));
        Assert.StartsWith("InvalidOperationException: disk full", runs[0].Error, StringComparison.Ordinal);
        Assert.Empty(m.Errors.Entries);
    }

    /// <summary>A data source over another that notes the ambient transaction each connection is made under.</summary>
    private sealed class Watching(DbDataSource inner) : DbDataSource
    {
        public List<Transaction?> Ambient { get; } = [];

        public override string ConnectionString => inner.ConnectionString;

        protected override DbConnection CreateDbConnection()
        {
            lock (Ambient)
            {
                Ambient.Add(Transaction.Current);
            }
            return inner.CreateConnection();
        }

        protected override void Dispose(bool disposing)
        {
            if (disposing)
            {
                inner.Dispose();
            }
            base.Dispose(disposing);
        }
    }

    [Fact]
    public async Task The_store_opens_its_connections_outside_the_apps_transaction()
    {
        using var dir = new TempDir();
        using var source = new Watching(Source(dir.File("tx.db")));
        var store = SqlStore.Sqlite(source);
        await using (store)
        {
            using (var scope = new TransactionScope(TransactionScopeAsyncFlowOption.Enabled))
            {
                Assert.NotNull(Transaction.Current);
                await store.InitAsync();
                await store.InsertRunAsync(Run.Running("r1", "a", 1, "run"));
                // The app rolls back: nothing of the store's goes with it.
            }
            Assert.NotNull(await store.GetRunAsync("r1"));
        }
        Assert.NotEmpty(source.Ambient);
        Assert.All(source.Ambient, t => Assert.Null(t));
    }

    [Fact]
    public async Task A_run_survives_the_apps_rollback()
    {
        using var dir = new TempDir();
        await using var m = Support.Make(store: SqlStore.Sqlite(Source(dir.File("rollback.db"))));
        var job = m.Cw.Job("import");
        await Assert.ThrowsAsync<InvalidOperationException>(() => job.RunAsync(async (ctx, ct) =>
        {
            using var scope = new TransactionScope(TransactionScopeAsyncFlowOption.Enabled);
            await Task.Yield();
            throw new InvalidOperationException("constraint violated");
        }));
        Run run = Assert.Single(await m.Cw.RunsAsync("import"));
        Assert.Equal(RunStatus.Failed, run.Status);
        Assert.StartsWith("InvalidOperationException: constraint violated", run.Error, StringComparison.Ordinal);
    }
}
