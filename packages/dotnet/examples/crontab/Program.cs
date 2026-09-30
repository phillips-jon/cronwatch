// A job and its check run from two crontab lines, on one SQLite file:
//
//   0 2 * * *  dotnet /app/Crontab.dll nightly-report
//   * * * * *  dotnet /app/Crontab.dll cronwatch check
//
// The first runs the job as a recorded run and exits 1 when it fails, so cron mails the failure
// too; the second checks every job for missed and stuck runs and sends what it finds. Both make
// the client the same way, so the check knows the job's schedule. CRONWATCH_DB names the file
// (cronwatch.db by default).
using System;
using System.IO;
using System.Threading.Tasks;
using Cronwatch;
using Microsoft.Data.Sqlite;

static CronwatchClient MakeClient()
{
    string file = Environment.GetEnvironmentVariable("CRONWATCH_DB") ?? "cronwatch.db";
    var cw = new CronwatchClient(new CronwatchOptions
    {
        Store = SqlStore.Sqlite(SqliteFactory.Instance.CreateDataSource("Data Source=" + file)),
    });
    cw.Job("nightly-report", new JobOptions { Schedule = "0 2 * * *", Timezone = "UTC", Grace = "15m", Expect = "Report written" });
    return cw;
}

if (args is ["cronwatch", .. var rest])
{
    return await CronwatchCli.RunAsync(MakeClient, rest, Console.Out, Console.Error);
}

if (args is ["nightly-report"])
{
    await using CronwatchClient cw = MakeClient();
    try
    {
        await cw.Job("nightly-report").RunAsync(async (job, ct) =>
        {
            if (Environment.GetEnvironmentVariable("REPORT_FAILS") == "1")
            {
                throw new IOException("the reports disk is full");
            }
            await Task.Delay(10, ct);
            job.Log("Report written: /var/reports/nightly.csv");
        });
        return 0;
    }
    catch (IOException e)
    {
        await Console.Error.WriteAsync("nightly-report failed: " + e.Message + "\n");
        return 1;
    }
}

await Console.Error.WriteAsync("usage: Crontab nightly-report | cronwatch check\n");
return 2;
