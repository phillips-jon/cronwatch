using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.Diagnostics;
using System.Reflection;
using System.Threading;
using System.Threading.Tasks;
using Cronwatch.Bridge;
using Hangfire;
using Hangfire.Storage;
using CronwatchJob = Cronwatch.Job;
using HangfireJob = Hangfire.Common.Job;

namespace Cronwatch.Hangfire;

/// <summary>
/// CronWatch for Hangfire 1.8: every attempt of a watched job is recorded as a run, so a job that
/// fails, runs late, never runs, gets stuck, or runs slow is reported, and every recurring job is
/// declared as a CronWatch job on its cron.
/// <code>
/// GlobalConfiguration.Configuration.UseInMemoryStorage().UseCronwatch(cw);
/// CronwatchHangfire.ScheduleCheck(); // a check every minute, once per cluster
/// </code>
/// </summary>
/// <remarks>
/// A server filter (<see cref="CronwatchHangfireFilter"/>, added to
/// <see cref="GlobalJobFilters.Filters"/>) opens a run as Hangfire is about to perform a job
/// (trigger <c>hangfire</c>, id <c>hangfire:&lt;app&gt;:&lt;job id&gt;:&lt;attempt&gt;</c>, the attempt
/// counted from 0 in the job parameter <see cref="AttemptParameter"/>) and closes it when Hangfire
/// says the job was performed, so each retry, and each requeue, is a run of its own. One
/// integration watches Hangfire in a process, since its filters are global: starting another
/// stops the one before.
/// <see cref="CronwatchClient.Current"/> and <c>job.Log</c> work inside the job's method. A job its
/// server's shutdown stops is given back, as Hangfire puts it back in its queue; one whose type or
/// arguments no longer load is recorded failed from its state change. Recurring jobs are read from
/// the storage when watching starts and every minute, each declared on its cron in its zone, tagged
/// <c>hangfire</c> and <c>hangfire:&lt;app&gt;</c>. A job that is not recurring is watched only when
/// named (<see cref="CronwatchJobAttribute"/> or <see cref="CronwatchHangfireOptions.Named"/>).
/// </remarks>
[DebuggerDisplay("{ToString(),nq}")]
public sealed class CronwatchHangfire : IDisposable
{
    /// <summary>The tag every job this integration declares carries.</summary>
    public const string Tag = "hangfire";

    /// <summary>The trigger of the runs it records.</summary>
    public const string Trigger = "hangfire";

    /// <summary>
    /// The job parameter that counts the attempts CronWatch has seen of a job, the last part of
    /// each run's id.
    /// </summary>
    public const string AttemptParameter = "CronwatchAttempt";

    /// <summary>The check's recurring job id, whose runs are never a job.</summary>
    public const string CheckJobId = "cronwatch-check";

    private const string Scheduler = "Hangfire";

    private static CronwatchHangfire? s_active;

    /// <summary>The longest a timer waits at once (2^31 - 1 ms); a longer read interval is held to it.</summary>
    private static readonly TimeSpan LongestWait = TimeSpan.FromMilliseconds(int.MaxValue);

    private readonly CronwatchClient _cw;
    private readonly CronwatchHangfireOptions _options;
    private readonly FireTimeChecks _checks = new();
    private readonly CancellationTokenSource _stop = new();
    private readonly ConcurrentDictionary<Task, byte> _recording = new();
    private readonly Task _reading;
    private int _disposed;

    private CronwatchHangfire(CronwatchClient cw, CronwatchHangfireOptions options)
    {
        _cw = cw;
        _options = options;
        Watch = new Watch(cw, Tag, options.App, Scheduler);
        Filter = new CronwatchHangfireFilter(this);
        // One integration per process: Hangfire's filters are global, so an earlier one left in
        // place (a host built again in the same process) would open every attempt a second time,
        // under the same id, on a client that may be disposed.
        Interlocked.Exchange(ref s_active, null)?.Dispose();
        GlobalJobFilters.Filters.Add(Filter);
        _reading = CronwatchClient_WithoutFlow(ReadLoopAsync);
        Volatile.Write(ref s_active, this);
    }

    /// <summary>
    /// Watches Hangfire: the filter is added to <see cref="GlobalJobFilters.Filters"/>, so every
    /// attempt from now on is recorded, and the recurring jobs are read now and every minute.
    /// Call it before the server starts. <see cref="Dispose"/> stops it, and so does starting
    /// another in the same process.
    /// </summary>
    public static CronwatchHangfire Start(CronwatchClient cw, CronwatchHangfireOptions? options = null)
    {
        ArgumentNullException.ThrowIfNull(cw);
        return new CronwatchHangfire(cw, options ?? new CronwatchHangfireOptions());
    }

    /// <summary>
    /// Adds the recurring job <see cref="CheckJobId"/> every minute, unless it is there already: a
    /// sync (the recurring jobs declared again, the declarations written, and jobs gone from Hangfire
    /// declared again without their schedule, within 30 seconds) and a CronWatch check, once per
    /// minute across every server sharing the storage, in place of <c>cw.StartChecking()</c> on each.
    /// </summary>
    public static void ScheduleCheck(IRecurringJobManager manager, string cron = "* * * * *")
    {
        ArgumentNullException.ThrowIfNull(manager);
        manager.AddOrUpdate(CheckJobId, HangfireJob.FromExpression(() => CronwatchCheckJob.RunAsync()), cron);
    }

    /// <summary><see cref="ScheduleCheck(IRecurringJobManager, string)"/> on the storage's default manager.</summary>
    public static void ScheduleCheck() => ScheduleCheck(new RecurringJobManager());

    /// <summary>The integration running in this process, which the check job uses, or null.</summary>
    internal static CronwatchHangfire? Active => Volatile.Read(ref s_active);

    /// <summary>The watch that declares Hangfire's recurring jobs, for an integration built on this one.</summary>
    public Watch Watch { get; }

    /// <summary>The client runs are recorded on.</summary>
    public CronwatchClient Client => _cw;

    /// <summary>The filter this integration added to <see cref="GlobalJobFilters.Filters"/>.</summary>
    public CronwatchHangfireFilter Filter { get; }

    /// <summary>The fire-time checks kept per cron, for the tests.</summary>
    internal FireTimeChecks Checks => _checks;

    internal bool Disposed => Volatile.Read(ref _disposed) != 0;

    private static Task CronwatchClient_WithoutFlow(Func<Task> work)
    {
        using (ExecutionContext.SuppressFlow())
        {
            return Task.Run(work);
        }
    }

    // ---- reading the recurring jobs

    private static string Label(string id) => "Hangfire recurring job " + Json.Stringify(id);

    private JobOptions OptionsFor(string name) =>
        _options.Jobs.TryGetValue(name, out JobOptions? given) ? given : new JobOptions();

    /// <summary>The recurring jobs, one entry each, the check's own left out.</summary>
    internal List<Entry> Entries()
    {
        _checks.BeginRead();
        try
        {
            JobStorage storage = _options.Storage ?? JobStorage.Current;
            List<RecurringJobDto> jobs;
            using (IStorageConnection connection = storage.GetConnection())
            {
                jobs = connection.GetRecurringJobs();
            }
            long now = _cw.NowMs;
            var output = new List<Entry>();
            foreach (RecurringJobDto dto in jobs)
            {
                if (dto.Removed || dto.Id == CheckJobId)
                {
                    continue;
                }
                string label = Label(dto.Id);
                if (!SchedulerBridge.ValidName(dto.Id))
                {
                    Watch.ReportOnce(
                        "cronwatch: " + label + " is not a CronWatch job name (1 to 120 letters, digits, \".\", \"_\", \":\", or \"-\"), so it is not watched; rename it",
                        "declaring " + label);
                    continue;
                }
                output.Add(EntryOf(dto, label, now));
            }
            return output;
        }
        finally
        {
            _checks.EndRead();
        }
    }

    private Entry EntryOf(RecurringJobDto dto, string label, long now)
    {
        string schedule = "";
        string zone = "";
        string? problem = null;
        (string? iana, TimeZoneInfo? info) = HangfireCrons.Zone(dto.TimeZoneId);
        if (iana == null || info == null)
        {
            problem = "cronwatch: " + label + " runs in the time zone " + Json.Stringify(dto.TimeZoneId ?? "")
                + ", which this system does not know, so it is watched without a schedule";
        }
        else if (string.IsNullOrWhiteSpace(dto.Cron))
        {
            problem = "cronwatch: " + label + " has no cron, so it is watched without a schedule";
        }
        else
        {
            var (checkedSchedule, checkedProblem) = _checks.Check(label, dto.Cron, iana, now, () => HangfireCrons.Convert(label, dto.Cron, iana, info, now));
            if (checkedSchedule != null)
            {
                schedule = checkedSchedule;
                zone = iana;
            }
            problem = checkedProblem;
        }
        if (problem == null && (dto.LoadException != null || !string.IsNullOrEmpty(dto.Error)))
        {
            problem = "cronwatch: Hangfire reports " + label + " as broken ("
                + (dto.LoadException?.InnerException?.Message ?? dto.LoadException?.Message ?? dto.Error) + ")";
        }
        return new Entry(dto.Id, label, schedule, zone, problem, _options.JobDefaults, OptionsFor(dto.Id));
    }

    /// <summary>Reads the recurring jobs and declares them; a failure is reported once.</summary>
    internal void Read()
    {
        try
        {
            Watch.Declare(Entries());
        }
        catch (InvalidOperationException e) when (_options.Storage == null && e.Source == "Hangfire.Core")
        {
            // JobStorage.Current is not set yet: the app sets its storage after watching starts.
            Watch.ReportOnce("cronwatch: " + e.Message, "hangfire");
        }
        catch (Exception e)
        {
            _cw.ReportError(e, "hangfire");
        }
    }

    private async Task ReadLoopAsync()
    {
        CancellationToken stop = _stop.Token;
        TimeSpan every = _options.ReadEvery < LongestWait ? _options.ReadEvery : LongestWait;
        while (!stop.IsCancellationRequested)
        {
            Read();
            try
            {
                await Task.Delay(every, stop).ConfigureAwait(false);
            }
            catch (OperationCanceledException)
            {
                return;
            }
        }
    }

    /// <summary>
    /// Declares the recurring jobs as they are now, waits for the declarations to be written, and
    /// declares again without its schedule each job of this app's the store holds with a schedule
    /// that Hangfire no longer has. The check job runs it before each check.
    /// </summary>
    /// <exception cref="CronwatchException">Naming what failed.</exception>
    public async Task SyncAsync()
    {
        Watch.Declare(Entries());
        await Watch.SettleAsync(SchedulerBridge.SyncTimeout).ConfigureAwait(false);
        await Watch.UnscheduleAsync().ConfigureAwait(false);
    }

    /// <summary>
    /// Waits until what was declared has been written to the store, at most
    /// <paramref name="timeout"/>, for tests and a clean exit. Says whether it was.
    /// </summary>
    public Task<bool> SettleAsync(TimeSpan timeout) => Watch.SettleAsync(timeout);

    /// <summary>The check job's work: <see cref="SyncAsync"/> within 30 seconds, then a check. Never throws.</summary>
    internal async Task CheckNowAsync()
    {
        await SchedulerBridge.SyncWithinAsync(_cw, SchedulerBridge.SyncTimeout, "hangfire", SyncAsync).ConfigureAwait(false);
        try
        {
            await _cw.CheckAsync().ConfigureAwait(false);
        }
        catch (Exception e)
        {
            _cw.ReportError(e, "hangfire");
        }
    }

    // ---- runs

    /// <summary>
    /// The CronWatch name of a Hangfire job, or null when it is not watched: its recurring job's
    /// id, else the name its method's <see cref="CronwatchJobAttribute"/> or
    /// <see cref="CronwatchHangfireOptions.Named"/> gives it.
    /// </summary>
    internal string? NameOf(HangfireJob? job, string? recurringJobId)
    {
        if (recurringJobId == CheckJobId || job?.Type == typeof(CronwatchCheckJob))
        {
            return null;
        }
        string? name = recurringJobId;
        if (string.IsNullOrEmpty(name) && job != null)
        {
            name = job.Method.GetCustomAttribute<CronwatchJobAttribute>()?.Name
                ?? (_options.Named.TryGetValue(job.Type.FullName + "." + job.Method.Name, out string? named) ? named : null);
        }
        if (string.IsNullOrEmpty(name))
        {
            return null;
        }
        if (!SchedulerBridge.ValidName(name))
        {
            Watch.ReportOnce(
                "cronwatch: the Hangfire job " + Json.Stringify(name) + " is not a CronWatch job name (1 to 120 letters, digits, \".\", \"_\", \":\", or \"-\"), so it is not watched; rename it",
                "hangfire");
            return null;
        }
        return name;
    }

    /// <summary>
    /// The run's id: the app and the job's attempt, since a job id is unique only within one
    /// storage and two apps may share a CronWatch store.
    /// </summary>
    internal string RunId(string jobId, int attempt) =>
        "hangfire:" + Watch.AppSlug + ":" + jobId + ":" + attempt.ToString(System.Globalization.CultureInfo.InvariantCulture);

    /// <summary>The job a run of <paramref name="name"/> belongs to: declared from a recurring job, else declared from the store.</summary>
    internal async Task<CronwatchJob?> JobAsync(string name)
    {
        if (Watch.Job(name) is { } known)
        {
            return known;
        }
        return await Watch.FallbackAsync(name, Merge(_options.JobDefaults, OptionsFor(name))).ConfigureAwait(false);
    }

    /// <summary>
    /// <paramref name="first"/> then <paramref name="later"/>, as the SDK spreads one options
    /// object over another: a field both set keeps the first's place and takes the later value.
    /// </summary>
    internal static JobOptions Merge(JobOptions? first, JobOptions later)
    {
        var merged = new JobOptions { Expect = later.Expect ?? first?.Expect };
        foreach (JobOptions? options in new[] { first, later })
        {
            if (options == null)
            {
                continue;
            }
            Definition fields = options.Describe("x");
            foreach (string key in fields.Keys)
            {
                if (key is not ("name" or "expect"))
                {
                    merged.Field(key, fields.Get(key));
                }
            }
        }
        return merged;
    }

    /// <summary>Records, on a task of its own, a failed attempt of a job Hangfire could not load.</summary>
    internal void RecordLoadFailure(string name, string runId, string error)
    {
        Task work = CronwatchClient_WithoutFlow(async () =>
        {
            try
            {
                if (await JobAsync(name).ConfigureAwait(false) == null)
                {
                    return;
                }
                if (await _cw.GetRunAsync(runId).ConfigureAwait(false) != null)
                {
                    return; // recorded already, by the server filter or an earlier election
                }
                long now = _cw.NowMs;
                Run run = Run.Running(runId, name, now, Trigger) with
                {
                    Status = RunStatus.Failed,
                    FinishedAt = now,
                    DurationMs = 0,
                    Error = error,
                };
                await _cw.RecordRunAsync(run).ConfigureAwait(false);
            }
            catch (Exception e)
            {
                _cw.ReportError(e, "recording " + name);
            }
        });
        _recording.TryAdd(work, 0);
        _ = work.ContinueWith(t => _recording.TryRemove(t, out _), CancellationToken.None, TaskContinuationOptions.ExecuteSynchronously, TaskScheduler.Default);
    }

    /// <summary>Waits for the load failures being recorded, for tests and a clean exit.</summary>
    internal Task RecordedAsync() => Task.WhenAll(_recording.Keys);

    /// <summary>
    /// Stops watching: the filter is taken off <see cref="GlobalJobFilters.Filters"/>, so no attempt
    /// is recorded from now on, and the recurring jobs are no longer read. A run open now is still
    /// closed when its job ends. Leaves the client and Hangfire running.
    /// </summary>
    public void Dispose()
    {
        if (Interlocked.Exchange(ref _disposed, 1) != 0)
        {
            return;
        }
        GlobalJobFilters.Filters.Remove(Filter);
        Interlocked.CompareExchange(ref s_active, null, this);
        _stop.Cancel();
        try
        {
            _reading.Wait(TimeSpan.FromSeconds(5));
        }
        catch (AggregateException)
        {
            // The loop reports its own failures; it ends on the cancellation.
        }
        _stop.Dispose();
    }

    /// <summary>Names the app's tag.</summary>
    public override string ToString() => "CronwatchHangfire(" + Watch.AppTag + ")";
}
