using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.Threading;
using System.Threading.Tasks;
using Cronwatch.Internal;

namespace Cronwatch;

/// <summary>A job declared in this process: its name, stored definition, and expect rule.</summary>
internal sealed class JobDef(string name, Definition stored, Expect? expect)
{
    public string Name { get; } = name;

    public Definition Stored { get; } = stored;

    public Expect? Expect { get; } = expect;
}

/// <summary>What the client's parts share: the store, the declared jobs, the job queues, and the client's own tasks.</summary>
public sealed partial class CronwatchClient
{
    internal const int StateAttempts = 10;

    private readonly IStore _store;
    private readonly bool _defaultStore;
    private readonly IReadOnlyList<IChannel> _channels;
    private readonly ITriage? _triage;
    private readonly Cronwatch.Alerts.ITransport _transport;
    private readonly IReadOnlyList<ISource> _sources;
    private readonly string? _cronSecret;
    private readonly bool _secretOptOut;
    private readonly double _retentionMs;
    private readonly JsObject _defaults;
    private readonly Func<string, string>? _redact;
    private readonly bool _redactOff;
    private readonly bool _deferDelivery;
    private readonly Action<Exception, string> _onError;
    private readonly Action<string> _onWarning;
    private readonly TimeProvider _time;
    private readonly string? _environment;
    private readonly Func<JobContext, IDisposable?>? _runScope;
    internal readonly Timings Timings;

    private readonly Lock _declaredLock = new();
    private readonly Dictionary<string, JobDef> _definitions = new(StringComparer.Ordinal);
    private readonly List<string> _declarationOrder = [];
    private readonly HashSet<string> _synced = new(StringComparer.Ordinal);
    private readonly Dictionary<string, Task> _syncTurns = new(StringComparer.Ordinal);

    private readonly ConcurrentDictionary<string, Task<RunHandle>> _starting = new(StringComparer.Ordinal);
    internal readonly JobQueues Queues = new();

    private readonly SemaphoreSlim _readyLock = new(1, 1);
    private bool _ready;

    private readonly ConcurrentDictionary<Task, byte> _inFlight = new();
    private readonly CancellationTokenSource _closing = new();

    internal long Now() => Timings.Now is { } now ? now() : _time.GetUtcNow().ToUnixTimeMilliseconds();

    /// <summary>The zone a cron without one is read in: the clock's.</summary>
    internal TimeZoneInfo LocalZone => _time.LocalTimeZone;

    /// <summary>Runs pure evaluation with the client's local zone for crons without one.</summary>
    internal T Evaluated<T>(Func<T> work) => EvaluateDeps.InZone(LocalZone, work);

    internal void Report(Exception error, string where)
    {
        try
        {
            _onError(error, where);
        }
        catch (Exception)
        {
            // Nothing more can be done with it.
        }
    }

    internal void Report(string message, string where) => Report(new CronwatchException(message), where);

    /// <summary>The app's scope around a run's function (<see cref="CronwatchOptions.RunScope"/>), or null.</summary>
    internal IDisposable? OpenRunScope(JobContext context)
    {
        if (_runScope == null)
        {
            return null;
        }
        try
        {
            return _runScope(context);
        }
        catch (Exception e)
        {
            Report(e, "run scope for " + context.Name);
            return null;
        }
    }

    /// <summary>Disposes a run scope, reporting a throw.</summary>
    internal void CloseRunScope(IDisposable? scope, string name)
    {
        try
        {
            scope?.Dispose();
        }
        catch (Exception e)
        {
            Report(e, "run scope for " + name);
        }
    }

    internal void Warn(string message)
    {
        try
        {
            _onWarning(message);
        }
        catch (Exception)
        {
            // A warning that cannot be written is dropped.
        }
    }

    private static void DefaultOnError(Exception error, string where)
    {
        try
        {
            Console.Error.Write("[cronwatch] " + where + ": " + OutputText.ErrorName(error) + ": " + OutputText.MessageOf(error) + "\n");
        }
        catch (Exception)
        {
            // A closed or failing standard error is ignored, as console.error never throws.
        }
    }

    private static void DefaultOnWarning(string message)
    {
        try
        {
            Console.Error.Write(message + "\n");
        }
        catch (Exception)
        {
            // As above.
        }
    }

    internal string Redact(string text)
    {
        if (_redactOff)
        {
            return text;
        }
        var custom = _redact;
        if (custom == null)
        {
            return OutputText.RedactSecrets(text);
        }
        try
        {
            return custom(text) ?? throw new InvalidOperationException("redact must return a string, not null");
        }
        catch (Exception e)
        {
            // A broken redact must not stop the run finishing, nor leak what it was given.
            Report(e, "redact");
            return OutputText.RedactSecrets(text);
        }
    }

    // ---- declared jobs

    internal void Declare(JobDef def)
    {
        lock (_declaredLock)
        {
            if (!_definitions.ContainsKey(def.Name))
            {
                _declarationOrder.Add(def.Name);
            }
            _definitions[def.Name] = def;
            _synced.Remove(def.Name);
        }
    }

    internal JobDef? Declared(string name)
    {
        lock (_declaredLock)
        {
            return _definitions.TryGetValue(name, out var d) ? d : null;
        }
    }

    internal List<JobDef> DeclaredAll()
    {
        lock (_declaredLock)
        {
            return _declarationOrder.ConvertAll(n => _definitions[n]);
        }
    }

    internal void Undeclare(string name)
    {
        lock (_declaredLock)
        {
            if (_definitions.Remove(name))
            {
                _declarationOrder.Remove(name);
            }
            _synced.Remove(name);
        }
    }

    // ---- the store

    /// <summary>A store call, its failure a <see cref="CronwatchException"/> of kind Store.</summary>
    internal static async Task<T> CallAsync<T>(Func<Task<T>> call)
    {
        try
        {
            return await call().ConfigureAwait(false);
        }
        catch (CronwatchException)
        {
            throw;
        }
        catch (Exception e)
        {
            throw CronwatchException.Store(e);
        }
    }

    internal static Task CallAsync(Func<Task> call) => CallAsync<bool>(async () =>
    {
        await call().ConfigureAwait(false);
        return true;
    });

    internal async Task EnsureReadyAsync()
    {
        if (Volatile.Read(ref _ready))
        {
            return;
        }
        await _readyLock.WaitAsync().ConfigureAwait(false);
        try
        {
            if (_ready)
            {
                return;
            }
            await CallAsync(() => _store.InitAsync()).ConfigureAwait(false);
            Volatile.Write(ref _ready, true);
            if (_defaultStore && Env.Environment(_environment) == "production")
            {
                Warn("[cronwatch] using the in-memory store: runs and state are lost on restart. Pass a store in CronwatchOptions.Store, such as SqlStore over the app's database.");
            }
        }
        finally
        {
            _readyLock.Release();
        }
    }

    /// <summary>
    /// Writes the declaration of <paramref name="def"/>'s name as it stands, unless the store has
    /// it: a handle kept from an earlier declaration writes the one that replaced it, never its
    /// own over it, and one forgotten since writes its own. With <paramref name="confirm"/>, as a
    /// run starts, a name already written is read back: another process may have forgotten the
    /// job since, and a job still declared here comes back on its next run.
    /// </summary>
    internal async Task SyncAsync(JobDef def, bool confirm = false)
    {
        await EnsureReadyAsync().ConfigureAwait(false);
        bool written;
        lock (_declaredLock)
        {
            written = _synced.Contains(def.Name);
        }
        if (written)
        {
            if (!confirm || await CallAsync(() => _store.GetJobAsync(def.Name)).ConfigureAwait(false) != null)
            {
                return;
            }
            lock (_declaredLock)
            {
                _synced.Remove(def.Name);
            }
        }
        await InTurnAsync(def.Name, async () =>
        {
            JobDef standing;
            lock (_declaredLock)
            {
                if (_synced.Contains(def.Name))
                {
                    return false;
                }
                standing = _definitions.TryGetValue(def.Name, out var current) ? current : def;
            }
            await CallAsync(() => _store.UpsertJobAsync(standing.Stored, Now())).ConfigureAwait(false);
            MarkSynced(standing);
            return true;
        }).ConfigureAwait(false);
    }

    /// <summary>
    /// Runs <paramref name="write"/> after every earlier write of <paramref name="name"/>'s
    /// declaration has ended, so two declarations of one name reach the store in the order they
    /// were made and the later one stays.
    /// </summary>
    internal async Task<T> InTurnAsync<T>(string name, Func<Task<T>> write)
    {
        var mine = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        Task? earlier;
        lock (_declaredLock)
        {
            _syncTurns.TryGetValue(name, out earlier);
            _syncTurns[name] = mine.Task;
        }
        try
        {
            if (earlier != null)
            {
                await earlier.ConfigureAwait(false);
            }
            return await write().ConfigureAwait(false);
        }
        finally
        {
            lock (_declaredLock)
            {
                if (_syncTurns.TryGetValue(name, out Task? last) && ReferenceEquals(last, mine.Task))
                {
                    _syncTurns.Remove(name);
                }
            }
            mine.SetResult();
        }
    }

    /// <summary>
    /// Every stored job, once each declaration has been written. A job declared here that the
    /// store no longer has was forgotten by another process after this one wrote it: it is
    /// written again, as its next run would, so it is checked and shown while any process still
    /// declares it.
    /// </summary>
    internal async Task<IReadOnlyList<StoredJob>> StoredJobsAsync()
    {
        foreach (JobDef def in DeclaredAll())
        {
            await SyncAsync(def).ConfigureAwait(false);
        }
        var jobs = ReadStoredJobs(await CallAsync(() => _store.ListJobsAsync()).ConfigureAwait(false));
        var listed = new HashSet<string>(StringComparer.Ordinal);
        foreach (var job in jobs)
        {
            listed.Add(job.Name);
        }
        bool wrote = false;
        foreach (JobDef def in DeclaredAll())
        {
            if (listed.Contains(def.Name))
            {
                continue;
            }
            lock (_declaredLock)
            {
                // Not one forgotten or declared again here meanwhile.
                if (!_definitions.TryGetValue(def.Name, out var current) || !ReferenceEquals(current, def))
                {
                    continue;
                }
                _synced.Remove(def.Name);
            }
            await SyncAsync(def).ConfigureAwait(false);
            wrote = true;
        }
        return wrote ? ReadStoredJobs(await CallAsync(() => _store.ListJobsAsync()).ConfigureAwait(false)) : jobs;
    }

    private static List<StoredJob> ReadStoredJobs(IReadOnlyList<StoredJob> jobs)
    {
        var output = new List<StoredJob>(jobs.Count);
        foreach (var job in jobs)
        {
            output.Add(ReadStoredJob(job));
        }
        return output;
    }

    /// <summary>
    /// A stored job as the client reads it (the SDK's <c>readStoredJob</c>), so a foreign,
    /// hand-edited, or damaged row affects only its own job: <c>tags</c> is kept only when it is a
    /// list of strings, and every other field as stored. A definition that was not a JSON object
    /// comes from the store already read as <c>{ name }</c> and marked unreadable.
    /// </summary>
    internal static StoredJob ReadStoredJob(StoredJob stored)
    {
        JsObject fields = stored.Definition.Fields;
        if (stored.Definition.Unreadable || !fields.Has("tags"))
        {
            return stored;
        }
        if (fields.Get("tags") is List<object?> tags && tags.TrueForAll(t => t is string))
        {
            return stored;
        }
        JsObject kept = fields.Copy();
        kept.Remove("tags");
        return stored with { Definition = Definition.Own(kept) };
    }

    /// <summary>Throws for a job whose stored definition was not a JSON object: reported, and shown as failing, while the others carry on.</summary>
    internal static void Evaluable(StoredJob stored)
    {
        if (stored.Definition.Unreadable)
        {
            throw new InvalidOperationException("job " + JsonText.Quote(stored.Name) + ": its stored definition is not a JSON object");
        }
    }

    internal void MarkSynced(JobDef def)
    {
        lock (_declaredLock)
        {
            if (_definitions.TryGetValue(def.Name, out var current) && ReferenceEquals(current, def))
            {
                _synced.Add(def.Name);
            }
        }
    }

    internal async Task<JobState> ReadStateAsync(string job)
    {
        var state = await CallAsync(() => _store.GetStateAsync(job)).ConfigureAwait(false);
        return Evaluate.NormalizeState(state, job);
    }

    /// <summary>
    /// A read-modify-write of a job's state, holding the job's queue: reads the state, works out
    /// the next one, and writes it only when it changed, with its version one higher, through a
    /// compare-and-set against the version read; a refused write is worked out again from a fresh
    /// read, up to ten times. Only store calls happen in the queue; alerts are sent after it.
    /// </summary>
    internal async Task<(JobState State, TResult Result)> UpdateStateAsync<TPrepared, TResult>(
        string job, Func<Task<TPrepared>> prepare, Func<JobState, TPrepared, (JobState State, TResult Result)> change)
    {
        using var turn = await Queues.EnterAsync(job).ConfigureAwait(false);
        TPrepared prepared = await CallAsync(prepare).ConfigureAwait(false);
        for (int attempt = 1; ; attempt++)
        {
            JobState current = await ReadStateAsync(job).ConfigureAwait(false);
            var next = Evaluated(() => change(current, prepared));
            if (next.State.ToJson() == current.ToJson())
            {
                return (current, next.Result);
            }
            long version = current.CountedVersion;
            JobState written = next.State with { Version = version + 1 };
            if (await WriteStateAsync(written, version).ConfigureAwait(false))
            {
                return (written, next.Result);
            }
            if (attempt >= StateAttempts)
            {
                throw new CronwatchException(
                    "the state of " + job + " changed under " + StateAttempts + " attempts in a row to update it; gave up");
            }
        }
    }

    internal Task<(JobState State, TResult Result)> UpdateStateAsync<TResult>(string job, Func<JobState, (JobState State, TResult Result)> change) =>
        UpdateStateAsync<bool, TResult>(job, () => Task.FromResult(true), (s, _) => change(s));

    private async Task<bool> WriteStateAsync(JobState state, long expected)
    {
        if (_store is ICompareAndSetStateStore cas)
        {
            return await CallAsync(() => cas.CompareAndSetStateAsync(state, expected)).ConfigureAwait(false);
        }
        await CallAsync(() => _store.SetStateAsync(state)).ConfigureAwait(false);
        return true;
    }

    internal async Task<bool> WriteRunIfAsync(Run run, IReadOnlyList<RunStatus> from)
    {
        if (_store is IUpdateRunIfStore conditional)
        {
            return await CallAsync(() => conditional.UpdateRunIfAsync(run, from)).ConfigureAwait(false);
        }
        Run? stored = await CallAsync(() => _store.GetRunAsync(run.Id)).ConfigureAwait(false);
        if (stored == null || !Contains(from, stored.Status))
        {
            return false;
        }
        await CallAsync(() => _store.UpdateRunAsync(run)).ConfigureAwait(false);
        return true;
    }

    internal static bool Contains(IReadOnlyList<RunStatus> list, RunStatus status)
    {
        foreach (var s in list)
        {
            if (s == status)
            {
                return true;
            }
        }
        return false;
    }

    // ---- the client's own tasks

    /// <summary>
    /// Starts <paramref name="work"/> on the thread pool, outside the caller's execution context, so
    /// an app's <see cref="AsyncLocal{T}"/> values (its log scope, its current run, an activity) do
    /// not leak into work that outlives the call, and tracks it so disposal can wait for it.
    /// </summary>
    internal Task<T> Spawn<T>(Func<Task<T>> work)
    {
        Task<T> task = WithoutFlow(() => Task.Run(work));
        _inFlight.TryAdd(task, 0);
        _ = task.ContinueWith(
            static (t, state) =>
            {
                // Observed here, so a task whose caller stopped waiting never reaches the app's
                // UnobservedTaskException handler (an error tracker's) when it later fails.
                _ = t.Exception;
                ((ConcurrentDictionary<Task, byte>)state!).TryRemove(t, out _);
            },
            _inFlight,
            CancellationToken.None,
            TaskContinuationOptions.ExecuteSynchronously,
            TaskScheduler.Default);
        return task;
    }

    /// <summary>Observes a task given up on, so its later failure is not reported as unobserved.</summary>
    internal static void Abandon(Task task) => _ = task.ContinueWith(
        static t => _ = t.Exception,
        CancellationToken.None,
        TaskContinuationOptions.OnlyOnFaulted | TaskContinuationOptions.ExecuteSynchronously,
        TaskScheduler.Default);

    /// <summary>Runs <paramref name="start"/> with the execution context's flow suppressed.</summary>
    internal static T WithoutFlow<T>(Func<T> start)
    {
        if (ExecutionContext.IsFlowSuppressed())
        {
            return start();
        }
        using (ExecutionContext.SuppressFlow())
        {
            return start();
        }
    }

    internal Task Spawn(Func<Task> work) => Spawn<bool>(async () =>
    {
        await work().ConfigureAwait(false);
        return true;
    });

    /// <summary>Spawns work whose failure is reported rather than observed by anyone.</summary>
    internal void SpawnReported(Func<Task> work, string where) => _ = Spawn(async () =>
    {
        try
        {
            await work().ConfigureAwait(false);
        }
        catch (Exception e)
        {
            Report(e, where);
        }
    });

    /// <summary>How many job queues are held or waited for, for the tests.</summary>
    internal int LockedJobs => Queues.Count;
}
