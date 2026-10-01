using System;
using System.Collections.Generic;
using System.Data.Common;
using System.IO;
using System.Linq;
using System.Threading.Tasks;
using System.Transactions;
using Cronwatch.StoreTesting;
using Xunit;

namespace Cronwatch.Tests;

/// <summary>
/// The SQL store against a real server: the contract, the <c>store.json</c> replay with its
/// foreign versions and <c>nul</c> steps, rows of another shape, the finish-once scenarios over
/// several clients, a client end to end, and the app's transactions. Each test works on tables of
/// a prefix of its own, dropped at the end. Postgres, MySQL and MariaDB each run it when their
/// <c>CRONWATCH_TEST_*</c> variable is set.
/// </summary>
public abstract class ServerStoreTests
{
    private protected static string StoreFixture => File.ReadAllText(Path.Combine(Fixtures.ConformanceDir, "store.json"));

    /// <summary>The variable that names the server.</summary>
    private protected abstract string Variable { get; }

    /// <summary>A data source for the server, from its URL.</summary>
    private protected abstract DbDataSource Open(string url);

    /// <summary>The store over the data source.</summary>
    private protected abstract SqlStore Store(DbDataSource source);

    /// <summary>The dialect the store reports.</summary>
    private protected abstract string DialectName { get; }

    /// <summary>A statement writing a raw state row for job <c>v</c> with the text bound as its one parameter.</summary>
    private protected abstract string RawStateInsert(string prefix);

    /// <summary>A server, its data source and the prefixes a test used, dropped when it is disposed.</summary>
    private protected sealed class Server : IAsyncDisposable
    {
        private readonly List<string> _prefixes = [];

        public Server(DbDataSource source)
        {
            Source = source;
        }

        public DbDataSource Source { get; }

        public string Prefix(string name)
        {
            string p = Databases.Prefix(name);
            _prefixes.Add(p);
            return p;
        }

        public Task ExecAsync(string sql) => Databases.ExecAsync(Source, sql);

        public async ValueTask DisposeAsync()
        {
            foreach (string p in _prefixes)
            {
                await Databases.ExecAsync(Source, "DROP TABLE IF EXISTS " + p + "jobs, " + p + "runs, " + p + "state");
            }
            await Source.DisposeAsync();
        }
    }

    private protected Server Connect() => new(Open(Databases.Require(Variable)));

    [Fact]
    public async Task The_store_passes_the_contract()
    {
        await using var server = Connect();
        var store = Store(server.Source).WithPrefix(server.Prefix("contract"));
        Assert.Equal(DialectName, store.Dialect);
        await StoreContract.RunAsync(store);
    }

    [Fact]
    public async Task The_store_replays_store_json_with_its_foreign_versions_and_nuls()
    {
        await using var server = Connect();
        int cases = await StoreReplay.RunAsync(StoreFixture, () => Store(server.Source).WithPrefix(server.Prefix("replay")));
        Assert.True(cases >= 28);
        string p = server.Prefix("foreign");
        var store = Store(server.Source).WithPrefix(p);
        int foreign = await StoreReplay.ForeignVersionsAsync(StoreFixture, store, async text =>
        {
            await using var c = await server.Source.OpenConnectionAsync();
            await using var cmd = c.CreateCommand();
            cmd.CommandText = RawStateInsert(p);
            var parameter = cmd.CreateParameter();
            parameter.Value = text;
            cmd.Parameters.Add(parameter);
            await cmd.ExecuteNonQueryAsync();
        });
        Assert.Equal(16, foreign);
    }

    [Fact]
    public async Task A_check_over_foreign_rows_reports_nothing_and_sends_the_sdks_alert()
    {
        await using var server = Connect();
        string p = server.Prefix("far");
        await ForeignRowChecks.CheckOverForeignRowsAsync(Store(server.Source).WithPrefix(p), p, server.ExecAsync);
        foreach (string start in ForeignRowChecks.FarStarts)
        {
            string each = server.Prefix("cron");
            await ForeignRowChecks.CronOverForeignRowAsync(Store(server.Source).WithPrefix(each), each, start, server.ExecAsync);
        }
    }

    [Fact]
    public async Task Rows_of_another_shape_are_read_as_the_sdk_reads_them()
    {
        await using var server = Connect();
        string p = server.Prefix("shape");
        var store = Store(server.Source).WithPrefix(p);
        await store.InitAsync();
        await server.ExecAsync("INSERT INTO " + p + "jobs (name, definition, created_at, updated_at) VALUES ('odd', '[1]', 1, 2)");
        await server.ExecAsync("INSERT INTO " + p + "runs (id, job, status, started_at, metrics) VALUES ('x', 'odd', 'running', 5, '{\"a\":\"text\",\"b\":2}')");
        StoredJob job = (await store.GetJobAsync("odd"))!;
        // A definition that is not an object reads as its name alone, marked unreadable.
        Assert.Equal("{\"name\":\"odd\"}", job.Definition.ToJson());
        Assert.True(job.Definition.Unreadable);
        Assert.Equal(2, job.UpdatedAt);
        Run running = Assert.Single(await store.RunningRunsAsync());
        Assert.Equal("{\"b\":2}", running.Metrics.ToJson());
        Assert.Equal("run", running.Trigger);
        await server.ExecAsync("INSERT INTO " + p + "runs (id, job, status, started_at, finished_at, duration_ms) VALUES ('far', 'odd', 'ok', -9223372036854775808, 7, 9223372036854775807)");
        Run far = (await store.GetRunAsync("far"))!;
        Assert.Equal(long.MinValue, far.StartedAt);
        Assert.Equal(7L, far.FinishedAt);
        Assert.Equal(long.MaxValue, far.DurationMs);
        if (DialectName == "mysql")
        {
            // MySQL's and MariaDB's LONGTEXT hold text that is not JSON (Postgres's JSONB cannot): it
            // reads as no state, and its version counts as 0, so the next write replaces it.
            await server.ExecAsync("INSERT INTO " + p + "state (job, state) VALUES ('bad', 'not json')");
            Assert.Null(await store.GetStateAsync("bad"));
            Assert.True(await store.CompareAndSetStateAsync(JobState.Initial("bad") with { Version = 1 }, 0));
            Assert.Equal(1L, (await store.GetStateAsync("bad"))!.Version);
        }
    }

    [Fact]
    public async Task Text_drops_nuls_and_a_lone_surrogate_is_written_as_the_replacement_character()
    {
        await using var server = Connect();
        var store = Store(server.Source).WithPrefix(server.Prefix("text"));
        await store.InitAsync();
        // The drivers encode strict UTF-8 and would throw on a lone surrogate, losing the run:
        // every string is bound well formed.
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
        await store.UpsertJobAsync(Definition.FromJson("{\"name\":\"j\",\"description\":\"a\\u0000b\"}"), 1);
        Assert.Equal("{\"name\":\"j\",\"description\":\"ab\"}", (await store.GetJobAsync("j"))!.Definition.ToJson());
    }

    [Fact]
    public async Task Runs_that_started_together_keep_their_insertion_order_and_names_sort_by_byte()
    {
        await using var server = Connect();
        var store = Store(server.Source).WithPrefix(server.Prefix("order"));
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

    [Fact]
    public async Task The_store_names_its_database_from_the_connection()
    {
        await using var server = Connect();
        Assert.Equal(DialectName, SqlStore.For(server.Source).Dialect);
    }

    [Fact]
    public async Task Many_stores_make_the_tables_at_once()
    {
        await using var server = Connect();
        string p = server.Prefix("init");
        await Task.WhenAll(Enumerable.Range(0, 6).Select(_ => Task.Run(() => Store(server.Source).WithPrefix(p).InitAsync())));
        var store = Store(server.Source).WithPrefix(p);
        await store.UpsertJobAsync(Definition.FromJson("{\"name\":\"a\"}"), 1);
        Assert.Equal("a", Assert.Single(await store.ListJobsAsync()).Name);
    }

    private sealed class Shared(ServerStoreTests test, Server server) : FinishOnce.IShared
    {
        private readonly string _prefix = server.Prefix("once");

        public IStore Open() => test.Store(server.Source).WithPrefix(_prefix);

        public Task DoneAsync() => Task.CompletedTask;
    }

    [Fact]
    public async Task A_run_is_finished_once_by_several_clients_on_one_database()
    {
        await using var server = Connect();
        await FinishOnce.RunAsync(() => new Shared(this, server));
    }

    [Fact]
    public async Task A_client_end_to_end()
    {
        await using var server = Connect();
        await using var m = Support.Make(store: Store(server.Source).WithPrefix(server.Prefix("e2e")));
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
        Assert.Equal("nightly", Assert.Single(result.Jobs).Name);
        var runs = await m.Cw.RunsAsync("nightly");
        Assert.Equal([RunStatus.Failed, RunStatus.Ok], runs.Select(r => r.Status));
        Assert.StartsWith("InvalidOperationException: disk full", runs[0].Error, StringComparison.Ordinal);
        Assert.Empty(m.Errors.Entries);
    }

    [Fact]
    public async Task A_run_survives_the_apps_rolled_back_transaction_scope()
    {
        await using var server = Connect();
        string p = server.Prefix("scope");
        await using var m = Support.Make(store: Store(server.Source).WithPrefix(p));
        var job = m.Cw.Job("import");
        await Assert.ThrowsAsync<InvalidOperationException>(() => job.RunAsync(async (ctx, ct) =>
        {
            using var scope = new TransactionScope(TransactionScopeAsyncFlowOption.Enabled);
            // The app's own write, on a connection that enlists in the scope, as the drivers'
            // connections do by default.
            await using var c = await server.Source.OpenConnectionAsync(ct);
            await using var cmd = c.CreateCommand();
            cmd.CommandText = "INSERT INTO " + p + "jobs (name, definition, created_at, updated_at) VALUES ('app_row', '{}', 1, 1)";
            await cmd.ExecuteNonQueryAsync(ct);
            ctx.Log("imported 3 rows");
            throw new InvalidOperationException("constraint violated");
        }));
        Run run = Assert.Single(await m.Cw.RunsAsync("import"));
        Assert.Equal(RunStatus.Failed, run.Status);
        Assert.StartsWith("InvalidOperationException: constraint violated", run.Error, StringComparison.Ordinal);
        Assert.Equal("imported 3 rows", run.Output);
        // The app's write went with its rollback.
        Assert.Null(await m.Cw.Store.GetJobAsync("app_row"));
    }

    [Fact]
    public async Task A_run_survives_the_apps_rolled_back_connection_transaction()
    {
        // An EF Core transaction is one on the context's own connection, as this is: the store's
        // connections are its own, so nothing of the store's joins it.
        await using var server = Connect();
        string p = server.Prefix("dbtx");
        await using var m = Support.Make(store: Store(server.Source).WithPrefix(p));
        var job = m.Cw.Job("import");
        await m.Cw.JobsAsync();
        await using (var c = await server.Source.OpenConnectionAsync())
        {
            await using var tx = await c.BeginTransactionAsync();
            await Assert.ThrowsAsync<InvalidOperationException>(() => job.RunAsync(async (ctx, ct) =>
            {
                await using var cmd = c.CreateCommand();
                cmd.Transaction = tx;
                cmd.CommandText = "INSERT INTO " + p + "jobs (name, definition, created_at, updated_at) VALUES ('app_row', '{}', 1, 1)";
                await cmd.ExecuteNonQueryAsync(ct);
                throw new InvalidOperationException("constraint violated");
            }));
            await tx.RollbackAsync();
        }
        Assert.Equal(RunStatus.Failed, Assert.Single(await m.Cw.RunsAsync("import")).Status);
        Assert.Null(await m.Cw.Store.GetJobAsync("app_row"));
    }
}

/// <summary>The SQL store on Postgres (Npgsql), when <c>CRONWATCH_TEST_PG</c> is set.</summary>
public sealed class PostgresStoreTests : ServerStoreTests
{
    private protected override string Variable => Databases.PgVariable;

    private protected override DbDataSource Open(string url) => Databases.Postgres(url);

    private protected override SqlStore Store(DbDataSource source) => SqlStore.Postgres(source);

    private protected override string DialectName => "postgres";

    private protected override string RawStateInsert(string prefix) => "INSERT INTO " + prefix + "state (job, state) VALUES ('v', $1::jsonb)";

    [Fact]
    public async Task The_tables_are_the_sdks_with_jsonb_and_a_partial_index()
    {
        await using var server = Connect();
        string p = server.Prefix("schema");
        await Store(server.Source).WithPrefix(p).InitAsync();
        await using var c = await server.Source.OpenConnectionAsync();
        await using var cmd = c.CreateCommand();
        cmd.CommandText = "SELECT table_name || '.' || column_name || ' ' || data_type FROM information_schema.columns WHERE table_name LIKE '" + p
            + "%' ORDER BY table_name, ordinal_position";
        var columns = new List<string>();
        await using (var reader = await cmd.ExecuteReaderAsync())
        {
            while (await reader.ReadAsync())
            {
                columns.Add(reader.GetString(0));
            }
        }
        Assert.Equal(
            [
                p + "jobs.name text", p + "jobs.definition jsonb", p + "jobs.created_at bigint", p + "jobs.updated_at bigint",
                p + "runs.seq bigint", p + "runs.id text", p + "runs.job text", p + "runs.status text", p + "runs.started_at bigint",
                p + "runs.finished_at bigint", p + "runs.duration_ms bigint", p + "runs.error text", p + "runs.output text",
                p + "runs.metrics jsonb", p + "runs.trigger text", p + "state.job text", p + "state.state jsonb",
            ],
            columns);
        cmd.CommandText = "SELECT indexdef FROM pg_indexes WHERE indexname = '" + p + "runs_running'";
        Assert.EndsWith("WHERE (status = 'running'::text)", (string)(await cmd.ExecuteScalarAsync())!, StringComparison.Ordinal);
    }
}

/// <summary>What MySQL and MariaDB share: the dialect, and a connection counting changed rows.</summary>
public abstract class MySqlFamilyStoreTests : ServerStoreTests
{
    private protected override DbDataSource Open(string url) => Databases.MySql(url);

    private protected override SqlStore Store(DbDataSource source) => SqlStore.MySql(source);

    private protected override string DialectName => "mysql";

    private protected override string RawStateInsert(string prefix) => "INSERT INTO " + prefix + "state (job, state) VALUES ('v', ?)";

    [Fact]
    public async Task The_contract_and_the_replay_hold_on_a_connection_that_counts_changed_rows()
    {
        string url = Databases.Require(Variable);
        await using var server = new Server(Databases.MySql(url, useAffectedRows: true));
        await StoreContract.RunAsync(Store(server.Source).WithPrefix(server.Prefix("affected")));
        Assert.True(await StoreReplay.RunAsync(StoreFixture, () => Store(server.Source).WithPrefix(server.Prefix("affected_replay"))) >= 28);
    }

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public async Task A_write_that_changed_nothing_still_counts_as_written(bool useAffectedRows)
    {
        string url = Databases.Require(Variable);
        await using var server = new Server(Databases.MySql(url, useAffectedRows));
        var store = Store(server.Source).WithPrefix(server.Prefix("landed"));
        await store.InitAsync();
        var finished = StoreContract.MakeRun("r1", "j", RunStatus.Ok, 1000) with { FinishedAt = 2000, DurationMs = 1000, Metrics = Metrics.Of([new("b", 2), new("a", 1)]) };
        await store.InsertRunAsync(finished);
        // The same values over a row already holding them: matched, but not changed.
        Assert.True(await store.UpdateRunIfAsync(finished, [RunStatus.Ok]));
        Assert.False(await store.UpdateRunIfAsync(finished, [RunStatus.Running]));

        var state = JobState.Initial("j");
        Assert.True(await store.CompareAndSetStateAsync(state, 0));
        // A version 0 row written again with the same bytes: a lost answer, counted as written.
        Assert.True(await store.CompareAndSetStateAsync(state, 0));
        var next = state with { Version = 1 };
        Assert.True(await store.CompareAndSetStateAsync(next, 0));
        // Now at version 1: a write expecting 0 is refused.
        Assert.False(await store.CompareAndSetStateAsync(state, 0));
    }

    [Fact]
    public async Task A_long_trigger_is_cut_to_255_code_points()
    {
        await using var server = Connect();
        var store = Store(server.Source).WithPrefix(server.Prefix("trigger"));
        await store.InitAsync();
        string trigger = new string('x', 254) + "\ud83d\ude00" + "tail";
        await store.InsertRunAsync(Run.Running("r1", "j", 1, trigger));
        Assert.Equal(new string('x', 254) + "\ud83d\ude00", (await store.GetRunAsync("r1"))!.Trigger);
    }

    [Fact]
    public async Task The_tables_hold_json_as_longtext_compared_by_byte()
    {
        await using var server = Connect();
        string p = server.Prefix("schema");
        await Store(server.Source).WithPrefix(p).InitAsync();
        await using var c = await server.Source.OpenConnectionAsync();
        await using var cmd = c.CreateCommand();
        cmd.CommandText = "SELECT CONCAT(TABLE_NAME, '.', COLUMN_NAME, ' ', DATA_TYPE, ' ', IFNULL(COLLATION_NAME, '-')) FROM information_schema.COLUMNS"
            + " WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME LIKE '" + p + "%' AND DATA_TYPE IN ('longtext', 'varchar') ORDER BY TABLE_NAME, ORDINAL_POSITION";
        var columns = new List<string>();
        await using (var reader = await cmd.ExecuteReaderAsync())
        {
            while (await reader.ReadAsync())
            {
                columns.Add(reader.GetString(0));
            }
        }
        Assert.Equal(
            [
                p + "jobs.name varchar utf8mb4_bin", p + "jobs.definition longtext utf8mb4_bin",
                p + "runs.id varchar utf8mb4_bin", p + "runs.job varchar utf8mb4_bin", p + "runs.status varchar utf8mb4_bin",
                p + "runs.metrics longtext utf8mb4_bin", p + "runs.trigger varchar utf8mb4_bin",
                p + "state.job varchar utf8mb4_bin", p + "state.state longtext utf8mb4_bin",
            ],
            columns);
    }
}

/// <summary>The SQL store on MySQL (MySqlConnector), when <c>CRONWATCH_TEST_MYSQL</c> is set.</summary>
public sealed class MySqlStoreTests : MySqlFamilyStoreTests
{
    private protected override string Variable => Databases.MySqlVariable;
}

/// <summary>The SQL store on MariaDB (MySqlConnector), when <c>CRONWATCH_TEST_MARIADB</c> is set.</summary>
public sealed class MariaDbStoreTests : MySqlFamilyStoreTests
{
    private protected override string Variable => Databases.MariaDbVariable;
}
