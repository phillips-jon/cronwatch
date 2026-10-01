using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.Linq;
using System.Threading.Tasks;
using static Cronwatch.StoreTesting.Checks;

namespace Cronwatch.StoreTesting;

/// <summary>
/// A client over rows another writer left in a SQL store's tables, rows the SDK's writers never
/// make but a foreign or damaged row can hold: a run that started at the lowest <c>BIGINT</c>
/// under a state whose version is <c>1.5</c>, and a cron job whose last run started before the
/// year 1 or after 9999. Nothing is reported as an error, every duration and time is one every
/// store holds, and the alerts are the SDK's. For a SQL store of the app's own; the caller runs
/// the SQL that plants each row, since only it can write raw rows into its database. Each method
/// disposes the store with the client it makes.
/// </summary>
internal static class ForeignRowChecks
{
    /// <summary>
    /// The starts a foreign or damaged row could give a cron job's last run, as SQL literals:
    /// before the year 1, after 9999, and the <c>BIGINT</c> extremes.
    /// </summary>
    public static IReadOnlyList<string> FarStarts { get; } =
        ["-62135596800001", "253402300800000", "-9223372036854775808", "9223372036854775807"];

    private sealed record Client(CronwatchClient Cw, ConcurrentQueue<Alert> Sent, ConcurrentQueue<string> Errors);

    // The caller disposes the client it is given.
#pragma warning disable CA2000
    private static Client Make(IStore store)
    {
        var sent = new ConcurrentQueue<Alert>();
        var errors = new ConcurrentQueue<string>();
        var cw = new CronwatchClient(new CronwatchOptions
        {
            Store = store,
            Alerts = { CustomChannel.Create("capture", (alert, _, _) => { sent.Enqueue(alert); return Task.CompletedTask; }) },
            CronSecret = CronSecret.None,
            OnError = (e, where) => errors.Enqueue(where + ": " + e.Message),
            OnWarning = _ => { },
            ProcessExitHook = false,
        });
        return new Client(cw, sent, errors);
    }
#pragma warning restore CA2000

    private static Task Exec(Func<string, Task> sql, string text) => Must("running " + text, () => sql(text));

    private static string Types(IEnumerable<Alert> alerts) => "[" + string.Join(", ", alerts.Select(a => a.Type.Value)) + "]";

    /// <summary>
    /// Two checks over a job with a 5 minute timeout whose running run started at the lowest
    /// <c>BIGINT</c>, under a state whose version is 1.5: the run is marked timed out with its
    /// duration held at 2^53 - 1, the state's 1.5 counts as 0, and the stuck alert is sent, its
    /// start written in words.
    /// </summary>
    /// <param name="store">The store, empty.</param>
    /// <param name="prefix">Its tables' prefix.</param>
    /// <param name="sql">Runs one SQL statement against the store's database.</param>
    /// <exception cref="StoreContractException">At the first thing that goes wrong.</exception>
    public static async Task CheckOverForeignRowsAsync(IStore store, string prefix, Func<string, Task> sql)
    {
        ArgumentNullException.ThrowIfNull(store);
        ArgumentNullException.ThrowIfNull(sql);
        await Must("init", () => store.InitAsync()).ConfigureAwait(false);
        await Must("upsertJob", () => store.UpsertJobAsync(Definition.FromJson("{\"name\":\"far\",\"timeout\":\"5m\"}"), 1)).ConfigureAwait(false);
        await Exec(sql, "INSERT INTO " + prefix + "runs (id, job, status, started_at) VALUES ('far1', 'far', 'running', -9223372036854775808)").ConfigureAwait(false);
        await Exec(sql, "INSERT INTO " + prefix + "state (job, state) VALUES ('far', '{\"job\":\"far\",\"open\":{},"
            + "\"consecutiveFailures\":0,\"silencedUntil\":null,\"lastAlertAt\":null,\"version\":1.5}')").ConfigureAwait(false);
        Client c = Make(store);
        await using (c.Cw.ConfigureAwait(false))
        {
            for (int i = 0; i < 2; i++)
            {
                await c.Cw.CheckAsync().ConfigureAwait(false);
            }
            Eq("nothing reported", string.Join("; ", c.Errors), "");
            Run? run = await Get("getRun", () => store.GetRunAsync("far1")).ConfigureAwait(false);
            Eq("the run is there", run != null, true);
            Eq("the run's status", run!.Status, RunStatus.Timeout);
            Eq("the duration, held at 2^53 - 1", run.DurationMs, (long?)9_007_199_254_740_991L);
            JobState? state = await Get("getState", () => store.GetStateAsync("far")).ConfigureAwait(false);
            Eq("the state is there", state != null, true);
            Eq("the state's 1.5 counted as 0, then the timeout and the alert each wrote it", state!.Version, (long?)2L);
            Eq("the timeout counted", state.ConsecutiveFailures, 1L);
            Eq("the alerts sent", Types(c.Sent), "[stuck]");
            Eq(
                "the stuck alert's first line",
                c.Sent.First().Message.Split('\n')[0],
                "Started before 0001-01-01 00:00:00 UTC and never reported finishing. Marked as timed out after 104249991d 8h.");
        }
    }

    /// <summary>
    /// A check and the reads the dashboard makes over a cron job (<c>0 2 * * *</c> in UTC, grace
    /// 10m) whose last run started at <paramref name="startedAt"/>, one of
    /// <see cref="FarStarts"/>. Nothing reports an error. A cron counts from a start before the
    /// year 1 as from the year's first millisecond, so the first fire of the year 1 was missed;
    /// after 9999 nothing is due again.
    /// </summary>
    /// <exception cref="StoreContractException">At the first thing that goes wrong.</exception>
    public static async Task CronOverForeignRowAsync(IStore store, string prefix, string startedAt, Func<string, Task> sql)
    {
        ArgumentNullException.ThrowIfNull(store);
        ArgumentNullException.ThrowIfNull(startedAt);
        ArgumentNullException.ThrowIfNull(sql);
        await Must("init", () => store.InitAsync()).ConfigureAwait(false);
        await Must("upsertJob", () => store.UpsertJobAsync(
            Definition.FromJson("{\"name\":\"far\",\"schedule\":\"0 2 * * *\",\"timezone\":\"UTC\",\"grace\":\"10m\"}"), 1)).ConfigureAwait(false);
        await Exec(sql, "INSERT INTO " + prefix + "runs (id, job, status, started_at, finished_at, duration_ms) VALUES ('far1', 'far', 'ok', "
            + startedAt + ", " + startedAt + ", 0)").ConfigureAwait(false);
        Client c = Make(store);
        await using (c.Cw.ConfigureAwait(false))
        {
            await c.Cw.CheckAsync().ConfigureAwait(false);
            await c.Cw.JobsWithRunsAsync(20).ConfigureAwait(false);
            await c.Cw.JobSummaryAsync("far").ConfigureAwait(false);
            Eq("nothing reported from " + startedAt, string.Join("; ", c.Errors), "");
            bool missed = startedAt.StartsWith('-');
            Eq("the alerts sent from " + startedAt, Types(c.Sent), missed ? "[missed]" : "[]");
            if (missed)
            {
                string message = c.Sent.First().Message;
                Eq("the missed alert from " + startedAt + ": " + message, message.StartsWith("Due 0001-01-01 02:00:00 UTC ", StringComparison.Ordinal), true);
            }
        }
    }
}

/// <summary>
/// The foreign-row checks <c>ServerStoreTests</c> run over a server's raw rows: fixture helpers,
/// not part of the 1.x promise, which covers <see cref="StoreContract.RunAsync"/>,
/// <see cref="StoreReplay"/> and <see cref="FinishOnce"/>.
/// </summary>
[Obsolete("A fixture helper of the port's own tests, public by accident. It still works, and is removed in 1.0.")]
public static class ForeignRows
{
    /// <summary>The far start times the checks write.</summary>
    public static IReadOnlyList<string> FarStarts => ForeignRowChecks.FarStarts;

    /// <summary>A check over foreign rows written with <paramref name="sql"/>.</summary>
    public static Task CheckOverForeignRowsAsync(IStore store, string prefix, Func<string, Task> sql) =>
        ForeignRowChecks.CheckOverForeignRowsAsync(store, prefix, sql);

    /// <summary>A cron job's check over a foreign row that started at <paramref name="startedAt"/>.</summary>
    public static Task CronOverForeignRowAsync(IStore store, string prefix, string startedAt, Func<string, Task> sql) =>
        ForeignRowChecks.CronOverForeignRowAsync(store, prefix, startedAt, sql);
}
