using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.Security.Cryptography;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using Cronwatch.Bridge;
using Quartz;

namespace Cronwatch.Quartz;

/// <summary>
/// CronWatch for a Quartz.NET 4 scheduler: every job the scheduler holds with a trigger is
/// declared as a CronWatch job with its schedule, and every firing is recorded as a run, so a job
/// that fails, runs late, never runs, gets stuck or runs slow is reported.
/// </summary>
/// <remarks>
/// <para>
/// With the host's container, <c>services.AddQuartz(q =&gt; q.UseCronwatch())</c>; without one,
/// <see cref="WatchAsync"/> on a scheduler the app built. A global <see cref="IJobListener"/> opens
/// a run when Quartz is about to execute a job (trigger <c>quartz</c>, id
/// <c>quartz:&lt;app&gt;:&lt;scheduler instance&gt;:&lt;fire instance id&gt;:&lt;refire count&gt;</c>,
/// the instance given a random part of its own when the job store is not clustered) and closes it
/// when Quartz says the job was executed, failed with the exception the job threw. A refire is a
/// new run. A vetoed firing opens nothing, and one another listener stopped before the job ran is
/// given back.
/// </para>
/// <para>
/// Jobs are named after their <see cref="JobKey"/>: <c>nightlyReport</c> in the <c>DEFAULT</c>
/// group, <c>reports.nightly</c> for <c>nightly</c> in <c>reports</c>. A job with one cron trigger
/// is declared on its expression in the trigger's zone (a <c>?</c> as <c>*</c>), checked against
/// Quartz's own fire times: one Quartz reads differently (a day of the week by number, which Quartz
/// counts from 1 for Sunday) is reported once and watched without a schedule. A simple trigger
/// repeating forever is declared <c>every &lt;interval&gt;</c>; any other trigger, a trigger with a
/// calendar, or several triggers on different schedules is a job without a schedule. A job removed
/// from the scheduler keeps its runs and is declared again without its schedule.
/// </para>
/// </remarks>
[DebuggerDisplay("{ToString(),nq}")]
public sealed class CronwatchQuartz : IAsyncDisposable
{
    /// <summary>The tag every job this integration declares carries.</summary>
    public const string Tag = "quartz";

    /// <summary>The trigger of the runs it records.</summary>
    public const string Trigger = "quartz";

    /// <summary>The error of a run a recovered firing finishes.</summary>
    public const string Recovered = "Quartz recovered the job after its node stopped";

    /// <summary>The check job's key, whose runs are never a job.</summary>
    public static readonly JobKey CheckJobKey = new("cronwatch-check", "cronwatch");

    /// <summary>Where the scheduler's context keeps the integration, for the check job.</summary>
    internal const string ContextKey = "Cronwatch.Quartz.CronwatchQuartz";

    internal const string ListenerName = "Cronwatch.Quartz";
    private const string Scheduler = "Quartz";

    /// <summary>How far a dead node's run may have started from the firing recovered.</summary>
    private const long RecoverySlackMs = 60_000;

    /// <summary>The longest a timer waits at once (2^31 - 1 ms); a longer read interval is held to it.</summary>
    private static readonly TimeSpan LongestWait = TimeSpan.FromMilliseconds(int.MaxValue);

    /// <summary>The runs open on each firing, by its context: what the middleware and <c>CronwatchRun()</c> read.</summary>
    private static readonly System.Runtime.CompilerServices.ConditionalWeakTable<IJobExecutionContext, Firing> Firings = new();

    private readonly CronwatchClient _cw;
    private readonly CronwatchQuartzOptions _options;
    private readonly Watch _watch;
    private readonly FireTimeChecks _checks = new();

    /// <summary>The firings open now, by fire instance id, for a listener's error that names only the id.</summary>
    private readonly ConcurrentDictionary<string, Firing> _open = new(StringComparer.Ordinal);

    private readonly SemaphoreSlim _wake = new(0, 1);
    private readonly CancellationTokenSource _stop = new();
    private readonly Lock _lock = new();
    private IScheduler? _scheduler;
    private string _instancePart = "";
    private Task? _loop;
    private int _closed;

    internal CronwatchQuartz(CronwatchClient cw, CronwatchQuartzOptions options, string? hostApp)
    {
        _cw = cw ?? throw new ArgumentNullException(nameof(cw));
        _options = options ?? throw new ArgumentNullException(nameof(options));
        _watch = new Watch(cw, Tag, options.App is { Length: > 0 } app ? app : SchedulerBridge.AppName(hostApp), Scheduler);
        JobListener = new Listener(this);
        SchedulerListener = new Changes(this);
    }

    /// <summary>A run open on one firing, and the failure of its attempt, which a refire reports.</summary>
    internal sealed class Firing(ObservedRun run)
    {
        public ObservedRun Run { get; } = run;

        public Exception? Failure { get; set; }
    }

    internal IJobListener JobListener { get; }

    internal ISchedulerListener SchedulerListener { get; }

    /// <summary>The watch that declares this scheduler's jobs, for an integration built on this one.</summary>
    public Watch Watch => _watch;

    /// <summary>The client runs are recorded on.</summary>
    public CronwatchClient Client => _cw;

    /// <summary>The crons' checks against Quartz's own fire times, kept between reads.</summary>
    internal FireTimeChecks Checks => _checks;

    /// <summary>How long a sync the check job starts may take; the tests shorten it.</summary>
    internal TimeSpan SyncTimeout { get; set; } = SchedulerBridge.SyncTimeout;

    private bool Closed => Volatile.Read(ref _closed) != 0;

    /// <summary>
    /// Watches <paramref name="scheduler"/>, one the app built without the host's container: its
    /// jobs are declared now, from its triggers, and every firing from now on is recorded. Call it
    /// before the scheduler starts, so no firing goes unrecorded. <see cref="CronwatchClient.Current"/>
    /// is not set inside a job this way (Quartz's middleware is added only when a scheduler is
    /// built); a job reads its run with <c>context.CronwatchRun()</c>. <see cref="DisposeAsync"/>
    /// stops it.
    /// </summary>
    public static async Task<CronwatchQuartz> WatchAsync(CronwatchClient cw, IScheduler scheduler, CronwatchQuartzOptions? options = null, CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(scheduler);
        var q = new CronwatchQuartz(cw, options ?? new CronwatchQuartzOptions(), null);
        scheduler.ListenerManager.AddJobListener(q.JobListener, [Matchers.AllJobs()]);
        scheduler.ListenerManager.AddSchedulerListener(q.SchedulerListener);
        await q.AttachAsync(scheduler, cancellationToken).ConfigureAwait(false);
        if (q._options.ScheduleCheck)
        {
            await ScheduleCheckAsync(scheduler, q._options.CheckEvery, cancellationToken).ConfigureAwait(false);
        }
        return q;
    }

    /// <summary>
    /// Schedules <see cref="CronwatchCheckJob"/> on <paramref name="scheduler"/> every
    /// <paramref name="every"/> (a minute by default), unless it is scheduled already: a sync and a
    /// CronWatch check, once per firing across a cluster sharing a job store, in place of the
    /// client's own interval on every node.
    /// </summary>
    public static async Task ScheduleCheckAsync(IScheduler scheduler, TimeSpan? every = null, CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(scheduler);
        if (await scheduler.Exists(CheckJobKey, cancellationToken).ConfigureAwait(false))
        {
            return;
        }
        IJobDetail job = CheckJobDetail();
        ITrigger trigger = CheckTrigger(scheduler.TimeProvider, every ?? TimeSpan.FromMinutes(1));
        try
        {
            await scheduler.ScheduleJob(job, trigger, default, cancellationToken).ConfigureAwait(false);
        }
        catch (ObjectAlreadyExistsException)
        {
            // Another node scheduled it first.
        }
    }

    internal static IJobDetail CheckJobDetail() =>
        JobBuilder.Create<CronwatchCheckJob>()
            .WithIdentity(CheckJobKey)
            .WithDescription("CronWatch's check: missed and stuck runs, retries, pruning")
            .StoreDurably(true)
            .Build();

    internal static ITrigger CheckTrigger(TimeProvider time, TimeSpan every) =>
        TriggerBuilder.Create(time)
            .WithIdentity(new TriggerKey(CheckJobKey.Name, CheckJobKey.Group))
            .ForJob(CheckJobKey)
            .StartNow()
            .WithSchedule(SimpleScheduleBuilder.Create().WithInterval(every).RepeatForever().WithMisfireInstruction(SimpleTriggerMisfireInstruction.NextWithRemainingCount))
            .Build();

    /// <summary>
    /// Takes the scheduler this integration watches: its instance id, whether it is clustered, its
    /// jobs, and the loop that reads them again. Once; later calls do nothing.
    /// </summary>
    internal async Task AttachAsync(IScheduler scheduler, CancellationToken cancellationToken)
    {
        lock (_lock)
        {
            if (_scheduler != null || Closed)
            {
                return;
            }
            _scheduler = scheduler;
        }
        bool clustered = false;
        try
        {
            clustered = (await scheduler.GetMetadata(cancellationToken).ConfigureAwait(false)).JobStoreClustered;
        }
        catch (Exception e)
        {
            _cw.ReportError(e, "quartz");
        }
        string id = scheduler.SchedulerInstanceId;
        string part = clustered ? id : id + "." + Convert.ToHexStringLower(RandomNumberGenerator.GetBytes(4));
        _instancePart = part.Length > 100 ? "h" + Sha256(part)[..32] : part;
        scheduler.Context[ContextKey] = this;
        await ReadAsync(cancellationToken).ConfigureAwait(false);
        // Started without the caller's flow, so no scheduler callback's context lives on in it.
        using (ExecutionContext.SuppressFlow())
        {
            _loop = Task.Run(ReadLoopAsync, CancellationToken.None);
        }
    }

    /// <summary>
    /// Declares the scheduler's jobs as they are now, waits for the declarations to be written, and
    /// declares again without its schedule each job of this app's the store holds with a schedule
    /// that the scheduler no longer has. The check job runs it before each check.
    /// </summary>
    /// <exception cref="CronwatchException">Naming what failed.</exception>
    public async Task SyncAsync(CancellationToken cancellationToken = default)
    {
        IScheduler scheduler = _scheduler ?? throw new CronwatchException("the integration is not attached to a scheduler yet");
        IReadOnlyList<Entry> entries;
        try
        {
            entries = await EntriesAsync(scheduler, cancellationToken).ConfigureAwait(false);
        }
        catch (Exception e) when (e is not OperationCanceledException)
        {
            throw new CronwatchException("reading the scheduler's jobs: " + e.Message, e);
        }
        _watch.Declare(entries);
        await _watch.SettleAsync(SchedulerBridge.SyncTimeout).ConfigureAwait(false);
        await _watch.UnscheduleAsync().ConfigureAwait(false);
    }

    /// <summary>Waits until what was declared has been written to the store, at most <paramref name="timeout"/>. Says whether it was.</summary>
    public Task<bool> SettleAsync(TimeSpan timeout) => _watch.SettleAsync(timeout);

    /// <summary>The check job's work: <see cref="SyncAsync"/> within 30 seconds, then a check. Never throws.</summary>
    internal async Task CheckNowAsync(CancellationToken cancellationToken)
    {
        await SchedulerBridge.SyncWithinAsync(_cw, SyncTimeout, "quartz", () => SyncAsync(CancellationToken.None)).ConfigureAwait(false);
        try
        {
            await _cw.CheckAsync(cancellationToken).ConfigureAwait(false);
        }
        catch (Exception e)
        {
            _cw.ReportError(e, "quartz");
        }
    }

    /// <summary>
    /// Stops watching: no firing is recorded from now on, its jobs are no longer read, and the
    /// listeners are taken off the scheduler, the job listener once the firings open now have
    /// ended, so their runs are still closed when their jobs end. Leaves the client and the
    /// scheduler running.
    /// </summary>
    public async ValueTask DisposeAsync()
    {
        if (Interlocked.Exchange(ref _closed, 1) != 0)
        {
            return;
        }
        await _stop.CancelAsync().ConfigureAwait(false);
        IScheduler? scheduler;
        lock (_lock)
        {
            scheduler = _scheduler;
        }
        if (scheduler != null)
        {
            try
            {
                // The job listener stays until the firings open now have ended, since Quartz tells
                // only the listeners it holds then that a job was executed.
                scheduler.ListenerManager.RemoveSchedulerListener(ListenerName);
                if (scheduler.Context.TryGetValue(ContextKey, out object? mine) && ReferenceEquals(mine, this))
                {
                    scheduler.Context.Remove(ContextKey);
                }
            }
            catch (Exception e)
            {
                _cw.ReportError(e, "quartz");
            }
            LetGo();
        }
        if (_loop is { } loop)
        {
            try
            {
                await loop.ConfigureAwait(false);
            }
            catch (Exception)
            {
                // The loop reports its own failures; it ends when stopped.
            }
        }
        _stop.Dispose();
        _wake.Dispose();
    }

    // ---- reading the scheduler's jobs

    /// <summary>A job's CronWatch name: its name in the default group, else <c>group.name</c>.</summary>
    internal static string NameOf(JobKey key) =>
        key.Group == JobKey.DefaultGroup ? key.Name : key.Group + "." + key.Name;

    private static string Label(string name) => "Quartz job " + Json.Quote(name);

    private JobOptions? OptionsFor(string name) => _options.Jobs.TryGetValue(name, out var given) ? given : null;

    /// <summary>Every job the scheduler holds with a trigger, one entry per trigger.</summary>
    internal async Task<IReadOnlyList<Entry>> EntriesAsync(IScheduler scheduler, CancellationToken cancellationToken)
    {
        var output = new List<Entry>();
        long now = _cw.NowMs;
        List<JobKey> keys = await scheduler.GetJobKeys(GroupMatcher<JobKey>.AnyGroup(), cancellationToken).ConfigureAwait(false);
        keys.Sort((a, b) => string.CompareOrdinal(a.Group + "\0" + a.Name, b.Group + "\0" + b.Name));
        foreach (JobKey key in keys)
        {
            if (key.Equals(CheckJobKey))
            {
                continue;
            }
            List<ITrigger> triggers = await scheduler.GetTriggersOfJob(key, cancellationToken).ConfigureAwait(false);
            if (triggers.Count == 0)
            {
                continue;
            }
            string name = NameOf(key);
            if (!SchedulerBridge.ValidName(name))
            {
                _watch.ReportOnce(
                    "cronwatch: " + Label(name) + " is not a CronWatch job name (1 to 120 letters, digits, \".\", \"_\", \":\" or \"-\"), so it is not watched; rename it",
                    "declaring " + Label(name));
                continue;
            }
            foreach (ITrigger trigger in triggers)
            {
                output.Add(EntryOf(name, trigger, now));
            }
        }
        _checks.EndRead();
        return output;
    }

    private Entry EntryOf(string name, ITrigger trigger, long now)
    {
        string label = Label(name);
        string schedule = "";
        string zone = "";
        string? problem = null;
        string triggerName = Json.Quote(trigger.Key.ToString());
        if (trigger.CalendarName is { } calendar)
        {
            problem = "cronwatch: " + label + "'s trigger " + triggerName + " has the calendar " + Json.Quote(calendar)
                + ", which excludes times CronWatch cannot know, so it is watched without a schedule";
        }
        else if (trigger is ICronTrigger cron)
        {
            TimeZoneInfo tz = cron.TimeZone ?? TimeZoneInfo.Local;
            string? zoneId = IanaId(tz);
            string expression = cron.CronExpressionString ?? "";
            if (zoneId == null)
            {
                problem = "cronwatch: " + label + "'s trigger " + triggerName + " is in the zone " + Json.Quote(tz.Id)
                    + ", which has no IANA name, so it is watched without a schedule";
            }
            else
            {
                var (read, why) = _checks.Check(label, expression, zoneId, now, () => CronOf(label, expression, tz, zoneId, now));
                if (read != null)
                {
                    schedule = read;
                    zone = zoneId;
                }
                else
                {
                    problem = why;
                }
            }
        }
        else if (trigger is ISimpleTrigger simple)
        {
            if (simple.RepeatCount < 0)
            {
                TimeSpan interval = simple.RepeatInterval;
                if (interval < TimeSpan.FromSeconds(1))
                {
                    problem = "cronwatch: " + label + " repeats every " + interval.TotalMilliseconds.ToString(CultureInfo.InvariantCulture)
                        + "ms, more often than CronWatch's shortest schedule of one second, so it is watched without a schedule";
                }
                else
                {
                    schedule = SchedulerBridge.EveryText(interval);
                }
            }
        }
        else
        {
            problem = "cronwatch: " + label + "'s trigger " + triggerName + " is a " + KindOf(trigger)
                + ", which CronWatch cannot follow, so it is watched without a schedule";
        }
        return new Entry(name, label, schedule, zone, problem, _options.JobDefaults, OptionsFor(name));
    }

    private static string KindOf(ITrigger trigger) => trigger switch
    {
        ICalendarIntervalTrigger => "CalendarIntervalTrigger",
        IDailyTimeIntervalTrigger => "DailyTimeIntervalTrigger",
        IRecurrenceTrigger => "RecurrenceTrigger",
        _ => trigger.GetType().Name,
    };

    /// <summary>A zone's IANA name: its own, or a Windows id converted; null when it has none.</summary>
    internal static string? IanaId(TimeZoneInfo tz)
    {
        if (tz.HasIanaId)
        {
            return tz.Id;
        }
        return TimeZoneInfo.TryConvertWindowsIdToIanaId(tz.Id, out string? iana) ? iana : null;
    }

    /// <summary>
    /// A cron trigger's expression as CronWatch reads it: Quartz's six fields as they are (croner
    /// reads seconds first too) but for a <c>?</c>, which is <c>*</c> (croner reads a <c>?</c> as a
    /// day field naming every day), a seventh year field left out when it is <c>*</c> or <c>?</c>,
    /// and kept when it names years, for the check to judge; then checked against Quartz's own fire
    /// times.
    /// </summary>
    internal static string CronOf(string label, string expression, TimeZoneInfo tz, string zoneId, long now)
    {
        string[] fields = expression.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries);
        var kept = new List<string>(fields);
        if (kept.Count == 7 && IsAny(kept[6]))
        {
            kept.RemoveAt(6);
        }
        for (int i = 0; i < kept.Count; i++)
        {
            if (kept[i] == "?")
            {
                kept[i] = "*";
            }
        }
        string expr = string.Join(' ', kept);
        CronExpression quartz;
        try
        {
            quartz = new CronExpression(expression).WithTimeZone(tz);
        }
        catch (Exception e) when (e is FormatException or ArgumentException)
        {
            throw new ScheduleException("cronwatch: " + label + " is " + Json.Quote(expression) + ", which Quartz cannot read: " + e.Message);
        }
        bool daily = fields.Length >= 6 && IsAny(fields[3]) && IsAny(fields[4]) && IsAny(fields[5]) && (fields.Length < 7 || IsAny(fields[6]));
        SchedulerBridge.CheckFires(SchedulerBridge.Walking(at => NextAfter(quartz, at), Scheduler), expr, zoneId, "cronwatch: " + label, Scheduler, daily, now);
        return expr;
    }

    private static long? NextAfter(CronExpression cron, long at) =>
        cron.GetNextValidTimeAfter(DateTimeOffset.FromUnixTimeMilliseconds(at)) is { } next ? next.ToUnixTimeMilliseconds() : null;

    private static bool IsAny(string field) => field == "*" || field == "?";

    /// <summary>Reads the scheduler's jobs and declares them; a failure is reported.</summary>
    private async Task ReadAsync(CancellationToken cancellationToken)
    {
        IScheduler? scheduler = _scheduler;
        if (scheduler == null || Closed)
        {
            return;
        }
        try
        {
            _watch.Declare(await EntriesAsync(scheduler, cancellationToken).ConfigureAwait(false));
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
        {
            // Stopping.
        }
        catch (Exception e)
        {
            _cw.ReportError(e, "quartz");
        }
    }

    /// <summary>
    /// Reads the jobs again whenever the scheduler says they changed and every
    /// <see cref="CronwatchQuartzOptions.ReadEvery"/> besides: the scheduler's own calls come from
    /// inside its locks, so they only ask for a read.
    /// </summary>
    private async Task ReadLoopAsync()
    {
        CancellationToken stop = _stop.Token;
        TimeSpan every = _options.ReadEvery < LongestWait ? _options.ReadEvery : LongestWait;
        while (!stop.IsCancellationRequested)
        {
            try
            {
                await _wake.WaitAsync(every, stop).ConfigureAwait(false);
            }
            catch (OperationCanceledException)
            {
                return;
            }
            await ReadAsync(stop).ConfigureAwait(false);
        }
    }

    private void Changed()
    {
        if (Closed)
        {
            return;
        }
        try
        {
            if (_wake.CurrentCount == 0)
            {
                _wake.Release();
            }
        }
        catch (Exception e) when (e is SemaphoreFullException or ObjectDisposedException)
        {
            // A read is already asked for, or the loop has stopped.
        }
    }

    // ---- runs

    /// <summary>
    /// The run's id: the app, the scheduler instance and the firing, since a fire instance id is
    /// unique only within one scheduler instance and a refire reuses it. One longer than a store
    /// holds keeps its prefix and instance and a hash of the rest.
    /// </summary>
    internal string RunId(IJobExecutionContext ctx)
    {
        string own = Prefix + _instancePart + ":";
        string rest = ctx.FireInstanceId + ":" + ctx.RefireCount.ToString(CultureInfo.InvariantCulture);
        return own.Length + rest.Length <= 200 ? own + rest : own + Sha256(rest)[..32];
    }

    private string Prefix => "quartz:" + _watch.AppSlug + ":";

    private static string Sha256(string s) => Convert.ToHexStringLower(SHA256.HashData(Encoding.UTF8.GetBytes(s)));

    /// <summary>What a firing's exception writes: its cause, when Quartz wrapped the job's own throw.</summary>
    internal static Exception? FailureOf(Exception? e)
    {
        Exception? t = e;
        while (t is SchedulerException && t.InnerException != null)
        {
            t = t.InnerException;
        }
        return t;
    }

    /// <summary>The run open on a firing, for <see cref="QuartzContextExtensions.CronwatchRun"/> and the middleware.</summary>
    internal static Firing? FiringOf(IJobExecutionContext ctx) => Firings.TryGetValue(ctx, out Firing? f) ? f : null;

    /// <summary>Once stopped and no firing is open, takes the job listener off the scheduler.</summary>
    private void LetGo()
    {
        IScheduler? scheduler = _scheduler;
        if (!Closed || !_open.IsEmpty || scheduler == null)
        {
            return;
        }
        try
        {
            scheduler.ListenerManager.RemoveJobListener(ListenerName);
        }
        catch (Exception e)
        {
            _cw.ReportError(e, "quartz");
        }
    }

    private async Task ToBeExecutedAsync(IJobExecutionContext ctx)
    {
        if (Closed)
        {
            // Stopped: nothing new is opened, but a refire still ends the attempt before it.
            if (_open.TryRemove(ctx.FireInstanceId, out Firing? earlier))
            {
                Firings.Remove(ctx);
                await earlier.Run.CloseAsync(FailureOf(earlier.Failure) ?? new JobExecutionException("Quartz refired the job")).ConfigureAwait(false);
            }
            LetGo();
            return;
        }
        if (_scheduler == null)
        {
            await AttachAsync(ctx.Scheduler, CancellationToken.None).ConfigureAwait(false);
        }
        JobKey key = ctx.JobDetail.Key;
        if (key.Equals(CheckJobKey))
        {
            return;
        }
        string name = NameOf(key);
        if (!SchedulerBridge.ValidName(name))
        {
            return;
        }
        // Quartz 4 tells no listener that an attempt it refires has ended; the next attempt's start
        // does, and the attempt before it is closed failed with what it threw.
        if (_open.TryRemove(ctx.FireInstanceId, out Firing? previous))
        {
            await previous.Run.CloseAsync(FailureOf(previous.Failure) ?? new JobExecutionException("Quartz refired the job")).ConfigureAwait(false);
        }
        Job? job = _watch.Job(name) ?? await _watch.FallbackAsync(name, Merged(_options.JobDefaults, OptionsFor(name))).ConfigureAwait(false);
        if (job == null)
        {
            return;
        }
        if (ctx.Recovering)
        {
            await RecoverAsync(name, ctx).ConfigureAwait(false);
        }
        ObservedRun run = await job.OpenAsync(new RunOptions { Trigger = Trigger, Id = RunId(ctx) }).ConfigureAwait(false);
        var firing = new Firing(run);
        _open[ctx.FireInstanceId] = firing;
        Firings.AddOrUpdate(ctx, firing);
    }

    private async Task WasExecutedAsync(IJobExecutionContext ctx, JobExecutionException? e)
    {
        if (!_open.TryRemove(ctx.FireInstanceId, out Firing? firing))
        {
            return;
        }
        Firings.Remove(ctx);
        try
        {
            await firing.Run.CloseAsync(FailureOf(e)).ConfigureAwait(false);
        }
        finally
        {
            LetGo();
        }
    }

    /// <summary>
    /// A listener after this one that threw stops Quartz running the job, and no listener is told
    /// it was executed; Quartz says so as a scheduler error naming the firing. Its run is given
    /// back, as a firing that never ran.
    /// </summary>
    private async Task ErrorAsync(SchedulerErrorContext error)
    {
        if (error.Exception is not JobExecutionProcessException
            || !error.Message.StartsWith("Unable to notify JobListener(s) of Job to be executed", StringComparison.Ordinal)
            || error.FireInstanceId is not { } fire
            || !_open.TryRemove(fire, out Firing? firing))
        {
            return;
        }
        try
        {
            await firing.Run.TakeBackAsync().ConfigureAwait(false);
        }
        finally
        {
            LetGo();
        }
    }

    /// <summary>
    /// The options for a job's run in a process that did not declare it from a trigger:
    /// <paramref name="defaults"/> and then <paramref name="given"/>, a key both give keeping its
    /// first place and taking the second's value, as the SDK spreads options.
    /// </summary>
    internal static JobOptions Merged(JobOptions? defaults, JobOptions? given)
    {
        var merged = new JobOptions { Expect = given?.Expect ?? defaults?.Expect };
        foreach (JobOptions? source in new[] { defaults, given })
        {
            if (source == null)
            {
                continue;
            }
            Definition def = source.Describe("x");
            foreach (string key in def.Keys)
            {
                if (key != "name" && key != "expect")
                {
                    merged.Field(key, def.Get(key));
                }
            }
        }
        return merged;
    }

    /// <summary>
    /// A recovering firing finishes the earlier firing's run, if it is still running, as failed: a
    /// run of this job and app from another scheduler instance, started within a minute of the
    /// original firing.
    /// </summary>
    private async Task RecoverAsync(string name, IJobExecutionContext ctx)
    {
        if (!ctx.MergedJobDataMap.TryGetValue(SchedulerConstants.FailedJobOriginalTriggerFireTime, out object? fired) || OriginalFireTime(fired) is not long firedAt)
        {
            return;
        }
        string mine = Prefix + _instancePart + ":";
        try
        {
            foreach (Run run in await _cw.RunsAsync(name, 50).ConfigureAwait(false))
            {
                if (run.Status == RunStatus.Running
                    && run.Id.StartsWith(Prefix, StringComparison.Ordinal)
                    && !run.Id.StartsWith(mine, StringComparison.Ordinal)
                    && Math.Abs(run.StartedAt - firedAt) <= RecoverySlackMs)
                {
                    RunHandle handle = await _cw.ResumeRunAsync(name, run.Id).ConfigureAwait(false);
                    await handle.FailAsync(Recovered).ConfigureAwait(false);
                }
            }
        }
        catch (Exception e)
        {
            _cw.ReportError(e, "recovering " + name);
        }
    }

    /// <summary>The original fire time Quartz keeps for a recovering firing: epoch milliseconds as text, or a date.</summary>
    internal static long? OriginalFireTime(object? fired) => fired switch
    {
        long ms => ms,
        DateTimeOffset at => at.ToUnixTimeMilliseconds(),
        string text when long.TryParse(text, NumberStyles.Integer, CultureInfo.InvariantCulture, out long ms) => ms,
        string text when DateTimeOffset.TryParse(text, CultureInfo.InvariantCulture, DateTimeStyles.AssumeUniversal, out DateTimeOffset at) => at.ToUnixTimeMilliseconds(),
        _ => null,
    };

    /// <summary>Names the app's tag and the scheduler instance.</summary>
    public override string ToString() => "CronwatchQuartz(" + _watch.AppTag + (_scheduler == null ? "" : ", instance " + _scheduler.SchedulerInstanceId) + ")";

    /// <summary>The global job listener: a run opened before the job and closed after it. Nothing it does throws into Quartz.</summary>
    private sealed class Listener(CronwatchQuartz q) : IJobListener
    {
        public string Name => ListenerName;

        public async ValueTask JobToBeExecuted(IJobExecutionContext context, CancellationToken cancellationToken)
        {
            // A throw here would stop Quartz running the job, so nothing leaves.
            try
            {
                await q.ToBeExecutedAsync(context).ConfigureAwait(false);
            }
            catch (Exception e)
            {
                q._cw.ReportError(e, "quartz");
            }
        }

        public ValueTask JobExecutionVetoed(IJobExecutionContext context, CancellationToken cancellationToken) => default; // nothing was opened for it

        public async ValueTask JobWasExecuted(IJobExecutionContext context, JobExecutionException? jobException, CancellationToken cancellationToken)
        {
            try
            {
                await q.WasExecutedAsync(context, jobException).ConfigureAwait(false);
            }
            catch (Exception e)
            {
                q._cw.ReportError(e, "quartz");
            }
        }
    }

    /// <summary>The scheduler's word that its jobs changed, which only asks for a read, and its start, error and shutdown.</summary>
    private sealed class Changes(CronwatchQuartz q) : ISchedulerListener
    {
        public string Name => ListenerName;

        public ValueTask JobScheduled(IScheduler scheduler, ITrigger trigger, CancellationToken cancellationToken) => Changed();

        public ValueTask JobUnscheduled(IScheduler scheduler, TriggerKey triggerKey, CancellationToken cancellationToken) => Changed();

        public ValueTask TriggerFinalized(IScheduler scheduler, ITrigger trigger, CancellationToken cancellationToken) => Changed();

        public ValueTask JobAdded(IScheduler scheduler, IJobDetail jobDetail, CancellationToken cancellationToken) => Changed();

        public ValueTask JobDeleted(IScheduler scheduler, JobKey jobKey, CancellationToken cancellationToken) => Changed();

        public ValueTask SchedulingDataCleared(IScheduler scheduler, CancellationToken cancellationToken) => Changed();

        public async ValueTask SchedulerStarting(IScheduler scheduler, CancellationToken cancellationToken)
        {
            try
            {
                await q.AttachAsync(scheduler, CancellationToken.None).ConfigureAwait(false);
                if (q._options.ScheduleCheck)
                {
                    await ScheduleCheckAsync(scheduler, q._options.CheckEvery, CancellationToken.None).ConfigureAwait(false);
                }
            }
            catch (Exception e)
            {
                q._cw.ReportError(e, "quartz");
            }
        }

        public async ValueTask SchedulerError(IScheduler scheduler, SchedulerErrorContext error, CancellationToken cancellationToken)
        {
            try
            {
                await q.ErrorAsync(error).ConfigureAwait(false);
            }
            catch (Exception e)
            {
                q._cw.ReportError(e, "quartz");
            }
        }

        public async ValueTask SchedulerShutdown(IScheduler scheduler, CancellationToken cancellationToken)
        {
            try
            {
                await q.DisposeAsync().ConfigureAwait(false);
            }
            catch (Exception e)
            {
                q._cw.ReportError(e, "quartz");
            }
        }

        private ValueTask Changed()
        {
            q.Changed();
            return default;
        }
    }
}
