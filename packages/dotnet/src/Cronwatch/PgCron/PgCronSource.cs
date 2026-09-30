using System;
using System.Collections.Generic;
using System.Data.Common;
using System.Globalization;
using System.Linq;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using System.Transactions;
using Cronwatch.Internal;

namespace Cronwatch.PgCron;

/// <summary>One query, answering its rows, each a map of column name to value.</summary>
internal delegate Task<List<Dictionary<string, object?>>> PgCronQuery(string sql, object[] parameters, CancellationToken cancellationToken);

/// <summary>
/// Watches pg_cron jobs, which run inside Postgres where nothing can wrap them: the SDK's
/// <c>pgCron()</c> source (<c>sources/pgcron.ts</c>), line for line as the Go, Rust, Elixir and
/// Java ports have it. On every check it reads <c>cron.job</c> and declares each job with its
/// schedule, then copies new rows of <c>cron.job_run_details</c> in as runs (ids
/// <c>pgcron:&lt;prefix&gt;&lt;runid&gt;</c>), so the usual evaluation raises missed, failed,
/// stuck and slow alerts.
/// </summary>
/// <remarks>
/// <para>
/// A job that is renamed, unscheduled or no longer picked keeps its old name's runs and history,
/// and that name is declared again without a schedule, so it is never reported missed. Its
/// description says why.
/// </para>
/// <para>
/// The data source must reach the database pg_cron runs in (its <c>cron.database_name</c>). Each
/// query opens a connection of its own from the data source, outside any ambient transaction
/// (<see cref="TransactionScopeOption.Suppress"/>), so the source never reads inside a transaction
/// the app has open, and it never commits or rolls back anything. Settings are read from
/// <c>pg_settings</c>, which answers no row for a setting the role may not read, where
/// <c>current_setting()</c> would raise an error.
/// </para>
/// </remarks>
public sealed class PgCronSource : ISource
{
    /// <summary>
    /// How long a run pg_cron has queued but not started (no start time yet) is waited for: ten
    /// minutes. After that it is copied as running from when it was first seen, so a run that
    /// never starts is marked stuck like any other.
    /// </summary>
    public const long HoldMs = 10 * 60_000L;

    /// <summary>How many of a job's newest runs are copied, without alerting, the first time it is seen.</summary>
    private const int Backfill = 20;

    /// <summary>Run details read per query, and the most queries one sync makes.</summary>
    private const int Page = 500;

    private const int MaxPages = 10;

    internal const string JobsSql = "SELECT jobid, jobname, schedule, database, username, active FROM cron.job ORDER BY jobid";

    // pg_settings has no row for a setting the role may not read, where current_setting() raises
    // an error that would abort the caller's transaction.
    internal const string SettingSql = "SELECT setting FROM pg_settings WHERE name = $1";

    private const string Columns = "d.runid, d.jobid, d.status, d.return_message, d.start_time, d.end_time";

    // Every tracked job's runs after its cursor, and any run still open here, whatever its job.
    // The arrays are passed as array literals in text, which every driver can send.
    internal const string RunsSql = "SELECT " + Columns + "\n  FROM cron.job_run_details d\n"
        + "  LEFT JOIN unnest($1::text::bigint[], $2::text::bigint[]) AS c(jobid, after) ON d.jobid = c.jobid\n"
        + "  WHERE d.runid > c.after OR d.runid = ANY($3::text::bigint[])\n"
        + "  ORDER BY d.runid LIMIT 500";

    internal const string NewestSql = "SELECT " + Columns + " FROM cron.job_run_details d WHERE d.jobid = $1 ORDER BY d.runid DESC LIMIT 20";

    private static readonly string[] Unscheduled = ["description", "tags", "grace", "timeout", "maxDuration", "budget", "failuresBeforeAlert"];

    private readonly PgCronQuery _db;
    private readonly PgCronOptions _o;
    private readonly string _idPrefix;
    private readonly JobQueues _turn = new();

    /// <summary>The newest runid read for each jobid, once known.</summary>
    private readonly Dictionary<long, long> _cursors = [];

    /// <summary>The start of the newest run copied for each jobid: where a restart row with no times goes.</summary>
    private readonly Dictionary<long, long> _lastAt = [];

    /// <summary>Runs copied while still going, by runid, with their job: read again until they finish, even once a check marks them timeout.</summary>
    private readonly Dictionary<long, string> _pending = [];

    /// <summary>Runs read before they started, by runid, with when they were first seen.</summary>
    private readonly Dictionary<long, long> _held = [];

    /// <summary>Each job's name and definition as last declared, by jobid, in jobid order.</summary>
    private SortedDictionary<long, (string Name, Definition Definition)> _known = [];

    /// <summary>The last definition declared for each name, so an unchanged job is not declared again.</summary>
    private readonly Dictionary<string, string> _declared = new(StringComparer.Ordinal);

    /// <summary>Names declared again without a schedule by Retire, whose open runs are still read.</summary>
    private readonly HashSet<string> _retired = new(StringComparer.Ordinal);

    private bool _scanned;
    private readonly HashSet<string> _warned = new(StringComparer.Ordinal);

    /// <summary>Jobids whose callback failed, reported once until it works again.</summary>
    private readonly HashSet<long> _failing = [];

    /// <summary>A source over a Postgres data source (an <c>NpgsqlDataSource</c>), watching the jobs <paramref name="options"/> picks.</summary>
    /// <exception cref="CronwatchException">Of kind <see cref="CronwatchErrorKind.Invalid"/> for options that contradict themselves.</exception>
    public PgCronSource(DbDataSource dataSource, PgCronOptions? options = null)
        : this(QueryOver(dataSource ?? throw new ArgumentNullException(nameof(dataSource))), options)
    {
    }

    /// <summary>A source over any query function, for the tests' fake <c>cron</c> schema.</summary>
    internal PgCronSource(PgCronQuery query, PgCronOptions? options)
    {
        _db = query;
        _o = options ?? new PgCronOptions();
        _o.Check();
        _idPrefix = "pgcron:" + _o.Prefix;
    }

    /// <inheritdoc/>
    public string Name => "pg_cron";

    /// <summary>Names the options set, never the data source.</summary>
    public override string ToString() => "PgCronSource(" + _o + ")";

    // ---- the SDK's helpers

    /// <summary>
    /// A pg_cron schedule as a CronWatch one (<c>pgCronSchedule</c>): a cron expression, <c>$</c>
    /// for the last day of the month read as <c>L</c>, or <c>N seconds</c> as <c>every Ns</c>.
    /// pg_cron reads only the first five fields of an expression and ignores the rest, so only
    /// those are kept (a sixth would otherwise be read as seconds). Null for one that has no
    /// cadence to watch (<c>@reboot</c>).
    /// </summary>
    public static string? ToSchedule(string schedule)
    {
        ArgumentNullException.ThrowIfNull(schedule);
        string text = Js.Trim(schedule);
        string? seconds = Seconds(text);
        if (seconds != null)
        {
            return "every " + Js.FormatNumber(double.Parse(seconds, NumberStyles.None, CultureInfo.InvariantCulture)) + "s";
        }
        if (AsciiLower(text) == "@reboot")
        {
            return null;
        }
        List<string> fields = Split(text);
        if (fields.Count > 5 && !fields[0].StartsWith('@'))
        {
            fields = fields.GetRange(0, 5);
        }
        if (fields.Count == 5 && fields[2].Contains('$', StringComparison.Ordinal))
        {
            fields[2] = fields[2].Replace('$', 'L');
        }
        return string.Join(' ', fields);
    }

    /// <summary>The digits of <c>/^(\d+)\s*seconds?$/i</c>, or null when the text is not that.</summary>
    private static string? Seconds(string text)
    {
        int i = 0;
        while (i < text.Length && text[i] >= '0' && text[i] <= '9')
        {
            i++;
        }
        if (i == 0)
        {
            return null;
        }
        int j = i;
        while (j < text.Length && Js.IsSpace(text[j]))
        {
            j++;
        }
        string rest = AsciiLower(text[j..]);
        return rest is "second" or "seconds" ? text[..i] : null;
    }

    /// <summary>Lowercases ASCII letters only, as <c>/i</c> without the <c>u</c> flag folds them.</summary>
    private static string AsciiLower(string s)
    {
        var b = new StringBuilder(s.Length);
        foreach (char c in s)
        {
            b.Append(c >= 'A' && c <= 'Z' ? (char)(c + 32) : c);
        }
        return b.ToString();
    }

    /// <summary><c>text.split(/\s+/)</c> of text already trimmed: <c>""</c> is <c>[""]</c>.</summary>
    private static List<string> Split(string text)
    {
        var output = new List<string>();
        var field = new StringBuilder();
        foreach (char c in text)
        {
            if (Js.IsSpace(c))
            {
                if (field.Length > 0)
                {
                    output.Add(field.ToString());
                    field.Clear();
                }
            }
            else
            {
                field.Append(c);
            }
        }
        output.Add(field.ToString());
        return output;
    }

    /// <summary>
    /// The default CronWatch name for a pg_cron job, before the prefix (<c>pgCronJobName</c>): its
    /// jobname with each run of anything other than letters, digits, <c>.</c>, <c>_</c>, <c>:</c>
    /// and <c>-</c> turned into <c>-</c>, what leads up to the first letter or digit dropped, at
    /// most 100 characters, or <c>pg_cron:&lt;jobid&gt;</c> when nothing is left.
    /// </summary>
    public static string DefaultJobName(PgCronJob job)
    {
        ArgumentNullException.ThrowIfNull(job);
        string name = job.JobName ?? "";
        var cleaned = new StringBuilder();
        bool inRun = false;
        foreach (char c in name)
        {
            if (Alnum(c) || c is '.' or '_' or ':' or '-')
            {
                cleaned.Append(c);
                inRun = false;
            }
            else if (!inRun)
            {
                cleaned.Append('-');
                inRun = true;
            }
        }
        int start = 0;
        while (start < cleaned.Length && !Alnum(cleaned[start]))
        {
            start++;
        }
        string output = cleaned.ToString(start, Math.Min(cleaned.Length - start, 100));
        return output.Length == 0 ? "pg_cron:" + job.JobId.ToString(CultureInfo.InvariantCulture) : output;
    }

    private static bool Alnum(char c) => (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9');

    private static bool Finished(string? status) => status is "succeeded" or "failed";

    /// <summary>
    /// A row of <c>cron.job_run_details</c> as a CronWatch run (<c>pgCronRun</c>), or null for one
    /// that has not started (no start time, not finished). A finished row with no start time
    /// (pg_cron writes these for runs a server restart cut off, "server restarted") starts at its
    /// end time, else at <paramref name="fallbackAt"/> (the source passes the job's newest run's
    /// start, or now).
    /// </summary>
    public static Run? ToRun(PgCronRow row, string job, string idPrefix, long fallbackAt)
    {
        ArgumentNullException.ThrowIfNull(row);
        long? finishedAt = row.EndTime;
        bool done = Finished(row.Status);
        if (row.StartTime == null && !done)
        {
            return null;
        }
        long startedAt = row.StartTime ?? finishedAt ?? fallbackAt;
        string? message = null;
        if (row.ReturnMessage != null)
        {
            string trimmed = Js.Trim(row.ReturnMessage);
            message = trimmed.Length == 0 ? null : trimmed;
        }
        RunStatus status = row.Status == "succeeded" ? RunStatus.Ok : row.Status == "failed" ? RunStatus.Failed : RunStatus.Running;
        long? end = done ? Math.Max(startedAt, finishedAt ?? startedAt) : null;
        return new Run
        {
            Id = idPrefix + row.RunId.ToString(CultureInfo.InvariantCulture),
            Job = job,
            Status = status,
            StartedAt = startedAt,
            FinishedAt = end,
            DurationMs = end is { } e ? Evaluate.RunDuration(startedAt, e) : null,
            Error = status == RunStatus.Failed ? message ?? "pg_cron reported the run as failed" : null,
            Output = status == RunStatus.Ok ? message : null,
            Trigger = "pg_cron",
        };
    }

    // ---- the sync

    /// <inheritdoc/>
    public async Task<IReadOnlyList<Alert>?> SyncAsync(CronwatchClient client, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(client);
        // One sync at a time, in turn: they share the cursors.
        using (await _turn.EnterAsync("sync").ConfigureAwait(false))
        {
            return await SyncLockedAsync(client, cancellationToken).ConfigureAwait(false);
        }
    }

    private void WarnOnce(CronwatchClient host, string key, string message)
    {
        if (_warned.Add(key))
        {
            host.ReportError(new CronwatchException(message), "source pg_cron");
        }
    }

    /// <summary>A server setting from pg_settings, or null when the role may not read it (or it failed).</summary>
    private async Task<string?> SettingAsync(string name, CancellationToken ct)
    {
        try
        {
            var rows = await _db(SettingSql, [name], ct).ConfigureAwait(false);
            return rows.Count == 0 ? null : Text(rows[0].GetValueOrDefault("setting"));
        }
        catch (Exception e) when (e is not OperationCanceledException || !ct.IsCancellationRequested)
        {
            return null;
        }
    }

    /// <summary>The pg_cron runid of a run id this source made (<c>Number()</c> of the rest), or null.</summary>
    private long? RunIdOf(string id)
    {
        if (!id.StartsWith(_idPrefix, StringComparison.Ordinal))
        {
            return null;
        }
        string rest = Js.Trim(id[_idPrefix.Length..]);
        if (rest.Length == 0)
        {
            return 0;
        }
        // A decimal number only: no id this source made has anything else.
        foreach (char c in rest)
        {
            if (!(c >= '0' && c <= '9') && c is not ('.' or 'e' or 'E' or '+' or '-'))
            {
                return null;
            }
        }
        if (!double.TryParse(rest, NumberStyles.Float, CultureInfo.InvariantCulture, out double n))
        {
            return null;
        }
        return Js.IsInteger(n) && Math.Abs(n) <= Js.MaxSafeInteger ? (long)n : null;
    }

    private static string KeyOf(Definition definition) => definition.ToJson();

    /// <summary>
    /// The options of a declared or stored definition that can be declared again, without its
    /// schedule, in the SDK's order.
    /// </summary>
    private static JobOptions UnscheduledOptions(Definition definition)
    {
        var output = new JobOptions();
        foreach (string key in Unscheduled)
        {
            if (definition.Has(key))
            {
                output.Field(key, definition.Get(key));
            }
        }
        return output;
    }

    /// <summary>Declares a name this source no longer uses for any job again, without its schedule.</summary>
    private void Retire(CronwatchClient host, string name, Definition definition, string why)
    {
        JobOptions next = UnscheduledOptions(definition);
        object? description = definition.Get("description");
        next.Field("description", (description == null ? "pg_cron job" : AlertFormat.JsText(description)) + " (" + why + ")");
        try
        {
            host.Job(name, next);
            _declared[name] = KeyOf(next.Describe(name));
            _retired.Add(name);
        }
        catch (Exception e)
        {
            host.ReportError(e, "source pg_cron: job " + name);
        }
    }

    private bool Picks(PgCronJob job)
    {
        if (_o.Pick != null)
        {
            return _o.Pick(job);
        }
        if (_o.Jobs == null && _o.JobIds == null)
        {
            return true;
        }
        if (_o.JobIds != null && _o.JobIds.Contains(job.JobId))
        {
            return true;
        }
        return _o.Jobs != null && job.JobName != null && _o.Jobs.Contains(job.JobName, StringComparer.Ordinal);
    }

    /// <summary>What a callback threw, as the SDK names an error: its type's simple name, then its message.</summary>
    private static string Threw(Exception e) => OutputText.ErrorName(e) + ": " + OutputText.MessageOf(e);

    /// <summary>The job's options: description and tags, the app's, then the schedule when there is one.</summary>
    private static JobOptions OptionsOf(string description, JobOptions? extra, string? schedule, string timezone)
    {
        var options = extra?.Expect is { } expect ? new JobOptions { Expect = expect } : new JobOptions();
        options.Field("description", description);
        options.Field("tags", new List<object?> { "pg_cron" });
        if (extra != null)
        {
            foreach (var e in extra.Fields())
            {
                options.Field(e.Key, e.Value);
            }
        }
        if (schedule != null)
        {
            options.Field("schedule", schedule);
            options.Field("timezone", timezone);
        }
        return options;
    }

    private async Task<IReadOnlyList<Alert>> SyncLockedAsync(CronwatchClient host, CancellationToken ct)
    {
        long now = host.NowMs;
        string? timezone = _o.Timezone;
        if (string.IsNullOrEmpty(timezone))
        {
            string? tz = await SettingAsync("cron.timezone", ct).ConfigureAwait(false);
            if (tz == null)
            {
                WarnOnce(host, "tz", "could not read cron.timezone; assuming UTC. Grant pg_read_all_settings or set PgCronOptions.Timezone.");
            }
            timezone = tz == null || IsUtc(tz) ? "UTC" : tz;
        }
        string? logRun = await SettingAsync("cron.log_run", ct).ConfigureAwait(false);
        bool recording = logRun != "off";
        if (!recording)
        {
            WarnOnce(host, "log_run", "cron.log_run is off, so pg_cron records no runs: jobs are watched without their schedules and no run can fail. Turn it on to watch them.");
        }

        var rows = await _db(JobsSql, [], ct).ConfigureAwait(false);
        if (rows.Count == 0)
        {
            WarnOnce(host, "empty", "cron.job shows no jobs. pg_cron's row level security shows a role only the jobs it scheduled: connect as that role, or give this one BYPASSRLS.");
        }
        var all = rows.ConvertAll(JobOf);

        // Declare each job. A paused one (active = false) keeps its failures but loses its
        // schedule, so it is not missed.
        var names = new Dictionary<long, string>();
        var order = new List<long>();
        var definitions = new Dictionary<long, Definition>();
        var used = new HashSet<string>(StringComparer.Ordinal);

        // A callback of the app's (Pick, JobName, OptionsFor) that threw, or a JobName that gave
        // no name, fails only its job, as a bad row does: reported once until it works again, and
        // the job carries on as last declared (skipped when it never was), so its runs are still
        // copied.
        void Trouble(PgCronJob job, string what)
        {
            if (_failing.Add(job.JobId))
            {
                host.ReportError(
                    new CronwatchException("pg_cron job " + job.JobId.ToString(CultureInfo.InvariantCulture) + ": " + what + "; it keeps its last declaration until that works"),
                    "source pg_cron");
            }
            if (!_known.TryGetValue(job.JobId, out var last) || used.Contains(last.Name))
            {
                return;
            }
            names[job.JobId] = last.Name;
            order.Add(job.JobId);
            definitions[job.JobId] = last.Definition;
            used.Add(last.Name);
        }

        foreach (PgCronJob job in all)
        {
            bool picked;
            try
            {
                picked = Picks(job);
            }
            catch (Exception e)
            {
                Trouble(job, "the jobs callback threw " + Threw(e));
                continue;
            }
            if (!picked)
            {
                _failing.Remove(job.JobId);
                continue;
            }
            string? given;
            try
            {
                given = _o.JobName != null ? _o.JobName(job) : DefaultJobName(job);
            }
            catch (Exception e)
            {
                Trouble(job, "jobName threw " + Threw(e));
                continue;
            }
            if (given == null)
            {
                Trouble(job, "jobName returned null, not a name");
                continue;
            }
            JobOptions? extra;
            try
            {
                extra = _o.Options ?? _o.OptionsFor?.Invoke(job);
            }
            catch (Exception e)
            {
                Trouble(job, "the options callback threw " + Threw(e));
                continue;
            }
            _failing.Remove(job.JobId);
            string name = _o.Prefix + given;
            if (used.Contains(name))
            {
                name = name + ":" + job.JobId.ToString(CultureInfo.InvariantCulture);
            }
            used.Add(name);
            try
            {
                if (extra != null && PgCronOptions.FromPgCron(extra))
                {
                    throw CronwatchException.Invalid(PgCronOptions.OptionsRefusal);
                }
                string? schedule = job.Active && recording ? ToSchedule(job.Schedule) : null;
                string description = "pg_cron job " + job.JobId.ToString(CultureInfo.InvariantCulture) + " in " + job.Database + " as " + job.Username + (job.Active ? "" : " (paused)");
                JobOptions options = OptionsOf(description, extra, schedule, timezone);
                Definition definition = options.Describe(name);
                string key = KeyOf(definition);
                // One forgotten since it was declared (the dashboard's forget) is declared again,
                // though unchanged: RecordRunAsync takes runs only of a declared job.
                if (!_declared.TryGetValue(name, out string? was) || was != key || host.Declared(name) == null)
                {
                    try
                    {
                        host.Job(name, options);
                    }
                    catch (CronwatchException e) when (schedule != null)
                    {
                        // A schedule CronWatch cannot read: watch the runs, not the cadence.
                        host.ReportError(
                            new CronwatchException("pg_cron job " + job.JobId.ToString(CultureInfo.InvariantCulture) + ": " + e.Message + "; watching it without a schedule"),
                            "source pg_cron");
                        JobOptions without = OptionsOf(description, extra, null, timezone);
                        definition = without.Describe(name);
                        host.Job(name, without);
                    }
                    _declared[name] = key;
                }
                names[job.JobId] = name;
                order.Add(job.JobId);
                definitions[job.JobId] = definition;
            }
            catch (Exception e)
            {
                host.ReportError(e, "source pg_cron: job " + job.JobId.ToString(CultureInfo.InvariantCulture));
            }
        }

        // A name this source used for a job that has since been renamed, unscheduled or dropped
        // from the jobs picked.
        var inUse = new HashSet<string>(names.Values, StringComparer.Ordinal);
        _retired.ExceptWith(inUse);
        foreach (var (jobId, previous) in _known)
        {
            if (inUse.Contains(previous.Name))
            {
                continue;
            }
            Retire(host, previous.Name, previous.Definition, names.TryGetValue(jobId, out string? renamed) ? "renamed to " + renamed : "no longer watched");
        }
        var nowKnown = new SortedDictionary<long, (string Name, Definition Definition)>();
        foreach (var (jobId, name) in names)
        {
            nowKnown[jobId] = (name, definitions[jobId]);
        }
        _known = nowKnown;
        // Once per source, the same for names left scheduled in the store while nothing was
        // watching.
        if (!_scanned && rows.Count > 0)
        {
            _scanned = true;
            await ScanAsync(host, all, names, inUse, ct).ConfigureAwait(false);
        }
        if (!recording || names.Count == 0)
        {
            return [];
        }

        var alerts = new List<Alert>();

        // Where each job left off. Found from the store the first time, so a restart carries on.
        foreach (long jobId in order)
        {
            string name = names[jobId];
            if (_cursors.ContainsKey(jobId))
            {
                continue;
            }
            var ours = new List<(Run Run, long Id)>();
            foreach (Run r in await host.Store.ListRunsAsync(name, Backfill, ct).ConfigureAwait(false))
            {
                if (RunIdOf(r.Id) is { } id)
                {
                    ours.Add((r, id));
                }
            }
            if (ours.Count > 0)
            {
                long cursor = long.MinValue;
                long last = long.MinValue;
                foreach (var (r, id) in ours)
                {
                    cursor = Math.Max(cursor, id);
                    last = Math.Max(last, r.StartedAt);
                    if (r.Status == RunStatus.Running || r.Status == RunStatus.Timeout)
                    {
                        _pending[id] = r.Job;
                    }
                }
                _cursors[jobId] = cursor;
                _lastAt[jobId] = last;
                continue;
            }
            // First sight: copy recent history quietly, and judge only from the newest finished
            // run on. The cursor goes to the newest row read, whatever is held, so history is
            // never judged later.
            var ordered = (await _db(NewestSql, [jobId], ct).ConfigureAwait(false)).ConvertAll(RowOf);
            ordered.Reverse();
            int lastFinished = -1;
            for (int i = 0; i < ordered.Count; i++)
            {
                if (Finished(ordered[i].Status))
                {
                    lastFinished = i;
                }
            }
            for (int i = 0; i < ordered.Count; i++)
            {
                PgCronRow row = ordered[i];
                // Already copied under another name (the job was renamed while nothing watched): left.
                if (await host.Store.GetRunAsync(_idPrefix + row.RunId.ToString(CultureInfo.InvariantCulture), ct).ConfigureAwait(false) != null)
                {
                    continue;
                }
                await RecordAsync(host, names, row, i >= lastFinished, now, alerts, ct).ConfigureAwait(false);
            }
            _cursors[jobId] = ordered.Count == 0 ? 0 : ordered[^1].RunId;
        }

        // New runs, runs copied while still going (or since marked timeout), and runs not yet
        // started.
        var watched = new HashSet<string>(names.Values, StringComparer.Ordinal);
        watched.UnionWith(_retired);
        foreach (Run run in await host.Store.RunningRunsAsync(ct).ConfigureAwait(false))
        {
            if (RunIdOf(run.Id) is { } id && watched.Contains(run.Job))
            {
                _pending[id] = run.Job;
            }
        }
        var open = new SortedSet<long>(_pending.Keys);
        open.UnionWith(_held.Keys);
        bool complete = false;
        for (int page = 0; page < MaxPages; page++)
        {
            var afters = order.ConvertAll(j => _cursors.GetValueOrDefault(j, 0));
            var found = await _db(RunsSql, [ArrayOf(order), ArrayOf(afters), ArrayOf(open)], ct).ConfigureAwait(false);
            foreach (var r in found)
            {
                PgCronRow row = RowOf(r);
                open.Remove(row.RunId);
                await RecordAsync(host, names, row, true, now, alerts, ct).ConfigureAwait(false);
                // Held or not, the cursor moves on: a held run is read again by its runid.
                if (names.ContainsKey(row.JobId) && row.RunId > _cursors.GetValueOrDefault(row.JobId, 0))
                {
                    _cursors[row.JobId] = row.RunId;
                }
            }
            if (found.Count < Page)
            {
                complete = true;
                break;
            }
        }
        // Every row was read and these were not among them: pg_cron no longer has them.
        if (complete)
        {
            foreach (long runId in open)
            {
                _pending.Remove(runId);
                _held.Remove(runId);
            }
        }
        return alerts;
    }

    /// <summary>cron.timezone's value that is UTC by another name: <c>/^(gmt|utc|z)$/i</c>.</summary>
    private static bool IsUtc(string tz) => AsciiLower(tz) is "gmt" or "utc" or "z";

    /// <summary>
    /// Names this source's kind left scheduled in the store while nothing was watching: one whose
    /// job is gone from cron.job, or was renamed, is declared again without its schedule.
    /// </summary>
    private async Task ScanAsync(CronwatchClient host, List<PgCronJob> all, Dictionary<long, string> names, HashSet<string> inUse, CancellationToken ct)
    {
        try
        {
            var visible = new HashSet<long>(all.Select(j => j.JobId));
            foreach (StoredJob stored in await host.Store.ListJobsAsync(ct).ConfigureAwait(false))
            {
                Definition def = stored.Definition;
                string schedule = def.Get("schedule") as string ?? "";
                if (!stored.Name.StartsWith(_o.Prefix, StringComparison.Ordinal)
                    || inUse.Contains(stored.Name)
                    || schedule.Length == 0
                    || !def.Tags.Contains("pg_cron"))
                {
                    continue;
                }
                if (DescribedJobId(def.Get("description")) is not { } jobId)
                {
                    continue;
                }
                if (!visible.Contains(jobId))
                {
                    Retire(host, stored.Name, def, "no longer in cron.job");
                }
                else if (names.TryGetValue(jobId, out string? current)
                    // Another pg_cron source's name for the same job ends the same way: left alone.
                    && !stored.Name.EndsWith(current[_o.Prefix.Length..], StringComparison.Ordinal))
                {
                    Retire(host, stored.Name, def, "renamed to " + current);
                }
            }
        }
        catch (Exception e) when (e is not OperationCanceledException || !ct.IsCancellationRequested)
        {
            host.ReportError(e, "source pg_cron");
        }
    }

    /// <summary>The jobid a description this source wrote names (<c>/^pg_cron job (\d+) in /</c>).</summary>
    private static long? DescribedJobId(object? description)
    {
        const string Lead = "pg_cron job ";
        if (description is not string d || !d.StartsWith(Lead, StringComparison.Ordinal))
        {
            return null;
        }
        int i = Lead.Length;
        while (i < d.Length && d[i] >= '0' && d[i] <= '9')
        {
            i++;
        }
        if (i == Lead.Length || string.CompareOrdinal(d, i, " in ", 0, 4) != 0)
        {
            return null;
        }
        // Number() of the digits: past a long they are no jobid pg_cron has.
        return long.TryParse(d.AsSpan(Lead.Length, i - Lead.Length), NumberStyles.None, CultureInfo.InvariantCulture, out long id) ? id : null;
    }

    /// <summary>Copies one row. A row that cannot be recorded is reported and skipped; it never stops the others.</summary>
    private async Task RecordAsync(CronwatchClient host, Dictionary<long, string> names, PgCronRow row, bool evaluate, long now, List<Alert> alerts, CancellationToken ct)
    {
        long runId = row.RunId;
        long jobId = row.JobId;
        string? name = _pending.TryGetValue(runId, out string? p) ? p : names.GetValueOrDefault(jobId);
        if (name == null)
        {
            _held.Remove(runId);
            return;
        }
        Run? run;
        if (row.StartTime == null && !Finished(row.Status))
        {
            long since = _held.TryGetValue(runId, out long h) ? h : now;
            if (now - since < HoldMs)
            {
                _held[runId] = since;
                return;
            }
            run = ToRun(row with { StartTime = since }, name, _idPrefix, now);
        }
        else
        {
            run = ToRun(row, name, _idPrefix, _lastAt.TryGetValue(jobId, out long l) ? l : now);
        }
        _held.Remove(runId);
        if (run == null)
        {
            return;
        }
        try
        {
            alerts.AddRange(await host.RecordRunAsync(run, evaluate, ct).ConfigureAwait(false));
        }
        catch (Exception e) when (e is not OperationCanceledException || !ct.IsCancellationRequested)
        {
            host.ReportError(e, "source pg_cron: run " + runId.ToString(CultureInfo.InvariantCulture));
            return;
        }
        if (run.Status == RunStatus.Running)
        {
            _pending[runId] = name;
        }
        else
        {
            _pending.Remove(runId);
        }
        if (!_lastAt.TryGetValue(jobId, out long lastAt) || run.StartedAt > lastAt)
        {
            _lastAt[jobId] = run.StartedAt;
        }
    }

    /// <summary>A Postgres array literal, <c>{1,2,3}</c>.</summary>
    internal static string ArrayOf(IEnumerable<long> ids) =>
        "{" + string.Join(',', ids.Select(id => id.ToString(CultureInfo.InvariantCulture))) + "}";

    // ---- reading values as a driver or a fake gives them

    private static string? Text(object? v) => v switch
    {
        null or DBNull => null,
        string s => s,
        IFormattable f => f.ToString(null, CultureInfo.InvariantCulture),
        _ => v.ToString(),
    };

    private static long Integer(object? v)
    {
        switch (v)
        {
            case long n:
                return n;
            case int n:
                return n;
            case short n:
                return n;
            case decimal n:
                return (long)n;
            case double n:
                return Js.ToLong(n);
            default:
                string? s = Text(v);
                return s != null && long.TryParse(Js.Trim(s), NumberStyles.AllowLeadingSign, CultureInfo.InvariantCulture, out long parsed) ? parsed : 0;
        }
    }

    private static bool Bool(object? v) => v is bool b ? b : AsciiLower(Text(v) ?? "") is "t" or "true" or "1";

    /// <summary>A time as epoch milliseconds: milliseconds, a <see cref="DateTime"/> (UTC), a <see cref="DateTimeOffset"/>, or ISO text; else null.</summary>
    private static long? Time(object? v)
    {
        switch (v)
        {
            case null or DBNull:
                return null;
            case long n:
                return n;
            case DateTime t:
                return Js.FloorDiv((t.Kind == DateTimeKind.Local ? t.ToUniversalTime() : t).Ticks - DateTime.UnixEpoch.Ticks, TimeSpan.TicksPerMillisecond);
            case DateTimeOffset o:
                return Js.FloorDiv(o.UtcTicks - DateTime.UnixEpoch.Ticks, TimeSpan.TicksPerMillisecond);
            default:
                string? s = Text(v);
                return s != null && DateTimeOffset.TryParse(Js.Trim(s), CultureInfo.InvariantCulture, DateTimeStyles.AssumeUniversal, out var parsed)
                    ? Js.FloorDiv(parsed.UtcTicks - DateTime.UnixEpoch.Ticks, TimeSpan.TicksPerMillisecond)
                    : null;
        }
    }

    private static PgCronJob JobOf(Dictionary<string, object?> r) => new(
        Integer(r.GetValueOrDefault("jobid")),
        Text(r.GetValueOrDefault("jobname")),
        Text(r.GetValueOrDefault("schedule")) ?? "",
        Text(r.GetValueOrDefault("database")) ?? "",
        Text(r.GetValueOrDefault("username")) ?? "",
        Bool(r.GetValueOrDefault("active")));

    private static PgCronRow RowOf(Dictionary<string, object?> r) => new(
        Integer(r.GetValueOrDefault("runid")),
        Integer(r.GetValueOrDefault("jobid")),
        Text(r.GetValueOrDefault("status")),
        Text(r.GetValueOrDefault("return_message")),
        Time(r.GetValueOrDefault("start_time")),
        Time(r.GetValueOrDefault("end_time")));

    /// <summary>
    /// Queries on a connection of their own, opened from the data source outside any ambient
    /// transaction, with positional parameters (<c>$1</c>), reading every row.
    /// </summary>
    private static PgCronQuery QueryOver(DbDataSource dataSource) => async (sql, parameters, ct) =>
    {
        DbConnection connection;
        using (new TransactionScope(TransactionScopeOption.Suppress, TransactionScopeAsyncFlowOption.Enabled))
        {
            connection = await dataSource.OpenConnectionAsync(ct).ConfigureAwait(false);
        }
        await using (connection.ConfigureAwait(false))
        {
            DbCommand command = connection.CreateCommand();
            await using (command.ConfigureAwait(false))
            {
                command.CommandText = sql;
                foreach (object value in parameters)
                {
                    DbParameter p = command.CreateParameter();
                    p.Value = value;
                    command.Parameters.Add(p);
                }
                DbDataReader reader = await command.ExecuteReaderAsync(ct).ConfigureAwait(false);
                await using (reader.ConfigureAwait(false))
                {
                    var rows = new List<Dictionary<string, object?>>();
                    while (await reader.ReadAsync(ct).ConfigureAwait(false))
                    {
                        var row = new Dictionary<string, object?>(StringComparer.Ordinal);
                        for (int i = 0; i < reader.FieldCount; i++)
                        {
                            row[reader.GetName(i)] = await reader.IsDBNullAsync(i, ct).ConfigureAwait(false) ? null : reader.GetValue(i);
                        }
                        rows.Add(row);
                    }
                    return rows;
                }
            }
        }
    };
}
