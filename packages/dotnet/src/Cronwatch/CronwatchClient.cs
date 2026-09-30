using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Reflection;
using System.Threading;
using System.Threading.Tasks;
using Cronwatch.Internal;

namespace Cronwatch;

/// <summary>
/// The CronWatch client: the SDK's <c>cronwatch({...})</c>. Declare jobs with <see cref="Job"/>,
/// run them with <see cref="Job.RunAsync(Func{JobContext, CancellationToken, Task}, CancellationToken)"/>,
/// and check for missed and stuck runs with <see cref="CheckAsync"/> (or every minute with
/// <see cref="Start"/>). Safe to use from any number of threads and tasks at once; keep one per
/// process, as a data source is kept, and dispose it at shutdown.
/// </summary>
[DebuggerDisplay("{ToString(),nq}")]
public sealed partial class CronwatchClient : IAsyncDisposable, IDisposable
{
    /// <summary>The library's version.</summary>
    public static string Version { get; } = ReadVersion();

    /// <summary>Run ids the pg_cron source gives its runs start with this, which no other run may.</summary>
    public const string ReservedRunIdPrefix = "pgcron:";

    private static readonly HashSet<string> Defaultable = new(StringComparer.Ordinal) { "grace", "timeout", "timezone", "failuresBeforeAlert" };

    private readonly bool _processExitHook;
    private int _disposed;

    /// <summary>A client with the options' store, channels and rules, checked now.</summary>
    /// <exception cref="CronwatchException">Of kind <see cref="CronwatchErrorKind.Invalid"/> for a bad option, with the SDK's message.</exception>
    public CronwatchClient(CronwatchOptions? options = null)
    {
        options ??= new CronwatchOptions();
        var defaults = new JsObject();
        if (options.Defaults is { } d)
        {
            foreach (string key in d.Fields().Keys)
            {
                if (!Defaultable.Contains(key))
                {
                    throw CronwatchException.Invalid("defaults takes grace, timeout, timezone and failuresBeforeAlert, not " + key);
                }
            }
            if (d.Expect != null)
            {
                throw CronwatchException.Invalid("defaults takes grace, timeout, timezone and failuresBeforeAlert, not expect");
            }
            defaults = d.Fields();
        }
        _retentionMs = options.Retention.Milliseconds("retention");
        _store = options.Store ?? new MemoryStore();
        _defaultStore = options.Store == null;
        _channels = options.AlertsGiven ? new List<IChannel>(options.Alerts) : [new ConsoleChannel()];
        _triage = options.Triage;
        _transport = options.Transport ?? new LazyTransport();
        _sources = new List<ISource>(options.Sources ?? []);
        if (options.CronSecret is { } secret)
        {
            _cronSecret = string.IsNullOrEmpty(secret.Value) ? null : secret.Value;
            _secretOptOut = secret.Value == null;
        }
        else
        {
            string? fromEnv = Env.Read("CRON_SECRET");
            _cronSecret = string.IsNullOrEmpty(fromEnv) ? null : fromEnv;
        }
        _defaults = defaults;
        _redactOff = ReferenceEquals(options.Redact, Redaction.None);
        _redact = _redactOff ? null : options.Redact;
        _deferDelivery = options.Deliver == Deliver.AtCheck;
        _onError = options.OnError ?? DefaultOnError;
        _onWarning = options.OnWarning ?? DefaultOnWarning;
        _time = options.Clock ?? TimeProvider.System;
        _environment = options.Environment;
        _runScope = options.RunScope;
        Timings = options.TimingsOverride ?? new Timings();
        _processExitHook = options.ProcessExitHook;
        if (_processExitHook)
        {
            AppDomain.CurrentDomain.ProcessExit += OnProcessExit;
        }
    }

    private static string ReadVersion()
    {
        string? v = typeof(CronwatchClient).Assembly.GetCustomAttribute<AssemblyInformationalVersionAttribute>()?.InformationalVersion;
        if (string.IsNullOrEmpty(v))
        {
            return "0.0.0";
        }
        int plus = v.IndexOf('+', StringComparison.Ordinal);
        return plus >= 0 ? v[..plus] : v;
    }

    /// <summary>
    /// The current flow's run: set inside a job's function, flowing into everything it awaits and
    /// every task it starts, and gone when the run ends; null elsewhere.
    /// </summary>
    public static JobContext? Current => CurrentRun.Get();

    // ---- jobs

    /// <summary>
    /// Declares a job (again, replacing an earlier declaration of the name) and answers its
    /// handle. The definition is written to the store at the job's first run or check.
    /// </summary>
    /// <exception cref="CronwatchException">Of kind <see cref="CronwatchErrorKind.Invalid"/> for a bad name, schedule, zone or option, with the SDK's message.</exception>
    public Job Job(string name, JobOptions? options = null)
    {
        JobDef def = Define(name, options ?? new JobOptions());
        Declare(def);
        return new Job(this, def);
    }

    private JobDef Define(string name, JobOptions options)
    {
        ArgumentNullException.ThrowIfNull(name);
        if (!ValidName(name))
        {
            throw CronwatchException.Invalid("job name " + Json.Quote(name) + " must be 1 to 120 characters of letters, digits, \".\", \"_\", \":\" or \"-\"");
        }
        JsObject fields = _defaults.Copy();
        foreach (var e in options.Fields())
        {
            fields.Set(e.Key, Json.Copy(e.Value));
        }
        fields.Set("name", name);
        Definition stored = Expect.ToStored(fields, options.Expect);
        Validate(name, stored);
        return new JobDef(name, stored, options.Expect);
    }

    private static bool ValidName(string name)
    {
        if (name.Length == 0 || name.Length > 120)
        {
            return false;
        }
        for (int i = 0; i < name.Length; i++)
        {
            char c = name[i];
            bool alnum = (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9');
            if (!alnum && (i == 0 || (c != '.' && c != '_' && c != ':' && c != '-')))
            {
                return false;
            }
        }
        return true;
    }

    private void Validate(string name, Definition def)
    {
        string quoted = Json.Quote(name);
        try
        {
            if (def.Has("schedule"))
            {
                if (def.Get("schedule") is not string text || Js.Trim(text).Length == 0)
                {
                    throw CronwatchException.Invalid("job " + quoted + ": schedule must be a non-empty string");
                }
                // The zone is checked below, with a message of its own; here only a good one is used.
                string? tz = def.Get("timezone") is string z && Schedules.IsZone(z) && z.Length > 0 ? z : null;
                Schedules.Parse(text, tz, LocalZone);
            }
            if (def.Has("timezone"))
            {
                string tz = def.Get("timezone") as string ?? "";
                if (!Schedules.IsZone(tz))
                {
                    throw CronwatchException.Invalid("job " + quoted + ": timezone " + Json.Quote(tz) + " is not an IANA timezone");
                }
            }
            if (def.Has("grace"))
            {
                Evaluate.GraceMs(def);
            }
            if (def.Has("timeout") && Evaluate.TimeoutMs(def) <= 0)
            {
                throw CronwatchException.Invalid("job " + quoted + ": timeout must be longer than zero");
            }
            if (def.Has("maxDuration") && Durations.ParseValue(def.Get("maxDuration"), "maxDuration") <= 0)
            {
                throw CronwatchException.Invalid("job " + quoted + ": maxDuration must be longer than zero");
            }
            if (def.Has("failuresBeforeAlert"))
            {
                object? v = def.Get("failuresBeforeAlert");
                double n = Json.TryNumber(v, out double x) ? x : 0;
                if (!Js.IsInteger(n) || n < 1)
                {
                    throw CronwatchException.Invalid("job " + quoted + ": failuresBeforeAlert must be a whole number, 1 or more (got " + AlertFormat.JsText(v) + ")");
                }
            }
            if (def.Get("budget") is JsObject budget)
            {
                foreach (var e in budget)
                {
                    double ceiling = Json.TryNumber(e.Value, out double c) ? c : 0;
                    if (!double.IsFinite(ceiling) || ceiling < 0)
                    {
                        throw CronwatchException.Invalid("job " + quoted + ": budget." + e.Key + " must be a finite number, 0 or more (got " + Js.FormatNumber(ceiling) + ")");
                    }
                }
            }
        }
        catch (ArgumentException e)
        {
            throw CronwatchException.Invalid(e.Message);
        }
    }

    /// <summary>The definition <see cref="Job"/> would declare, the client's defaults applied, without declaring it.</summary>
    /// <exception cref="CronwatchException">Of kind <see cref="CronwatchErrorKind.Invalid"/>, as <see cref="Job"/> refuses.</exception>
    internal Definition Describe(string name, JobOptions options) => Define(name, options).Stored;

    private Job DeclaredOrNew(string name, JobOptions? options)
    {
        JobDef? def = options == null ? Declared(name) : null;
        return def == null ? Job(name, options) : new Job(this, def);
    }

    /// <summary>
    /// Runs <paramref name="fn"/> as a recorded run of the job <paramref name="name"/>, declared
    /// with no options when it is not declared yet.
    /// </summary>
    public Task RunAsync(string name, Func<JobContext, CancellationToken, Task> fn, CancellationToken cancellationToken = default) =>
        DeclaredOrNew(name, null).RunAsync(fn, cancellationToken);

    /// <summary>Runs <paramref name="fn"/> as a recorded run of the job <paramref name="name"/>, and answers its value.</summary>
    public Task<T> RunAsync<T>(string name, Func<JobContext, CancellationToken, Task<T>> fn, CancellationToken cancellationToken = default) =>
        DeclaredOrNew(name, null).RunAsync(fn, cancellationToken);

    /// <summary>The definitions of the jobs declared in this client, in the order they were first declared.</summary>
    public IReadOnlyList<Definition> DefinedJobs => DeclaredAll().ConvertAll(d => d.Stored);

    /// <summary>
    /// Writes the job declared in this client to the store unless the store already holds that
    /// definition (compared as JSON, keys in any order), and says whether it wrote.
    /// </summary>
    /// <exception cref="CronwatchException">When the job is not declared, or the store fails.</exception>
    public Task<bool> SyncJobAsync(string name, CancellationToken cancellationToken = default)
    {
        JobDef def = Declared(name) ?? throw CronwatchException.Invalid("job " + Json.Quote(name) + " is not declared in this process");
        return Spawn(async () =>
        {
            await EnsureReadyAsync().ConfigureAwait(false);
            StoredJob? stored = await CallAsync(() => _store.GetJobAsync(name)).ConfigureAwait(false);
            bool write = stored == null || !SameJson(stored.Definition.ToObject(), def.Stored.ToObject());
            if (write)
            {
                await CallAsync(() => _store.UpsertJobAsync(def.Stored, Now())).ConfigureAwait(false);
            }
            MarkSynced(def);
            return write;
        }).WaitAsync(cancellationToken);
    }

    private static bool SameJson(object? a, object? b)
    {
        if (a is JsObject x && b is JsObject y)
        {
            if (x.Count != y.Count)
            {
                return false;
            }
            foreach (var e in x)
            {
                if (!y.Has(e.Key) || !SameJson(e.Value, y.Get(e.Key)))
                {
                    return false;
                }
            }
            return true;
        }
        if (a is List<object?> xl && b is List<object?> yl)
        {
            if (xl.Count != yl.Count)
            {
                return false;
            }
            for (int i = 0; i < xl.Count; i++)
            {
                if (!SameJson(xl[i], yl[i]))
                {
                    return false;
                }
            }
            return true;
        }
        if (Json.TryNumber(a, out double da) && Json.TryNumber(b, out double db))
        {
            return da == db;
        }
        return Equals(a, b);
    }

    // ---- runs that span calls

    internal async Task<RunHandle> StartRunAsync(JobDef def, StartOptions options, CancellationToken cancellationToken)
    {
        string? id = options.Id;
        string trigger = options.Trigger ?? "start";
        if (id == null)
        {
            return await Spawn(() => RecordStartAsync(def, trigger, null)).WaitAsync(cancellationToken).ConfigureAwait(false);
        }
        CheckRunId(def.Name, id, "start");
        // Keyed by job as well, so another job's start with the same id is not handed this job's
        // run: it fails as it would one call later.
        string key = def.Name + "\n" + id;
        var mine = new TaskCompletionSource<RunHandle>(TaskCreationOptions.RunContinuationsAsynchronously);
        Task<RunHandle> shared = _starting.GetOrAdd(key, mine.Task);
        if (ReferenceEquals(shared, mine.Task))
        {
            // Let go of before anyone is answered, so a start with this id once answered reads the
            // stored run rather than joining this finished start.
            _ = Spawn(async () =>
            {
                try
                {
                    RunHandle handle = await RecordStartAsync(def, trigger, id).ConfigureAwait(false);
                    _starting.TryRemove(new KeyValuePair<string, Task<RunHandle>>(key, mine.Task));
                    mine.SetResult(handle);
                }
                catch (Exception e)
                {
                    _starting.TryRemove(new KeyValuePair<string, Task<RunHandle>>(key, mine.Task));
                    mine.SetException(e);
                }
            });
        }
        return await shared.WaitAsync(cancellationToken).ConfigureAwait(false);
    }

    private async Task<RunHandle> RecordStartAsync(JobDef def, string trigger, string? id)
    {
        string name = def.Name;
        if (id != null)
        {
            Run? found = null;
            try
            {
                await EnsureReadyAsync().ConfigureAwait(false);
                found = await CallAsync(() => _store.GetRunAsync(id)).ConfigureAwait(false);
            }
            catch (Exception e)
            {
                Report(e, "recording " + name);
            }
            if (found != null)
            {
                return ExistingHandle(def, found);
            }
        }
        Run run = Run.Running(id ?? Guid.NewGuid().ToString(), name, Now(), trigger);
        bool recorded;
        try
        {
            await SyncAsync(def).ConfigureAwait(false);
            await CallAsync(() => _store.InsertRunAsync(run)).ConfigureAwait(false);
            recorded = true;
        }
        catch (Exception e)
        {
            // Another process may have started a run with this id first.
            if (id != null)
            {
                Run? stored = null;
                try
                {
                    stored = await CallAsync(() => _store.GetRunAsync(id)).ConfigureAwait(false);
                }
                catch (Exception)
                {
                    // Reported below as the start's failure.
                }
                if (stored != null)
                {
                    return ExistingHandle(def, stored);
                }
            }
            Report(e, "recording " + name);
            recorded = false;
        }
        if (recorded)
        {
            await CloseOnStartAsync(name).ConfigureAwait(false);
        }
        return new RunHandle(this, def, run.Id, run, recorded, null);
    }

    internal Task<RunHandle> ResumeHandleAsync(JobDef def, string runId, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(runId);
        CheckRunId(def.Name, runId, "resume");
        return Spawn(async () =>
        {
            Run? stored;
            try
            {
                await EnsureReadyAsync().ConfigureAwait(false);
                stored = await CallAsync(() => _store.GetRunAsync(runId)).ConfigureAwait(false);
            }
            catch (Exception e)
            {
                Report(e, "resuming " + def.Name);
                return new RunHandle(this, def, runId, null, true, null);
            }
            if (stored == null)
            {
                return new RunHandle(this, def, runId, null, true, "was not found");
            }
            return ExistingHandle(def, stored);
        }).WaitAsync(cancellationToken);
    }

    private RunHandle ExistingHandle(JobDef def, Run stored)
    {
        if (stored.Job != def.Name)
        {
            throw CronwatchException.Invalid(
                "run " + Json.Quote(stored.Id) + " belongs to job " + Json.Quote(stored.Job) + ", not " + Json.Quote(def.Name));
        }
        bool finished = stored.Status == RunStatus.Ok || stored.Status == RunStatus.Failed;
        return new RunHandle(this, def, stored.Id, stored, true, finished ? "already finished as " + stored.Status.Value : null);
    }

    /// <summary>A handle on a run started elsewhere, as <c>Job(name).ResumeAsync(runId)</c>; the job must be declared in this process.</summary>
    /// <exception cref="CronwatchException">Of kind <see cref="CronwatchErrorKind.Invalid"/> when it is not, or the run is another job's.</exception>
    public Task<RunHandle> ResumeRunAsync(string name, string runId, CancellationToken cancellationToken = default)
    {
        JobDef def = Declared(name) ?? throw CronwatchException.Invalid("resumeRun: job " + Json.Quote(name) + " is not declared; call Job() first");
        return ResumeHandleAsync(def, runId, cancellationToken);
    }

    /// <summary>
    /// Records a run that happened elsewhere (a source's, a platform's), keyed by its id: a new one
    /// is inserted and judged, one already stored and still open is finished and judged, and
    /// answers the alerts it raised. The job must be declared.
    /// </summary>
    /// <exception cref="CronwatchException">When the job is not declared, the id holds a NUL, or the store fails.</exception>
    public Task<IReadOnlyList<Alert>> RecordRunAsync(Run run, bool evaluate = true, CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(run);
        return Spawn(() => RecordRunNowAsync(run, evaluate)).WaitAsync(cancellationToken);
    }

    // ---- checks and reads

    /// <summary>
    /// Checks every job: missed and stuck runs, queued alerts retried, old runs pruned. A check
    /// already running is joined, and every caller gets its answer.
    /// </summary>
    /// <exception cref="CronwatchException">When the store fails.</exception>
    public Task<CheckResult> CheckAsync(CancellationToken cancellationToken = default) => SharedCheckAsync(cancellationToken);

    /// <summary>Every job's summary.</summary>
    /// <exception cref="CronwatchException">When the store fails.</exception>
    public async Task<IReadOnlyList<JobSummary>> JobsAsync(CancellationToken cancellationToken = default)
    {
        var all = await JobsWithRunsAsync(0, cancellationToken).ConfigureAwait(false);
        var output = new List<JobSummary>(all.Count);
        foreach (var j in all)
        {
            output.Add(j.Job);
        }
        return output;
    }

    /// <summary>Every job's summary with its newest runs (20 by default, at most 500).</summary>
    /// <exception cref="CronwatchException">When the store fails.</exception>
    public Task<IReadOnlyList<JobWithRuns>> JobsWithRunsAsync(int limit = 20, CancellationToken cancellationToken = default) =>
        Spawn(() => JobsWithRunsNowAsync(limit)).WaitAsync(cancellationToken);

    /// <summary>A job's summary, or null when the store does not know it.</summary>
    /// <exception cref="CronwatchException">When the store fails.</exception>
    public Task<JobSummary?> JobSummaryAsync(string name, CancellationToken cancellationToken = default) =>
        Spawn(() => JobSummaryNowAsync(name)).WaitAsync(cancellationToken);

    /// <summary>A job's newest runs, from 1 to 500 of them (50 by default).</summary>
    /// <exception cref="CronwatchException">When the store fails.</exception>
    public Task<IReadOnlyList<Run>> RunsAsync(string name, int limit = 50, CancellationToken cancellationToken = default) =>
        Spawn(async () =>
        {
            await EnsureReadyAsync().ConfigureAwait(false);
            return await CallAsync(() => _store.ListRunsAsync(name, ClampLimit(limit, 1))).ConfigureAwait(false);
        }).WaitAsync(cancellationToken);

    /// <summary>A run, or null.</summary>
    /// <exception cref="CronwatchException">When the store fails.</exception>
    public Task<Run?> GetRunAsync(string id, CancellationToken cancellationToken = default) =>
        Spawn(async () =>
        {
            await EnsureReadyAsync().ConfigureAwait(false);
            return await CallAsync(() => _store.GetRunAsync(id)).ConfigureAwait(false);
        }).WaitAsync(cancellationToken);

    /// <summary>Silences a job's alerts for <paramref name="duration"/> (<c>"2h"</c>, a <see cref="TimeSpan"/>, milliseconds).</summary>
    /// <exception cref="CronwatchException">For a bad duration, or when the store fails.</exception>
    public Task<JobState> SilenceAsync(string name, Duration duration, CancellationToken cancellationToken = default)
    {
        double ms = duration.Milliseconds("silence duration");
        return Spawn(() => SilenceMsAsync(name, ms)).WaitAsync(cancellationToken);
    }

    /// <summary>Ends a job's silence.</summary>
    /// <exception cref="CronwatchException">When the store fails.</exception>
    public Task<JobState> UnsilenceAsync(string name, CancellationToken cancellationToken = default) =>
        Spawn(() => PatchStateAsync(name, s => s.SilencedUntil = null)).WaitAsync(cancellationToken);

    /// <summary>Forgets a job: its declaration here, and its definition, runs and state in the store.</summary>
    /// <exception cref="CronwatchException">When the store fails.</exception>
    public Task ForgetAsync(string name, CancellationToken cancellationToken = default) =>
        Spawn(() => ForgetNowAsync(name)).WaitAsync(cancellationToken);

    /// <summary>
    /// Checks on an interval (a minute by default, five seconds at least, at most 2^31 - 1 ms),
    /// the first a second from now, on the client's clock: the SDK's <c>start()</c>, for a
    /// long-running process. A second call does nothing.
    /// </summary>
    public void Start(Duration? every = null) => StartInterval(every is { } e ? e.Milliseconds("check interval") : 60_000);

    /// <summary>Stops the interval.</summary>
    public void Stop() => StopInterval();

    // ---- what a source uses

    /// <summary>The store.</summary>
    public IStore Store => _store;

    /// <summary>Now, on the client's clock, in epoch milliseconds.</summary>
    public long NowMs => Now();

    /// <summary>Reports an error to the client's error handler.</summary>
    public void ReportError(Exception error, string where)
    {
        ArgumentNullException.ThrowIfNull(error);
        Report(error, where ?? "");
    }

    // ---- shutdown

    private void OnProcessExit(object? sender, EventArgs e)
    {
        try
        {
            RecordOpenRunsAsync().Wait(Timings.Shutdown + TimeSpan.FromSeconds(1));
        }
        catch (Exception)
        {
            // The process is ending; nothing more can be done.
        }
    }

    /// <summary>
    /// Stops the interval, records the runs still open in this process as the process-exit hook
    /// does, waits up to five seconds for sends and recordings in flight, cancels what is left,
    /// and disposes the store when it is disposable.
    /// </summary>
    public async ValueTask DisposeAsync()
    {
        if (Interlocked.Exchange(ref _disposed, 1) != 0)
        {
            return;
        }
        StopInterval();
        await RecordOpenRunsAsync().ConfigureAwait(false);
        var pending = new List<Task>(_inFlight.Keys);
        try
        {
            await Task.WhenAll(pending).WaitAsync(Timings.CloseWait, _time).ConfigureAwait(false);
        }
        catch (Exception)
        {
            // Past the wait, or failed: what is left is cancelled below.
        }
        await _closing.CancelAsync().ConfigureAwait(false);
        if (_processExitHook)
        {
            AppDomain.CurrentDomain.ProcessExit -= OnProcessExit;
        }
        if (_transport is LazyTransport owned)
        {
            owned.Dispose();
        }
        try
        {
            if (_store is IAsyncDisposable ad)
            {
                await ad.DisposeAsync().ConfigureAwait(false);
            }
            else if (_store is IDisposable disposable)
            {
                disposable.Dispose();
            }
        }
        catch (Exception e)
        {
            Report(e, "closing the store");
        }
    }

    /// <summary>As <see cref="DisposeAsync"/>, on the calling thread, for a container that disposes synchronously.</summary>
    public void Dispose() => Task.Run(async () => await DisposeAsync().ConfigureAwait(false)).GetAwaiter().GetResult();

    /// <summary>Names the store's type and how many channels there are, never a secret.</summary>
    public override string ToString() => "CronwatchClient(store " + _store.GetType().Name + ", " + _channels.Count + " channels)";
}
