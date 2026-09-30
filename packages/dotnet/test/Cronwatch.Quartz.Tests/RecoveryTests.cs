using System;
using System.Collections.Generic;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;
using Npgsql;
using Quartz;
using Xunit;
using static Cronwatch.Quartz.Tests.QuartzSupport;

namespace Cronwatch.Quartz.Tests;

/// <summary>
/// A clustered ADO.NET job store over Postgres (the tables made by Quartz itself, under a prefix of
/// the test's own), when <c>CRONWATCH_TEST_PG</c> names a server: a job a node was running when it
/// stopped is fired again on another node, and that firing finishes the earlier firing's run.
/// SQLite would be cheaper, but Quartz refuses it for a clustered store.
/// </summary>
public class RecoveryTests
{
    /// <summary><c>postgres://user:password@host:port/database</c> as Npgsql's connection string.</summary>
    private static string? ConnectionString()
    {
        string? url = Environment.GetEnvironmentVariable("CRONWATCH_TEST_PG");
        if (string.IsNullOrEmpty(url))
        {
            return null;
        }
        var uri = new Uri(url);
        string[] user = Uri.UnescapeDataString(uri.UserInfo).Split(':', 2);
        return new NpgsqlConnectionStringBuilder
        {
            Host = uri.Host,
            Port = uri.Port > 0 ? uri.Port : 5432,
            Username = user[0],
            Password = user.Length > 1 ? user[1] : null,
            Database = uri.AbsolutePath.TrimStart('/'),
        }.ConnectionString;
    }

    private static async Task<IScheduler> ClusteredAsync(string connection, string prefix, string instance, CronwatchClient cw) =>
        await QuartzSchedulerBuilder.Create(q =>
        {
            q.ConfigureScheduler(o =>
            {
                o.InstanceName = "recovery-" + prefix;
                o.InstanceId = instance;
                o.IdleWaitTime = TimeSpan.FromSeconds(1);
            });
            q.UsePersistentStore(s =>
            {
                s.UsePostgres(NpgsqlFactory.Instance, connection);
                s.ConfigureStore(o => o.TablePrefix = prefix);
                s.ProvisionSchema();
                s.UseSystemTextJsonSerializer(_ => { });
                s.UseClustering(c =>
                {
                    c.CheckinInterval = TimeSpan.FromSeconds(1);
                    c.CheckinMisfireThreshold = TimeSpan.FromSeconds(1);
                });
            });
            q.UseCronwatch(cw, o => o.App = "billing");
        }).BuildScheduler(default);

    [Fact]
    public async Task A_recovered_firing_finishes_the_stopped_nodes_run()
    {
        string? connection = ConnectionString();
        if (connection == null)
        {
            Assert.Skip("Quartz recovery: skipped, CRONWATCH_TEST_PG is not set");
        }
        string prefix = "qrtz_" + Guid.NewGuid().ToString("N")[..8] + "_";
        var store = new MemoryStore();
        var hold = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        int started = 0;
        try
        {
            await using var a = Client(store);
            await using var b = Client(store);
            IScheduler nodeA = await ClusteredAsync(connection, prefix, "node-a", a.Cw);
            IScheduler? nodeB = null;
            try
            {
                await nodeA.Start(default);
                IJobDetail job = JobBuilder.Create<DelegateJob>().WithIdentity("long").RequestRecovery(true)
                    .UsingJobData("behaviour", Behaviour(async _ =>
                    {
                        if (Interlocked.Increment(ref started) == 1)
                        {
                            await hold.Task; // the first firing never ends on its own
                        }
                    })).Build();
                await nodeA.ScheduleJob(job, Once("long"), default, default);
                await Eventually("node a's run", async () => (await store.ListRunsAsync("long", 10)).Any(r => r.Status == RunStatus.Running));
                await nodeA.Shutdown(false, default);

                nodeB = await ClusteredAsync(connection, prefix, "node-b", b.Cw);
                await nodeB.Start(default);
                await Eventually("the recovery", async () => (await store.ListRunsAsync("long", 10)).Count(r => r.Status != RunStatus.Running) == 2);
                var runs = (await store.ListRunsAsync("long", 10)).OrderBy(r => r.StartedAt).ToList();
                Assert.StartsWith("quartz:billing:node-a:", runs[0].Id, StringComparison.Ordinal);
                Assert.Equal(RunStatus.Failed, runs[0].Status);
                Assert.Equal(CronwatchQuartz.Recovered, runs[0].Error);
                Assert.StartsWith("quartz:billing:node-b:", runs[1].Id, StringComparison.Ordinal);
                Assert.Equal(RunStatus.Ok, runs[1].Status);
            }
            finally
            {
                hold.TrySetResult();
                if (nodeB != null)
                {
                    await nodeB.Shutdown(true, default);
                }
            }
        }
        finally
        {
            await DropAsync(connection, prefix);
        }
    }

    /// <summary>Drops the tables Quartz made under <paramref name="prefix"/>.</summary>
    private static async Task DropAsync(string connection, string prefix)
    {
        await using var conn = new NpgsqlConnection(connection);
        await conn.OpenAsync();
        var tables = new List<string>();
        await using (var list = new NpgsqlCommand("SELECT tablename FROM pg_tables WHERE schemaname = current_schema() AND tablename LIKE $1", conn))
        {
            list.Parameters.Add(new NpgsqlParameter { Value = prefix.ToLowerInvariant() + "%" });
            await using var reader = await list.ExecuteReaderAsync();
            while (await reader.ReadAsync())
            {
                tables.Add(reader.GetString(0));
            }
        }
        foreach (string table in tables)
        {
            await using var drop = new NpgsqlCommand("DROP TABLE IF EXISTS \"" + table + "\" CASCADE", conn);
            await drop.ExecuteNonQueryAsync();
        }
    }
}
