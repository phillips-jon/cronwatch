using System;
using System.Collections.Generic;
using System.Globalization;

namespace Cronwatch.Internal;

/// <summary>An alert before it has a title and message.</summary>
/// <param name="Type">What happened.</param>
/// <param name="Run">The run it is about, or null.</param>
/// <param name="Details">What the type carries.</param>
internal sealed record AlertDraft(AlertType Type, Run? Run, AlertDetails Details)
{
    /// <summary>The draft as the SDK writes one.</summary>
    public JsObject ToValue() => new JsObject()
        .Set("type", Type.Value)
        .Set("run", Run?.ToValue())
        .Set("details", Details.ToValue());
}

/// <summary>A state worked out, and the alerts it owes.</summary>
/// <param name="State">The new state.</param>
/// <param name="Alerts">The alerts, in order.</param>
internal sealed record Evaluation(JobState State, IReadOnlyList<AlertDraft> Alerts);

/// <summary>What <see cref="Evaluate.OnCheck"/> found besides the evaluation.</summary>
/// <param name="Evaluation">The state and alerts.</param>
/// <param name="NextExpectedAt">When the schedule says the next run is due, or null.</param>
/// <param name="DueAt">The run the schedule wants now, or null.</param>
internal sealed record CheckOutcome(Evaluation Evaluation, long? NextExpectedAt, long? DueAt);

/// <summary>
/// Pure decisions about a job's health (the SDK's <c>evaluate.ts</c>). Each function takes the
/// current state and returns the new state plus the alerts that should go out. Nothing here
/// touches a store or a network, which is what makes it testable, and what lets
/// <c>conformance/evaluate.json</c> replay a job's life through it event by event.
/// </summary>
/// <remarks>
/// A stored definition may hold anything another writer put there, so a field that cannot be
/// read throws <see cref="ArgumentException"/> with the message the SDK's code would have thrown;
/// the client reports it and shows the job as it would an unevaluable one.
/// </remarks>
internal static class Evaluate
{
    /// <summary>The default grace: ten minutes.</summary>
    public const double DefaultGraceMs = 10 * 60_000;

    /// <summary>The default timeout: an hour.</summary>
    public const double DefaultTimeoutMs = 60 * 60_000;

    /// <summary>Runs faster than this are never called slow, whatever the baseline says.</summary>
    public const double SlowFloorMs = 10_000;

    /// <summary>How many earlier runs a baseline needs before it is trusted.</summary>
    public const int BaselineMinRuns = 5;

    /// <summary>How many successful runs a baseline looks at, and how many runs a summary covers.</summary>
    public const int BaselineWindow = 20;

    /// <summary>The longest duration written: 2^53 - 1, which every port and store reads back unchanged.</summary>
    public const long MaxDurationMs = Js.MaxSafeInteger;

    /// <summary>
    /// How long a run took, from <paramref name="startedAt"/> to <paramref name="finishedAt"/>: 0
    /// when it started later, and never more than <see cref="MaxDurationMs"/>. A foreign row's start
    /// near a 64-bit limit must not make a duration no store can write.
    /// </summary>
    public static long RunDuration(long startedAt, long finishedAt)
    {
        long ms = SaturatingSub(finishedAt, startedAt);
        return ms > 0 ? Math.Min(ms, MaxDurationMs) : 0;
    }

    /// <summary>
    /// When a silence of <paramref name="ms"/> from <paramref name="now"/> ends: a whole
    /// millisecond, never past <see cref="MaxDurationMs"/> (2^53 - 1), however long the silence
    /// asked for. Every port sharing the store reads it back unchanged.
    /// </summary>
    public static long SilenceEnd(long now, double ms)
    {
        return Math.Min(SaturatingAdd(now, Js.ToLong(Math.Floor(Math.Min(ms, MaxDurationMs)))), MaxDurationMs);
    }

    /// <summary>
    /// The version a stored state's <c>version</c> value counts as for compare-and-set: a JSON
    /// number that is a whole number from 0 to 2^53 - 1, else 0.
    /// </summary>
    public static long StateVersion(object? version)
    {
        if (JsonText.TryNumber(version, out double d) && Js.IsInteger(d) && d >= 0 && d <= MaxDurationMs)
        {
            return (long)d;
        }
        return 0;
    }

    /// <summary>
    /// The failures in a row a stored state's <c>consecutiveFailures</c> value counts as, as the
    /// SDK's <c>failureCount</c> reads it: a JSON number that is a whole number, held at 2^53 - 1,
    /// and 0 when it is negative or not a whole number (1.5, "3", Infinity).
    /// </summary>
    public static long FailureCount(object? count) =>
        JsonText.TryNumber(count, out double d) && Js.IsInteger(d) && d > 0 ? (d >= MaxDurationMs ? MaxDurationMs : (long)d) : 0;

    /// <summary>A count of failures in a row held from 0 to 2^53 - 1.</summary>
    public static long FailureCount(long count) => Math.Clamp(count, 0, MaxDurationMs);

    /// <summary>a + b, held at the ends of the range.</summary>
    public static long SaturatingAdd(long a, long b)
    {
        long r = unchecked(a + b);
        return ((a ^ r) & (b ^ r)) < 0 ? (a < 0 ? long.MinValue : long.MaxValue) : r;
    }

    /// <summary>a - b, held at the ends of the range.</summary>
    public static long SaturatingSub(long a, long b)
    {
        long r = unchecked(a - b);
        // Overflow when a and b differ in sign and the result's sign differs from a's.
        if (((a ^ b) & (a ^ r)) < 0)
        {
            return a > b ? long.MaxValue : long.MinValue;
        }
        return r;
    }

    /// <summary>A fresh state: nothing open, no failures, empty lists.</summary>
    public static JobState EmptyState(string job) => JobState.Initial(job);

    /// <summary>
    /// A stored state with every field present, or a fresh one. State written by an older version
    /// lacks the newer fields.
    /// </summary>
    public static JobState NormalizeState(JobState? state, string job)
    {
        if (state == null)
        {
            return EmptyState(job);
        }
        var s = MutableState.Of(state);
        if (s.Job.Length == 0)
        {
            s.Job = job;
        }
        s.Pending();
        s.Queued();
        return s.ToState();
    }

    /// <summary>
    /// <see cref="NormalizeState(JobState?, string)"/> of any stored JSON value: one that is not an
    /// object reads as no state.
    /// </summary>
    public static JobState NormalizeStateValue(object? value, string job) =>
        value is JsObject o ? NormalizeState(JobState.FromValue(o), job) : EmptyState(job);

    private static MutableState CloneState(JobState s) => MutableState.Of(NormalizeState(s, s.Job));

    // ---- delivery

    /// <summary>Alerts kept per job for retry, and per job being sent; past it the oldest go.</summary>
    public const int MaxUndelivered = 20;

    /// <summary>
    /// How long an alert in <c>sending</c> is left to the process sending it. Longer than any send
    /// takes: at most three alerts go out together, each with 25 seconds of triage and 15 of
    /// channels.
    /// </summary>
    public const long SendLeaseMs = 5 * 60_000;

    /// <summary>Identifies an alert across retries, and in <c>sending</c>.</summary>
    public static string AlertKey(Alert a) => a.Type.Value + "|" + Js.FormatLong(a.At) + "|" + (a.Run == null ? "" : a.Run.Id);

    /// <summary>The newest <paramref name="max"/> of <paramref name="list"/>, and how many went.</summary>
    private static (List<T> Kept, int Dropped) Newest<T>(List<T> list, int max)
    {
        int cut = Math.Max(0, list.Count - max);
        return (list.GetRange(cut, list.Count - cut), cut);
    }

    /// <summary>
    /// <paramref name="alerts"/> added to the undelivered queue: one with the same key as a queued
    /// alert replaces it where it stands, the rest go at the end, and only the newest
    /// <see cref="MaxUndelivered"/> stay. <c>Dropped</c> counts those let go.
    /// </summary>
    public static (JobState State, int Dropped) QueueUndelivered(JobState state, IReadOnlyList<Alert> alerts)
    {
        var next = CloneState(state);
        var byKey = new Dictionary<string, Alert>(StringComparer.Ordinal);
        foreach (var a in alerts)
        {
            byKey[AlertKey(a)] = a;
        }
        var queue = new List<Alert>();
        var known = new HashSet<string>(StringComparer.Ordinal);
        foreach (var a in next.Queued())
        {
            string key = AlertKey(a);
            queue.Add(byKey.TryGetValue(key, out var replaced) ? replaced : a);
            known.Add(key);
        }
        foreach (var a in alerts)
        {
            if (!known.Contains(AlertKey(a)))
            {
                queue.Add(a);
            }
        }
        var (kept, dropped) = Newest(queue, MaxUndelivered);
        next.Undelivered = kept;
        return (next.ToState(), dropped);
    }

    /// <summary>
    /// The outbox. Alerts just composed are written with the state that opens their condition,
    /// before any is sent, so a process that stops part way does not lose them: into
    /// <c>sending</c>, each with its lease ending at <paramref name="until"/>, when this process
    /// sends them, or (<paramref name="deferred"/>, delivering at check) straight into the
    /// undelivered queue for a check elsewhere. <c>Dropped</c> counts alerts let go past
    /// <see cref="MaxUndelivered"/>.
    /// </summary>
    public static (JobState State, int Dropped) HoldAlerts(JobState state, IReadOnlyList<Alert> alerts, long until, bool deferred)
    {
        if (alerts.Count == 0)
        {
            return (state, 0);
        }
        if (deferred)
        {
            return QueueUndelivered(state, alerts);
        }
        var next = CloneState(state);
        var sending = new List<SendingAlert>(next.Sending ?? []);
        foreach (var a in alerts)
        {
            sending.Add(new SendingAlert { Until = until, Alert = a });
        }
        var (kept, dropped) = Newest(sending, MaxUndelivered);
        next.Sending = kept;
        return (next.ToState(), dropped);
    }

    /// <summary>
    /// Alerts in <c>sending</c> whose lease ran out by <paramref name="now"/>: the process sending
    /// them stopped before it recorded how the send went. They go to the undelivered queue, where
    /// the retry sends them (with triage, which is never stored with them here) or drops them as
    /// stale. An entry with no alert is dropped; one without a numeric <c>until</c> counts as run
    /// out.
    /// </summary>
    public static (JobState State, int Dropped) ReleaseSending(JobState state, long now)
    {
        var held = new List<SendingAlert>();
        var lapsed = new List<Alert>();
        bool any = false;
        foreach (var e in (IReadOnlyList<SendingAlert>?)state.Sending ?? [])
        {
            if (e.Until is long until && until > now)
            {
                held.Add(e);
                continue;
            }
            any = true;
            if (e.Alert != null)
            {
                lapsed.Add(e.Alert);
            }
        }
        if (!any)
        {
            return (state, 0);
        }
        return QueueUndelivered(state with { Sending = held.Count > 0 ? ValueList<SendingAlert>.Of(held) : null }, lapsed);
    }

    /// <summary>
    /// How a send went. Delivered and stale alerts leave the queue; failed ones replace their
    /// queued copy, so a triage made on this attempt is kept, or join the queue. Every one of them
    /// leaves <c>sending</c>. <c>lastAlertAt</c> moves only on a delivery. <c>Dropped</c> counts
    /// alerts let go past <see cref="MaxUndelivered"/>.
    /// </summary>
    public static (JobState State, int Dropped) RecordSent(
        JobState state, IReadOnlyList<Alert> delivered, IReadOnlyList<Alert> failed, IReadOnlyList<Alert> stale, long now)
    {
        var next = CloneState(state);
        var done = new HashSet<string>(StringComparer.Ordinal);
        foreach (var a in delivered)
        {
            done.Add(AlertKey(a));
        }
        foreach (var a in stale)
        {
            done.Add(AlertKey(a));
        }
        next.Undelivered = next.Queued().FindAll(a => !done.Contains(AlertKey(a)));
        var sent = new HashSet<string>(done, StringComparer.Ordinal);
        foreach (var a in failed)
        {
            sent.Add(AlertKey(a));
        }
        next.Sending = next.Sending?.FindAll(e => e.Alert == null || !sent.Contains(AlertKey(e.Alert)));
        if (delivered.Count > 0)
        {
            next.LastAlertAt = now;
        }
        return QueueUndelivered(next.ToState(), failed);
    }

    private static bool OpenCondition(MutableState s, Condition c, long now)
    {
        if (s.Open.ContainsKey(c))
        {
            return false;
        }
        s.Open[c] = now;
        return true;
    }

    /// <summary>
    /// Closes <paramref name="c"/>. Every open condition has alerted, so closing one owes a
    /// recovered message; it is remembered until a successful run leaves nothing open and sends it.
    /// </summary>
    private static bool CloseCondition(MutableState s, Condition c)
    {
        if (!s.Open.Remove(c))
        {
            return false;
        }
        var pending = s.Pending();
        if (!pending.Contains(c))
        {
            pending.Add(c);
        }
        return true;
    }

    /// <summary>The conditions open, in the order they opened.</summary>
    public static List<Condition> OpenConditions(JobState s) => [.. s.Open.Keys];

    private static double DurationField(Definition def, string key, double fallback) =>
        def.Has(key) ? EvaluateDeps.ParseDuration(def.Get(key), key) : fallback;

    /// <summary>The job's grace in milliseconds.</summary>
    public static double GraceMs(Definition def) => DurationField(def, "grace", DefaultGraceMs);

    /// <summary>The job's timeout in milliseconds.</summary>
    public static double TimeoutMs(Definition def) => DurationField(def, "timeout", DefaultTimeoutMs);

    /// <summary>The slow threshold, or null when there is nothing to compare against yet.</summary>
    internal static (double Ms, string Basis)? SlowThreshold(Definition def, IReadOnlyList<Run> history)
    {
        if (def.Has("maxDuration"))
        {
            return (EvaluateDeps.ParseDuration(def.Get("maxDuration"), "maxDuration"), "maxDuration");
        }
        var durations = new List<double>();
        foreach (var r in history)
        {
            if (durations.Count >= BaselineWindow)
            {
                break;
            }
            if (r.Status == RunStatus.Ok && r.DurationMs != null)
            {
                durations.Add(r.DurationMs.Value);
            }
        }
        if (durations.Count < BaselineMinRuns)
        {
            return null;
        }
        double p = Stats.Percentile(durations, 95) ?? 0;
        return (Math.Max(2 * p, SlowFloorMs),
            "twice the p95 of the last " + durations.Count.ToString(CultureInfo.InvariantCulture) + " runs (" + EvaluateDeps.FormatDuration(p) + ")");
    }

    /// <summary>The run's metrics over their ceiling, or, without one, over three times the usual value.</summary>
    internal static List<BudgetBreach> BudgetBreaches(Definition def, Run run, IReadOnlyList<Run> history)
    {
        var breaches = new List<BudgetBreach>();
        var budget = def.Get("budget") as JsObject;
        foreach (var e in run.Metrics)
        {
            string name = e.Key;
            double value = e.Value;
            if (budget != null && budget.Has(name))
            {
                double ceiling = JsNumber(budget.Get(name));
                if (value > ceiling)
                {
                    breaches.Add(new BudgetBreach(name, value, ceiling, "budget"));
                }
                continue;
            }
            var past = new List<double>();
            foreach (var r in history)
            {
                if (past.Count >= BaselineWindow)
                {
                    break;
                }
                if (r.Status == RunStatus.Ok && r.Metrics.TryGetValue(name, out double v))
                {
                    past.Add(v);
                }
            }
            if (past.Count < BaselineMinRuns)
            {
                continue;
            }
            double usual = Stats.Median(past) ?? 0;
            if (usual > 0 && value > 3 * usual)
            {
                breaches.Add(new BudgetBreach(name, value, 3 * usual, "three times the usual " + AlertFormat.FormatNumber(usual)));
            }
        }
        return breaches;
    }

    /// <summary>
    /// The metrics of a successful run that fell below their floor. A metric with a floor breaches
    /// when it reports less than that floor. One without breaches when it reports 0 or less and
    /// either it did so on the job's last successful run too (<paramref name="previous"/>, the
    /// metrics under their floor then), or the earlier successful runs that reported it (at least
    /// five, the newest twenty) all reported more than 0.
    /// </summary>
    internal static List<BudgetBreach> FloorBreaches(Definition def, Run run, IReadOnlyList<Run> history, IReadOnlyCollection<string>? previous = null)
    {
        var breaches = new List<BudgetBreach>();
        var floors = def.Get("floor") as JsObject;
        var before = new HashSet<string>(previous ?? [], StringComparer.Ordinal);
        foreach (var e in run.Metrics)
        {
            string name = e.Key;
            double value = e.Value;
            if (floors != null && floors.Has(name))
            {
                double floor = JsNumber(floors.Get(name));
                if (value < floor)
                {
                    breaches.Add(new BudgetBreach(name, value, floor, "floor"));
                }
                continue;
            }
            if (value > 0)
            {
                continue;
            }
            if (before.Contains(name))
            {
                breaches.Add(new BudgetBreach(name, value, 0, "0 or less on the run before too"));
                continue;
            }
            var past = new List<double>();
            foreach (var r in history)
            {
                if (past.Count >= BaselineWindow)
                {
                    break;
                }
                if (r.Status == RunStatus.Ok && r.Metrics.TryGetValue(name, out double v))
                {
                    past.Add(v);
                }
            }
            if (past.Count < BaselineMinRuns || !past.TrueForAll(v => v > 0))
            {
                continue;
            }
            double lowest = past[0];
            foreach (double v in past)
            {
                lowest = Math.Min(lowest, v);
            }
            breaches.Add(new BudgetBreach(name, value, lowest,
                "the last " + past.Count.ToString(CultureInfo.InvariantCulture) + " runs all reported more than 0, the lowest " + AlertFormat.FormatNumber(lowest)));
        }
        return breaches;
    }

    /// <summary>Whether <paramref name="history"/> (newest first) holds a full baseline window of successful runs.</summary>
    public static bool HasFullBaseline(IReadOnlyList<Run> history)
    {
        int ok = 0;
        foreach (var r in history)
        {
            if (r.Status == RunStatus.Ok)
            {
                ok++;
            }
        }
        return ok >= BaselineWindow;
    }

    /// <summary>JavaScript's <c>Number(v)</c> for a JSON value, as a comparison with <c>&gt;</c> coerces one.</summary>
    public static double JsNumber(object? v)
    {
        switch (v)
        {
            case null:
                return 0;
            case bool b:
                return b ? 1 : 0;
            case string s:
                string text = Js.Trim(s);
                return text.Length == 0 ? 0 : StringToNumber(text);
            default:
                return JsonText.TryNumber(v, out double n) ? n : double.NaN;
        }
    }

    private static int Digit(char c, int radix)
    {
        int d = c >= '0' && c <= '9' ? c - '0' : c >= 'a' && c <= 'z' ? c - 'a' + 10 : c >= 'A' && c <= 'Z' ? c - 'A' + 10 : -1;
        return d < radix ? d : -1;
    }

    /// <summary>
    /// <c>Number(text)</c> for trimmed, non-empty text: decimal, <c>Infinity</c>, and the
    /// <c>0x</c>, <c>0o</c> and <c>0b</c> integer forms; anything else is NaN.
    /// </summary>
    internal static double StringToNumber(string text)
    {
        double sign = 1;
        string body = text;
        if (text[0] == '-')
        {
            sign = -1;
            body = text[1..];
        }
        else if (text[0] == '+')
        {
            body = text[1..];
        }
        if (body == "Infinity")
        {
            return sign * double.PositiveInfinity;
        }
        int radix = 10;
        if (body.Length >= 2)
        {
            string prefix = body[..2];
            if (prefix is "0x" or "0X")
            {
                radix = 16;
            }
            else if (prefix is "0o" or "0O")
            {
                radix = 8;
            }
            else if (prefix is "0b" or "0B")
            {
                radix = 2;
            }
        }
        if (radix != 10)
        {
            // A sign is not allowed before a prefixed integer.
            if (body.Length != text.Length || body.Length == 2)
            {
                return double.NaN;
            }
            double acc = 0;
            for (int i = 2; i < body.Length; i++)
            {
                int d = Digit(body[i], radix);
                if (d < 0)
                {
                    return double.NaN;
                }
                acc = acc * radix + d;
            }
            return acc;
        }
        bool digit = false;
        foreach (char c in body)
        {
            if (c >= '0' && c <= '9')
            {
                digit = true;
            }
            else if (c != '.' && c != 'e' && c != 'E' && c != '+' && c != '-')
            {
                return double.NaN;
            }
        }
        if (body.Length == 0 || !digit || body[0] == '+' || body[0] == '-')
        {
            return double.NaN;
        }
        return double.TryParse(body, NumberStyles.AllowDecimalPoint | NumberStyles.AllowExponent, CultureInfo.InvariantCulture, out double n)
            ? sign * n
            : double.NaN;
    }

    /// <summary>
    /// Called when a run starts. Missed and stuck are about the absence of a run, so a run
    /// starting closes them without an alert; the recovered message waits for a successful finish.
    /// </summary>
    public static JobState OnRunStart(JobState state)
    {
        var next = CloneState(state);
        CloseCondition(next, Condition.Missed);
        CloseCondition(next, Condition.Stuck);
        return next.ToState();
    }

    /// <summary><c>Math.max(1, def.failuresBeforeAlert ?? 1)</c>.</summary>
    private static double FailuresBeforeAlert(Definition def)
    {
        object? v = def.Get("failuresBeforeAlert");
        if (v == null)
        {
            return 1;
        }
        double n = JsNumber(v);
        return double.IsNaN(n) ? n : Math.Max(n, 1);
    }

    /// <summary>
    /// Called when a run finishes with status ok, failed or timeout. <paramref name="history"/> is
    /// the job's earlier runs, newest first, not including this one.
    /// </summary>
    public static Evaluation OnRunFinish(Definition def, Run run, JobState state, IReadOnlyList<Run> history, long now)
    {
        var next = CloneState(state);
        var alerts = new List<AlertDraft>();

        if (run.Status == RunStatus.Ok)
        {
            next.ConsecutiveFailures = 0;
            CloseCondition(next, Condition.Missed);
            CloseCondition(next, Condition.Stuck);
            CloseCondition(next, Condition.Failed);

            var slow = SlowThreshold(def, history);
            long? duration = run.DurationMs;
            if (slow != null && duration != null && duration.Value > slow.Value.Ms)
            {
                if (OpenCondition(next, Condition.Slow, now))
                {
                    alerts.Add(new AlertDraft(AlertType.Slow, run, new AlertDetails.Slow(duration.Value, slow.Value.Ms, slow.Value.Basis)));
                }
            }
            else
            {
                CloseCondition(next, Condition.Slow);
            }

            var breaches = BudgetBreaches(def, run, history);
            if (breaches.Count > 0)
            {
                if (OpenCondition(next, Condition.OverBudget, now))
                {
                    alerts.Add(new AlertDraft(AlertType.OverBudget, run, new AlertDetails.OverBudget(ValueList<BudgetBreach>.Of(breaches))));
                }
            }
            else
            {
                CloseCondition(next, Condition.OverBudget);
            }

            var shortfalls = FloorBreaches(def, run, history, next.UnderFloor);
            if (shortfalls.Count > 0)
            {
                next.UnderFloor = shortfalls.ConvertAll(b => b.Metric);
                if (OpenCondition(next, Condition.UnderFloor, now))
                {
                    alerts.Add(new AlertDraft(AlertType.UnderFloor, run, new AlertDetails.UnderFloor(ValueList<BudgetBreach>.Of(shortfalls))));
                }
            }
            else
            {
                next.UnderFloor = null;
                CloseCondition(next, Condition.UnderFloor);
            }

            var pending = next.Pending();
            if (pending.Count > 0 && next.Open.Count == 0)
            {
                var after = ValueList<Condition>.Of(pending);
                pending.Clear();
                alerts.Add(new AlertDraft(AlertType.Recovered, run, new AlertDetails.Recovered(after, null, null)));
            }
            return new Evaluation(next.ToState(), alerts);
        }

        // failed or timeout
        // Held at 2^53 - 1: a count at the limit neither loses precision nor wraps below a threshold.
        next.ConsecutiveFailures = Math.Min(FailureCount(next.ConsecutiveFailures) + 1, MaxDurationMs);
        CloseCondition(next, Condition.Missed);
        double threshold = FailuresBeforeAlert(def);
        bool timedOut = run.Status == RunStatus.Timeout;
        var condition = timedOut ? Condition.Stuck : Condition.Failed;
        if (next.ConsecutiveFailures >= threshold && OpenCondition(next, condition, now))
        {
            alerts.Add(new AlertDraft(
                timedOut ? AlertType.Stuck : AlertType.Failed,
                run,
                new AlertDetails.Failure(next.ConsecutiveFailures, Js.ToLong(threshold))));
        }
        return new Evaluation(next.ToState(), alerts);
    }

    /// <summary>JavaScript's truthiness of a JSON value.</summary>
    public static bool Truthy(object? v) => v switch
    {
        null => false,
        bool b => b,
        string s => s.Length != 0,
        _ => !JsonText.TryNumber(v, out double n) || (n != 0 && !double.IsNaN(n)),
    };

    /// <summary>
    /// <c>parseSchedule(def.schedule, def.timezone)</c> for a stored definition, which may hold
    /// anything another writer put there.
    /// </summary>
    /// <exception cref="ArgumentException">When the schedule cannot be read.</exception>
    public static ParsedSchedule ScheduleOf(Definition def)
    {
        if (def.Get("schedule") is not string text)
        {
            throw new ArgumentException("schedule.trim is not a function");
        }
        object? tz = def.Get("timezone");
        string? zone;
        if (tz == null)
        {
            zone = null;
        }
        else if (tz is string s)
        {
            zone = s.Length == 0 ? null : s;
        }
        else
        {
            throw new ArgumentException("timezone " + Json.Stringify(tz) + " is not an IANA timezone");
        }
        return EvaluateDeps.ParseSchedule(text, zone);
    }

    /// <summary>
    /// Called by a check. It decides whether the schedule has been missed: the run the schedule
    /// wants next has not started and its grace has run out. <paramref name="lastRun"/> is the most
    /// recent run of any status. A job with no schedule is never missed, and one whose schedule was
    /// removed while missed was open gets a recovered alert (reason <c>unscheduled</c>) for missed
    /// alone.
    /// </summary>
    public static CheckOutcome OnCheck(Definition def, StoredJob stored, Run? lastRun, JobState state, long now)
    {
        var next = CloneState(state);
        var alerts = new List<AlertDraft>();
        if (!Truthy(def.Get("schedule")))
        {
            if (next.Open.TryGetValue(Condition.Missed, out long since))
            {
                // The schedule went away while missed was open, so nothing is due any more.
                // Missed closes now with a recovery of its own; other open conditions keep their
                // own rules. Missed is taken out of the pending recovery too, so the next
                // successful run does not name it again.
                next.Open.Remove(Condition.Missed);
                next.Pending().RemoveAll(c => c == Condition.Missed);
                alerts.Add(new AlertDraft(
                    AlertType.Recovered,
                    lastRun,
                    new AlertDetails.Recovered(ValueList<Condition>.Of(Condition.Missed), "unscheduled", since)));
            }
            return new CheckOutcome(new Evaluation(next.ToState(), alerts), null, null);
        }

        ParsedSchedule parsed = ScheduleOf(def);
        double grace = GraceMs(def);
        long? lastRunAt = lastRun?.StartedAt;
        var exp = EvaluateDeps.Expectation(parsed, lastRunAt, stored.CreatedAt, grace);
        bool interval = EvaluateDeps.IsInterval(parsed);
        long? nextExpectedAt = interval
            ? EvaluateDeps.NextFire(parsed, stored.CreatedAt, lastRunAt)
            : EvaluateDeps.NextFire(parsed, now, null);
        if (exp == null)
        {
            return new CheckOutcome(new Evaluation(next.ToState(), alerts), nextExpectedAt, null);
        }

        // An interval's next run is due a period after the last one started. If that run is
        // still going, the job is busy, not late; stuck covers one that never ends.
        if (interval && lastRun != null && lastRun.Status == RunStatus.Running)
        {
            return new CheckOutcome(new Evaluation(next.ToState(), alerts), nextExpectedAt, exp.Value.DueAt);
        }

        if (now > exp.Value.Deadline)
        {
            if (OpenCondition(next, Condition.Missed, now))
            {
                alerts.Add(new AlertDraft(
                    AlertType.Missed,
                    lastRun,
                    new AlertDetails.Missed(exp.Value.DueAt, exp.Value.Deadline, grace, lastRunAt)));
            }
        }
        else
        {
            // A run has started since it opened, or the grace was widened.
            CloseCondition(next, Condition.Missed);
        }
        return new CheckOutcome(new Evaluation(next.ToState(), alerts), nextExpectedAt, exp.Value.DueAt);
    }

    /// <summary>Whether a running run has gone on longer than the job's timeout.</summary>
    public static bool IsStuck(Definition def, Run run, long now)
    {
        if (run.Status != RunStatus.Running)
        {
            return false;
        }
        return SaturatingSub(now, run.StartedAt) > TimeoutMs(def);
    }

    /// <summary>
    /// <paramref name="next"/> with nothing opened that was not open in <paramref name="previous"/>.
    /// While a job is silenced conditions may close but none may open, so the first problem after
    /// the silence ends alerts normally.
    /// </summary>
    public static JobState MuteOpens(JobState previous, JobState next)
    {
        var muted = CloneState(next);
        foreach (var c in new List<Condition>(muted.Open.Keys))
        {
            if (previous.OpenAt(c) == null)
            {
                muted.Open.Remove(c);
            }
        }
        return muted.ToState();
    }

    /// <summary>Whether a silence is in force at <paramref name="now"/>.</summary>
    public static bool IsSilenced(JobState state, long now) => state.SilencedUntil is long until && until > now;

    /// <summary>
    /// An evaluation as it is saved and sent: while the job was silenced when it began, nothing
    /// opens and nothing is sent.
    /// </summary>
    public static Evaluation ApplySilence(JobState previous, Evaluation e, long now)
    {
        if (!IsSilenced(previous, now))
        {
            return e;
        }
        return new Evaluation(MuteOpens(previous, e.State), []);
    }

    /// <summary>
    /// Whether an alert waiting to be retried no longer describes the job, so it is dropped rather
    /// than sent late. An alert for a condition is stale once that condition has closed, or has
    /// closed and opened again; a recovery is stale when any condition it names is open again.
    /// </summary>
    public static bool StaleAlert(Alert alert, JobState state)
    {
        // One read from a foreign or damaged row in a shape that cannot be judged (a recovery that
        // says nothing of what it recovers from, an alert with no time) goes.
        if (alert.Damaged)
        {
            return true;
        }
        if (alert.Type == AlertType.Recovered)
        {
            if (alert.Details is not AlertDetails.Recovered r)
            {
                return false;
            }
            foreach (var c in r.After)
            {
                if (state.OpenAt(c) != null)
                {
                    return true;
                }
            }
            return false;
        }
        long? openedAt = state.OpenAt(new Condition(alert.Type.Value));
        return openedAt == null || openedAt.Value != alert.At;
    }

    /// <summary>How a job looks at a glance. Silence wins, then stuck, failing and late.</summary>
    public static JobHealth JobHealthOf(Definition def, Run? lastRun, JobState state, long now)
    {
        var open = OpenConditions(state);
        if (IsSilenced(state, now))
        {
            return JobHealth.Silenced;
        }
        if (open.Contains(Condition.Stuck))
        {
            return JobHealth.Stuck;
        }
        if (lastRun != null && IsStuck(def, lastRun, now))
        {
            return JobHealth.Stuck;
        }
        if (open.Contains(Condition.Failed)
            || (lastRun != null && (lastRun.Status == RunStatus.Failed || lastRun.Status == RunStatus.Timeout)))
        {
            return JobHealth.Failing;
        }
        if (open.Contains(Condition.Missed))
        {
            return JobHealth.Late;
        }
        return lastRun == null ? JobHealth.NeverRan : JobHealth.Healthy;
    }

    /// <summary>
    /// A job's summary from its most recent runs (newest first; the first
    /// <see cref="BaselineWindow"/> are used) and its state. Stats cover runs of any status; the
    /// percentiles are over the successful ones among them.
    /// </summary>
    public static JobSummary Summarize(StoredJob stored, IReadOnlyList<Run> recent, JobState state, long? nextExpectedAt, long now)
    {
        var last = recent.Count == 0 ? null : recent[0];
        var health = JobHealthOf(stored.Definition, last, state, now);
        return Summary(stored, recent, state, nextExpectedAt, health);
    }

    /// <summary>
    /// The summary of a job that could not be evaluated, say because its stored schedule no longer
    /// parses. It reads nothing from the definition. The job shows as failing (or silenced, while
    /// it is), and nothing is known about when it is next due.
    /// </summary>
    public static JobSummary UnevaluableSummary(StoredJob stored, IReadOnlyList<Run> recent, JobState state, long now)
    {
        var health = IsSilenced(state, now) ? JobHealth.Silenced : JobHealth.Failing;
        return Summary(stored, recent, state, null, health);
    }

    private static JobSummary Summary(StoredJob stored, IReadOnlyList<Run> recent, JobState state, long? nextExpectedAt, JobHealth health)
    {
        int count = Math.Min(recent.Count, BaselineWindow);
        long finished = 0;
        long ok = 0;
        var okDurations = new List<double>();
        for (int i = 0; i < count; i++)
        {
            var r = recent[i];
            if (r.Status != RunStatus.Running)
            {
                finished++;
            }
            if (r.Status == RunStatus.Ok)
            {
                ok++;
                if (r.DurationMs != null)
                {
                    okDurations.Add(r.DurationMs.Value);
                }
            }
        }
        double? p50 = Stats.Percentile(okDurations, 50);
        double? p95 = Stats.Percentile(okDurations, 95);
        return new JobSummary
        {
            Name = stored.Name,
            Definition = stored.Definition,
            Health = health,
            Open = ValueList<Condition>.Of(OpenConditions(state)),
            LastRun = count == 0 ? null : recent[0],
            NextExpectedAt = nextExpectedAt,
            ConsecutiveFailures = state.ConsecutiveFailures,
            SilencedUntil = state.SilencedUntil,
            Stats = new JobStats(
                finished,
                finished > 0 ? (double)ok / finished : 1,
                p50 == null ? null : Js.ToLong(p50.Value),
                p95 == null ? null : Js.ToLong(p95.Value)),
        };
    }
}
