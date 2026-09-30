using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Threading;
using System.Threading.Tasks;
using Cronwatch.Internal;

namespace Cronwatch.Bridge;

/// <summary>
/// What an integration keeps for one scheduler: the jobs it declared, by name, the jobs gone from
/// it, the jobs a worker runs that another process declared, and the problems it reported. The Go
/// port's <c>bridge/watch.go</c> and <c>Fallback</c> through the Java port's <c>Watch</c>, with
/// their audits' fixes. Safe to use from many threads at once.
/// </summary>
[DebuggerDisplay("{ToString(),nq}")]
public sealed class Watch
{
    /// <summary>Bounds one write of a declaration to the store, so a store that hangs holds nothing.</summary>
    public static readonly TimeSpan SaveTimeout = TimeSpan.FromSeconds(30);

    private readonly CronwatchClient _cw;
    private readonly string _scheduler;

    /// <summary>
    /// Holds one declaration at a time (<see cref="Declare"/>, the end of
    /// <see cref="FallbackAsync"/>, <see cref="UnscheduleAsync"/>'s declarations), so one never
    /// takes another's entries for gone or leaves the client holding a job without its schedule.
    /// Never held across an await.
    /// </summary>
    private readonly Lock _declaring = new();

    private readonly Lock _lock = new();
    private readonly Dictionary<string, Declared> _jobs = new(StringComparer.Ordinal);
    private readonly Dictionary<string, Job> _fallback = new(StringComparer.Ordinal);
    private readonly HashSet<string> _reported = new(StringComparer.Ordinal);
    private readonly SortedSet<string> _pending = new(StringComparer.Ordinal);

    /// <summary>
    /// Whether this process ever declared an entry: until it has, it takes no job for one the
    /// scheduler dropped (a process that runs a check and no scheduler must not unschedule the
    /// app's jobs).
    /// </summary>
    private bool _seen;

    private bool _saving;
    private TaskCompletionSource _idle = NewIdle(true);

    private sealed class Declared(Job job, string key, bool current)
    {
        public Job Job { get; set; } = job;

        /// <summary>The definition's JSON, to tell a changed declaration.</summary>
        public string Key { get; set; } = key;

        /// <summary>The entry is still in the scheduler.</summary>
        public bool Current { get; set; } = current;
    }

    /// <summary>
    /// A watch for one scheduler: <paramref name="tag"/> is the integration's (<c>quartz</c>),
    /// <paramref name="app"/> the app's name for its tag (null for
    /// <see cref="SchedulerBridge.AppName"/>), and <paramref name="scheduler"/> how messages name the
    /// scheduler (<c>Quartz</c>).
    /// </summary>
    public Watch(CronwatchClient cw, string tag, string? app, string scheduler)
    {
        _cw = cw ?? throw new ArgumentNullException(nameof(cw));
        Tag = tag ?? throw new ArgumentNullException(nameof(tag));
        _scheduler = scheduler ?? throw new ArgumentNullException(nameof(scheduler));
        AppTag = SchedulerBridge.AppTag(tag, string.IsNullOrEmpty(app) ? SchedulerBridge.AppName() : app);
    }

    /// <summary>The client the watch declares jobs on.</summary>
    public CronwatchClient Client => _cw;

    /// <summary>The integration's tag.</summary>
    public string Tag { get; }

    /// <summary>The app's tag under the integration's.</summary>
    public string AppTag { get; }

    /// <summary>
    /// The app's part of its tag (<c>billing</c> of <c>quartz:billing</c>), for run ids that must
    /// not collide with another app's on a shared store.
    /// </summary>
    public string AppSlug => AppTag[(Tag.Length + 1)..];

    /// <summary>How long one write of a declaration may take; the tests shorten it.</summary>
    internal TimeSpan SaveLimit { get; set; } = SaveTimeout;

    private static TaskCompletionSource NewIdle(bool done)
    {
        var tcs = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        if (done)
        {
            tcs.SetResult();
        }
        return tcs;
    }

    /// <summary>
    /// Hands <paramref name="message"/> to the client's error handler the first time this watch
    /// sees it for that <paramref name="where"/>.
    /// </summary>
    public void ReportOnce(string message, string where)
    {
        bool first;
        lock (_lock)
        {
            first = _reported.Add(where + "\0" + message);
        }
        if (first)
        {
            _cw.ReportError(new CronwatchException(message), where);
        }
    }

    /// <summary>The job declared under <paramref name="name"/>, or one declared for a run of it (<see cref="FallbackAsync"/>).</summary>
    public Job? Job(string name)
    {
        lock (_lock)
        {
            return _jobs.TryGetValue(name, out var d) ? d.Job : _fallback.GetValueOrDefault(name);
        }
    }

    /// <summary>Whether <paramref name="name"/> was declared from a scheduler entry by this watch.</summary>
    public bool Declares(string name)
    {
        lock (_lock)
        {
            return _jobs.ContainsKey(name);
        }
    }

    /// <summary>
    /// Declares every entry the scheduler has now, one job per name, and declares again without its
    /// schedule a job this watch declared whose entries are all gone. Several entries of one name
    /// on different schedules are one job without a schedule, reported once. Each job is tagged
    /// with the integration's tag and the app's. A declaration that has not changed is left alone;
    /// one the client refuses is reported, as is each entry's problem, once. What is declared is
    /// written to the store by a task of its own (<see cref="SettleAsync"/> waits for it), since a
    /// process that only schedules neither runs nor checks, and a declaration kept in memory would
    /// never reach the processes that do.
    /// </summary>
    public void Declare(IReadOnlyList<Entry> entries)
    {
        ArgumentNullException.ThrowIfNull(entries);
        lock (_declaring)
        {
            var byName = new Dictionary<string, List<Entry>>(StringComparer.Ordinal);
            var order = new List<string>();
            foreach (Entry e in entries)
            {
                if (!byName.TryGetValue(e.Name, out var list))
                {
                    list = [];
                    byName[e.Name] = list;
                    order.Add(e.Name);
                }
                list.Add(e);
            }
            lock (_lock)
            {
                if (entries.Count > 0)
                {
                    _seen = true;
                }
                foreach (Declared d in _jobs.Values)
                {
                    d.Current = false;
                }
            }

            foreach (string name in order)
            {
                List<Entry> list = byName[name];
                Entry first = list[0];
                string schedule = first.Schedule;
                string zone = first.Timezone;
                var times = new List<string>();
                foreach (Entry e in list)
                {
                    if (e.Problem != null)
                    {
                        ReportOnce(e.Problem, "declaring " + e.Label);
                    }
                    string text = e.Schedule;
                    if (e.Timezone.Length > 0)
                    {
                        text = text + " in " + e.Timezone;
                    }
                    if (text.Length == 0)
                    {
                        text = "no schedule";
                    }
                    if (!times.Contains(text))
                    {
                        times.Add(text);
                    }
                }
                if (times.Count > 1)
                {
                    schedule = "";
                    zone = "";
                    ReportOnce(
                        "cronwatch: " + Json.Quote(name) + " is run by " + list.Count + " " + _scheduler
                        + " entries on different schedules (" + string.Join("; ", times)
                        + "), so it is watched without a schedule; give each a name of its own",
                        "declaring " + first.Label);
                }
                JobOptions options = first.Defaults.Copy();
                if (schedule.Length > 0)
                {
                    options.SetField("schedule", schedule);
                    if (zone.Length > 0)
                    {
                        options.SetField("timezone", zone);
                    }
                }
                options.MergeFrom(first.Options);
                DeclareOne(name, first.Label, Tagged(options), true);
            }

            // Jobs whose entries are gone keep their runs and lose their schedule.
            var gone = new SortedDictionary<string, Definition>(StringComparer.Ordinal);
            lock (_lock)
            {
                foreach (var e in _jobs)
                {
                    Definition def = e.Value.Job.Definition;
                    if (!e.Value.Current && !string.IsNullOrEmpty(def.Schedule))
                    {
                        gone[e.Key] = def;
                    }
                }
            }
            foreach (var e in gone)
            {
                DeclareOne(e.Key, Json.Quote(e.Key), SchedulerBridge.Unscheduled(e.Value), false);
            }
        }
    }

    /// <summary><paramref name="options"/> (a copy) with the integration's and the app's tags added to the ones it gives.</summary>
    public JobOptions Tagged(JobOptions options)
    {
        ArgumentNullException.ThrowIfNull(options);
        JobOptions copy = options.Copy();
        var tags = new List<object?>();
        foreach (string t in copy.Tags ?? [])
        {
            tags.Add(t);
        }
        foreach (string t in new[] { Tag, AppTag })
        {
            if (!tags.Contains(t))
            {
                tags.Add(t);
            }
        }
        copy.SetField("tags", tags);
        return copy;
    }

    private void DeclareOne(string name, string label, JobOptions options, bool current)
    {
        string key;
        try
        {
            key = SchedulerBridge.Definition(_cw, name, options).ToJson();
        }
        catch (CronwatchException e)
        {
            ReportOnce(e.Message, "declaring " + label);
            return;
        }
        // Unchanged only while the client still declares it: a job forgotten (the dashboard's
        // Forget) is declared again here, so it comes back without waiting for its next firing.
        bool declared = _cw.Declared(name) != null;
        lock (_lock)
        {
            if (declared && _jobs.TryGetValue(name, out var d) && d.Key == key)
            {
                d.Current = d.Current || current;
                return;
            }
        }
        Job job;
        try
        {
            job = _cw.Job(name, options);
        }
        catch (CronwatchException e)
        {
            ReportOnce(e.Message, "declaring " + label);
            return;
        }
        lock (_lock)
        {
            _fallback.Remove(name);
            if (_jobs.TryGetValue(name, out var d))
            {
                d.Job = job;
                d.Key = key;
                d.Current = d.Current || current;
            }
            else
            {
                _jobs[name] = new Declared(job, key, current);
            }
        }
        Save(name);
    }

    /// <summary>
    /// Writes <paramref name="name"/>'s declaration to the store by a task of its own, one writer
    /// at a time, each write the client's declaration as it is then.
    /// </summary>
    private void Save(string name)
    {
        lock (_lock)
        {
            _pending.Add(name);
            if (_saving)
            {
                return;
            }
            _saving = true;
            if (_idle.Task.IsCompleted)
            {
                _idle = NewIdle(false);
            }
        }
        _ = CronwatchClient.WithoutFlow(() => Task.Run(SaveAllAsync));
    }

    private async Task SaveAllAsync()
    {
        try
        {
            while (true)
            {
                List<string> names;
                lock (_lock)
                {
                    if (_pending.Count == 0)
                    {
                        return;
                    }
                    names = [.. _pending];
                    _pending.Clear();
                }
                HashSet<string> defined = Defined();
                foreach (string name in names)
                {
                    if (!defined.Contains(name))
                    {
                        continue; // forgotten since
                    }
                    try
                    {
                        await SyncJobAsync(name).ConfigureAwait(false);
                    }
                    catch (Exception e)
                    {
                        // A store that throws is that declaration's failure, not the end of every one after.
                        _cw.ReportError(e, "declaring " + name);
                    }
                }
            }
        }
        finally
        {
            // Marked finished whatever ended it, so the next declaration starts another.
            TaskCompletionSource? done = null;
            bool again = false;
            lock (_lock)
            {
                if (_pending.Count > 0)
                {
                    again = true;
                }
                else
                {
                    _saving = false;
                    done = _idle;
                }
            }
            if (again)
            {
                _ = CronwatchClient.WithoutFlow(() => Task.Run(SaveAllAsync));
            }
            done?.TrySetResult();
        }
    }

    /// <summary>
    /// <see cref="CronwatchClient.SyncJobAsync"/> within the save deadline: a store that hangs keeps
    /// the client's task, not the caller, which gives up.
    /// </summary>
    internal async Task<bool> SyncJobAsync(string name)
    {
        try
        {
            return await _cw.SyncJobAsync(name).WaitAsync(SaveLimit).ConfigureAwait(false);
        }
        catch (TimeoutException)
        {
            throw new CronwatchException(
                "writing the declaration of " + Json.Quote(name) + " took longer than " + Js.FormatLong((long)SaveLimit.TotalSeconds) + " seconds; gave up");
        }
    }

    private HashSet<string> Defined()
    {
        var output = new HashSet<string>(StringComparer.Ordinal);
        foreach (Definition d in _cw.DefinedJobs)
        {
            output.Add(d.Name);
        }
        return output;
    }

    /// <summary>
    /// Waits until what <see cref="Declare"/> declared has been written to the store, at most
    /// <paramref name="timeout"/>, for tests and a clean exit. Says whether it was.
    /// </summary>
    public async Task<bool> SettleAsync(TimeSpan timeout)
    {
        Task idle;
        lock (_lock)
        {
            idle = _idle.Task;
        }
        try
        {
            await idle.WaitAsync(timeout).ConfigureAwait(false);
            return true;
        }
        catch (TimeoutException)
        {
            return false;
        }
    }

    /// <summary>
    /// The job a run in this process belongs to when this process has not declared it from a
    /// scheduler of its own (a worker whose app schedules the job in another process): declared
    /// again from the definition the store holds, when that is this app's (tagged with its app
    /// tag), so the schedule another process stored is kept, else with <paramref name="options"/>
    /// and this watch's tags. Declared once per name in this process. Null, with the reason
    /// reported, when the client refuses it or the store cannot be read (the run then goes
    /// unrecorded, and the next one asks again), since a declaration made without the stored one
    /// would write over its schedule. A job <see cref="Declare"/> has declared is its.
    /// </summary>
    public async Task<Job?> FallbackAsync(string name, JobOptions options)
    {
        ArgumentNullException.ThrowIfNull(name);
        ArgumentNullException.ThrowIfNull(options);
        if (Job(name) is { } known)
        {
            return known;
        }
        StoredJob? stored;
        try
        {
            await _cw.EnsureReadyAsync().ConfigureAwait(false);
            stored = await CronwatchClient.CallAsync(() => _cw.Store.GetJobAsync(name)).ConfigureAwait(false);
        }
        catch (Exception e)
        {
            _cw.ReportError(e, "declaring " + name);
            return null;
        }
        JobOptions made = stored != null && HasTag(stored.Definition, AppTag)
            ? SchedulerBridge.OptionsOf(stored.Definition)
            : Tagged(options);
        // In turn with Declare, and after looking again: a job declared from a scheduler entry
        // meanwhile is that one, so the client never ends up holding the declaration without the
        // schedule.
        lock (_declaring)
        {
            if (Job(name) is { } again)
            {
                return again;
            }
            Job job;
            try
            {
                job = _cw.Job(name, made);
            }
            catch (CronwatchException e)
            {
                ReportOnce(e.Message, "declaring " + name);
                return null;
            }
            lock (_lock)
            {
                _fallback[name] = job;
            }
            return job;
        }
    }

    /// <summary>
    /// Declares again without its schedule every job of this app's (tagged with its app tag) that
    /// the store holds with a schedule and this process has not declared: a scheduler entry taken
    /// out since the job was declared, by this process or an earlier one, so it is never reported
    /// missed and a missed alert already open closes. Call it just before a check. It first writes
    /// back this process's own declarations wherever the store holds something else (an older
    /// release still up during a deploy may have taken the schedule out of a job it does not run).
    /// A process that never declared an entry of its scheduler leaves every job alone. Everything is
    /// written before it returns. Answers the names declared again.
    /// </summary>
    /// <exception cref="CronwatchException">Naming every write or read that failed, after doing the rest.</exception>
    public async Task<IReadOnlyList<string>> UnscheduleAsync()
    {
        bool everSeen;
        var mine = new SortedSet<string>(StringComparer.Ordinal);
        lock (_lock)
        {
            everSeen = _seen;
            mine.UnionWith(_jobs.Keys);
        }
        if (!everSeen)
        {
            return [];
        }
        var failed = new List<string>();
        HashSet<string> defined = Defined();
        foreach (string name in mine)
        {
            if (!defined.Contains(name))
            {
                continue;
            }
            try
            {
                await SyncJobAsync(name).ConfigureAwait(false);
            }
            catch (Exception e)
            {
                failed.Add("declaring " + name + ": " + e.Message);
            }
        }
        IReadOnlyList<StoredJob> stored;
        try
        {
            await _cw.EnsureReadyAsync().ConfigureAwait(false);
            stored = await CronwatchClient.CallAsync(() => _cw.Store.ListJobsAsync()).ConfigureAwait(false);
        }
        catch (Exception e)
        {
            failed.Add(e.Message);
            throw new CronwatchException(string.Join("\n", failed));
        }
        // In turn with Declare and FallbackAsync, and with what is declared read again: a job
        // declared since the first read (a scheduler entry added while the store was read) keeps
        // its schedule.
        var names = new List<string>();
        lock (_declaring)
        {
            HashSet<string> now = Defined();
            foreach (StoredJob job in stored)
            {
                Definition def = job.Definition;
                if (now.Contains(job.Name) || string.IsNullOrEmpty(def.Schedule) || !HasTag(def, AppTag))
                {
                    continue;
                }
                try
                {
                    _cw.Job(job.Name, SchedulerBridge.Unscheduled(def));
                    names.Add(job.Name);
                }
                catch (CronwatchException e)
                {
                    failed.Add("declaring " + job.Name + ": " + e.Message);
                }
            }
        }
        // Written before returning, and in order with this call's other writes: a process that
        // never checks would otherwise leave the schedule in the store, and a write left to run
        // behind could land after another process has put the schedule back. SyncJobAsync writes
        // what is declared at the time, so a job declared again since keeps its schedule.
        foreach (string name in names)
        {
            try
            {
                await SyncJobAsync(name).ConfigureAwait(false);
            }
            catch (Exception e)
            {
                failed.Add("declaring " + name + ": " + e.Message);
            }
        }
        if (failed.Count > 0)
        {
            throw new CronwatchException(string.Join("\n", failed));
        }
        return names;
    }

    private static bool HasTag(Definition def, string tag)
    {
        foreach (string t in def.Tags)
        {
            if (string.Equals(t, tag, StringComparison.Ordinal))
            {
                return true;
            }
        }
        return false;
    }

    /// <summary>Names the integration's tag and the app's.</summary>
    public override string ToString() => "Watch(" + Tag + ", " + AppTag + ")";
}
