using System;
using System.Collections.Generic;
using System.Threading;
using System.Threading.Tasks;
using Cronwatch;
using Microsoft.Data.Sqlite;

// Opens a run of the job "long" on the SQLite file named by the first argument, logs a line in
// it, prints "started", and ends the process with Environment.Exit while the run's function is
// still going. The client's process-exit hook records the run failed. Given "atstart" as the
// second argument, the process begins to stop the moment the run's row is written, before the
// client has gone on to the function: the hook must already know of the run.
var source = SqliteFactory.Instance.CreateDataSource("Data Source=" + args[0] + ";Pooling=False");
bool atStart = args.Length > 1 && args[1] == "atstart";
IStore store = SqlStore.Sqlite(source);
if (atStart)
{
    store = new ExitAfterInsert((SqlStore)store);
}
var cw = new CronwatchClient(new CronwatchOptions
{
    Store = store,
    Alerts = [],
    OnWarning = _ => { },
});
var started = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
_ = cw.Job("long").RunAsync(async (job, ct) =>
{
    job.Log("working");
    started.SetResult();
    await Task.Delay(Timeout.Infinite, CancellationToken.None);
});
if (atStart)
{
    await Task.Delay(Timeout.Infinite);
}
await started.Task;
Console.Out.Write("started\n");
Console.Out.Flush();
Environment.Exit(3);

/// <summary>
/// A SQLite store that, once a run's row is written, starts the process's exit on another thread
/// and holds the insert back for half a second, so the process is stopping before the client has
/// seen the insert return.
/// </summary>
internal sealed class ExitAfterInsert(SqlStore inner) : IStore, IConditionalRunStore, IStateCasStore
{
    public async Task InsertRunAsync(Run run, CancellationToken cancellationToken = default)
    {
        await inner.InsertRunAsync(run, cancellationToken);
        Console.Out.Write("started\n");
        Console.Out.Flush();
        new Thread(() => Environment.Exit(3)).Start();
        Thread.Sleep(500);
    }

    public Task InitAsync(CancellationToken cancellationToken = default) => inner.InitAsync(cancellationToken);

    public Task UpsertJobAsync(Definition definition, long now, CancellationToken cancellationToken = default) => inner.UpsertJobAsync(definition, now, cancellationToken);

    public Task<StoredJob?> GetJobAsync(string name, CancellationToken cancellationToken = default) => inner.GetJobAsync(name, cancellationToken);

    public Task<IReadOnlyList<StoredJob>> ListJobsAsync(CancellationToken cancellationToken = default) => inner.ListJobsAsync(cancellationToken);

    public Task DeleteJobAsync(string name, CancellationToken cancellationToken = default) => inner.DeleteJobAsync(name, cancellationToken);

    public Task UpdateRunAsync(Run run, CancellationToken cancellationToken = default) => inner.UpdateRunAsync(run, cancellationToken);

    public Task<Run?> GetRunAsync(string id, CancellationToken cancellationToken = default) => inner.GetRunAsync(id, cancellationToken);

    public Task<IReadOnlyList<Run>> ListRunsAsync(string job, int limit, CancellationToken cancellationToken = default) => inner.ListRunsAsync(job, limit, cancellationToken);

    public Task<Run?> LastRunAsync(string job, CancellationToken cancellationToken = default) => inner.LastRunAsync(job, cancellationToken);

    public Task<IReadOnlyList<Run>> RunningRunsAsync(CancellationToken cancellationToken = default) => inner.RunningRunsAsync(cancellationToken);

    public Task<JobState?> GetStateAsync(string job, CancellationToken cancellationToken = default) => inner.GetStateAsync(job, cancellationToken);

    public Task SetStateAsync(JobState state, CancellationToken cancellationToken = default) => inner.SetStateAsync(state, cancellationToken);

    public Task<long> PruneAsync(long before, CancellationToken cancellationToken = default) => inner.PruneAsync(before, cancellationToken);

    public Task<bool> UpdateRunIfAsync(Run run, IReadOnlyList<RunStatus> from, CancellationToken cancellationToken = default) => inner.UpdateRunIfAsync(run, from, cancellationToken);

    public Task<bool> CompareAndSetStateAsync(JobState state, long expected, CancellationToken cancellationToken = default) => inner.CompareAndSetStateAsync(state, expected, cancellationToken);
}
