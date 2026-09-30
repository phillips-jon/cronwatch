using System;
using System.Threading;
using System.Threading.Tasks;
using Cronwatch;
using Microsoft.Data.Sqlite;

// Opens a run of the job "long" on the SQLite file named by the first argument, logs a line in
// it, prints "started", and ends the process with Environment.Exit while the run's function is
// still going. The client's process-exit hook records the run failed.
var source = SqliteFactory.Instance.CreateDataSource("Data Source=" + args[0] + ";Pooling=False");
var cw = new CronwatchClient(new CronwatchOptions
{
    Store = SqlStore.Sqlite(source),
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
await started.Task;
Console.Out.Write("started\n");
Console.Out.Flush();
Environment.Exit(3);
