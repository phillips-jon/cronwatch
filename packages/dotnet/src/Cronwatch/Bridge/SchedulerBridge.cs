using System;
using System.Collections.Generic;
using System.Diagnostics.CodeAnalysis;
using System.Reflection;
using System.Security.Cryptography;
using System.Text;
using System.Threading.Tasks;
using Cronwatch.Internal;

namespace Cronwatch.Bridge;

/// <summary>
/// What the scheduler integrations share (<c>Cronwatch.Hangfire</c>, <c>Cronwatch.Quartz</c>),
/// carried over from the Go, Rust, Elixir, and Java ports' bridge. An app does not need it; a
/// scheduler integration of the app's own can. For integration authors, outside the 1.x promise: the bridge changes as the integrations need, in any minor release. Every type in
/// <c>Cronwatch.Bridge</c> is.
/// </summary>
/// <remarks>
/// <see cref="Watch"/> declares a scheduler's entries as jobs, one per name, tagged with the
/// integration and the app, and declares a job whose entry is gone again without its schedule, so
/// it is never reported missed. <see cref="CheckFires"/> checks a schedule taken from a scheduler
/// against the scheduler's own fire times. Which jobs are this app's is told by two tags, the
/// integration's (<c>quartz</c>) and the app's under it (<c>quartz:&lt;app&gt;</c>, see
/// <see cref="AppTag"/>), so two apps sharing one store never declare each other's jobs without a
/// schedule, the PHP port's rule.
/// </remarks>
public static class SchedulerBridge
{
    /// <summary>How many runs a <see cref="FireTimes"/> gives after the first when it is asked without an end.</summary>
    public const int SampleRuns = 8;

    /// <summary>How long a sync an integration starts itself may take before it is given up.</summary>
    public static readonly TimeSpan SyncTimeout = TimeSpan.FromSeconds(30);

    private static readonly string[] Kept = ["tags", "grace", "timeout", "maxDuration", "budget", "floor", "failuresBeforeAlert"];

    /// <summary>
    /// The app's name for its tag: <c>$CRONWATCH_APP_ID</c> when set, else
    /// <paramref name="fallback"/> when it is not empty (the host's application name), else the
    /// entry assembly's name. Two apps that share a store and would get the same name need
    /// <c>CRONWATCH_APP_ID</c> (or the integration's <c>App</c> option) to tell them apart; every
    /// process of one app needs the same.
    /// </summary>
    public static string AppName(string? fallback = null)
    {
        string? id = Environment.GetEnvironmentVariable("CRONWATCH_APP_ID");
        if (id != null && Js.Trim(id).Length > 0)
        {
            return Js.Trim(id);
        }
        if (fallback != null && Js.Trim(fallback).Length > 0)
        {
            return Js.Trim(fallback);
        }
        string? entry = Assembly.GetEntryAssembly()?.GetName().Name;
        return string.IsNullOrEmpty(entry) ? "dotnet" : entry;
    }

    /// <summary>
    /// The tag that names the app under an integration's tag: <c>&lt;tag&gt;:&lt;app&gt;</c>, the
    /// app's name lowercased, with anything but letters, digits, <c>.</c>, <c>_</c>, and <c>-</c>
    /// made <c>-</c>. A name that is empty once cleaned, or longer than 48 characters, is cut and
    /// given 8 hex characters of its MD5, so two names never share a tag. The PHP port's
    /// <c>appTag()</c>, character for character.
    /// </summary>
    public static string AppTag(string tag, string app)
    {
        ArgumentNullException.ThrowIfNull(tag);
        ArgumentNullException.ThrowIfNull(app);
        string trimmed = TrimPhp(app);
        var slug = new StringBuilder();
        bool run = false;
        foreach (char ch in trimmed)
        {
            char c = ch;
            // ASCII letters only, as PHP 8's strtolower, so the Kelvin sign is not a "k".
            if (c >= 'A' && c <= 'Z')
            {
                c = (char)(c + ('a' - 'A'));
            }
            if ((c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '.' || c == '_' || c == '-')
            {
                slug.Append(c);
                run = false;
            }
            else if (!run)
            {
                slug.Append('-');
                run = true;
            }
        }
        string s = slug.ToString().Trim('-');
        if (s.Length == 0 || s.Length > 48)
        {
            string cut = (s.Length > 39 ? s[..39] : s) + "-";
            s = cut.TrimStart('-') + Md5(app)[..8];
        }
        return tag + ":" + s;
    }

    /// <summary>PHP's <c>trim()</c>: spaces, tabs, newlines, returns, NULs, and vertical tabs.</summary>
    private static string TrimPhp(string s) => s.Trim(' ', '\t', '\n', '\r', '\0', '\u000b');

    [SuppressMessage("Security", "CA5351", Justification = "A short, stable name for a tag, as the PHP port's appTag writes it; not a security use.")]
    private static string Md5(string s) => Convert.ToHexStringLower(MD5.HashData(Js.Utf8(s)));

    /// <summary>
    /// Whether <paramref name="name"/> is a CronWatch job name: 1 to 120 letters, digits,
    /// <c>.</c>, <c>_</c>, <c>:</c>, or <c>-</c>, starting with a letter or digit.
    /// </summary>
    public static bool ValidName(string name)
    {
        ArgumentNullException.ThrowIfNull(name);
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

    /// <summary>
    /// The definition <c>cw.Job(name, options)</c> would declare, without declaring anything, so
    /// an integration can refuse a scheduler job whose runs it could not record.
    /// </summary>
    /// <exception cref="CronwatchException">For a name or an option the SDK refuses, with its message.</exception>
    public static Definition Definition(CronwatchClient cw, string name, JobOptions options)
    {
        ArgumentNullException.ThrowIfNull(cw);
        ArgumentNullException.ThrowIfNull(options);
        return cw.Describe(name, options.Copy());
    }

    /// <summary>
    /// An interval as CronWatch's schedule text, exact to the millisecond: <c>every 1h30m</c>.
    /// Rounded to the nearest millisecond; <c>every 0ms</c> for none.
    /// </summary>
    public static string EveryText(TimeSpan interval)
    {
        long ms = interval <= TimeSpan.Zero ? 0 : (interval.Ticks + (TimeSpan.TicksPerMillisecond / 2)) / TimeSpan.TicksPerMillisecond;
        var output = new StringBuilder();
        string[] names = ["d", "h", "m", "s", "ms"];
        long[] sizes = [86_400_000L, 3_600_000L, 60_000L, 1000L, 1L];
        for (int i = 0; i < names.Length; i++)
        {
            if (ms >= sizes[i])
            {
                output.Append(Js.FormatLong(ms / sizes[i])).Append(names[i]);
                ms %= sizes[i];
            }
        }
        return output.Length == 0 ? "every 0ms" : "every " + output;
    }

    /// <summary>
    /// The options that declare a job again without its schedule: its description followed by
    /// <c>(no longer scheduled)</c> (<c>A scheduled task</c> when it had none), its tags, grace,
    /// timeout, maxDuration, budget, floor, and failuresBeforeAlert, as stored.
    /// </summary>
    public static JobOptions Unscheduled(Definition def)
    {
        ArgumentNullException.ThrowIfNull(def);
        string description = def.Description is { Length: > 0 } d ? d : "A scheduled task";
        if (!description.EndsWith(" (no longer scheduled)", StringComparison.Ordinal))
        {
            description += " (no longer scheduled)";
        }
        var options = new JobOptions { Description = description };
        foreach (string key in Kept)
        {
            if (def.Has(key))
            {
                WithField(options, def, key);
            }
        }
        return options;
    }

    /// <summary>
    /// The options that declare a stored definition again, in its order: each option the
    /// definition holds, and its expect rule (<c>contains</c> as the same rule, a pattern as the
    /// same pattern run by the JavaScript engine, and a custom function as one that passes every
    /// output, since the function is the other process's). Fields no option gives are left out.
    /// For a worker whose job another process scheduled.
    /// </summary>
    public static JobOptions OptionsOf(Definition def)
    {
        ArgumentNullException.ThrowIfNull(def);
        var options = new JobOptions();
        foreach (string key in def.Keys)
        {
            switch (key)
            {
                case "schedule":
                case "timezone":
                case "description":
                    if (def.Get(key) is string text)
                    {
                        options.SetField(key, text);
                    }
                    break;
                case "expect":
                    if (def.Expect is string expect)
                    {
                        options.SetExpect(Expect.FromStored(expect));
                    }
                    break;
                default:
                    WithField(options, def, key);
                    break;
            }
        }
        return options;
    }

    /// <summary>One of the fields <see cref="Unscheduled"/> keeps, as stored: a duration's text as text and a number of milliseconds as a number.</summary>
    private static void WithField(JobOptions options, Definition def, string key)
    {
        object? value = def.Get(key);
        switch (key)
        {
            case "tags":
                options.SetField("tags", new List<object?>(def.Tags));
                break;
            case "grace":
            case "timeout":
            case "maxDuration":
                if (value is string text)
                {
                    options.SetField(key, text);
                }
                else if (JsonText.TryNumber(value, out double ms))
                {
                    options.SetField(key, ms);
                }
                break;
            case "budget":
                if (value is JsObject budget)
                {
                    foreach (var e in budget)
                    {
                        if (JsonText.TryNumber(e.Value, out double ceiling))
                        {
                            options.Budget[e.Key] = ceiling;
                        }
                    }
                }
                break;
            case "floor":
                if (value is JsObject floors)
                {
                    foreach (var e in floors)
                    {
                        if (JsonText.TryNumber(e.Value, out double floor))
                        {
                            options.Floor[e.Key] = floor;
                        }
                    }
                }
                break;
            case "failuresBeforeAlert":
                if (JsonText.TryNumber(value, out double n) && n >= 0 && n <= int.MaxValue && n == Math.Floor(n))
                {
                    options.SetField(key, (int)n);
                }
                break;
            default:
                // Not an option an integration carries over.
                break;
        }
    }

    /// <summary>
    /// Refuses a cron CronWatch would not expect runs of when the scheduler makes them, with a
    /// message naming <paramref name="where"/> (the job) and <paramref name="scheduler"/> (the
    /// scheduler's name). <paramref name="runs"/> are the scheduler's own fire times, from its own
    /// code. <paramref name="expr"/> and <paramref name="zone"/> are the schedule as CronWatch reads
    /// it, <paramref name="zone"/> <c>""</c> for the process's own. <paramref name="daily"/> is a cron
    /// that names no day or month, which meets every clock change of one kind alike, so one of each
    /// is walked. <paramref name="now"/> is the epoch milliseconds the horizon starts from.
    /// </summary>
    /// <exception cref="ScheduleException">When the two differ, or either cannot read the schedule.</exception>
    public static void CheckFires(FireTimes runs, string expr, string zone, string where, string scheduler, bool daily, long now)
    {
        ArgumentNullException.ThrowIfNull(runs);
        Checker.Check(runs, expr, zone, where, scheduler, daily, now);
    }

    /// <summary>
    /// The fire times of a scheduler that can only be asked for the next one (Quartz's
    /// <c>CronExpression</c>, Cronos's): the one at or before a time is found by asking from a
    /// window before it that grows from a second until it holds one, so a cron that fires every
    /// second walks a few fires and a yearly one a few steps, up to twelve years back.
    /// <paramref name="next"/> answers the first fire strictly after an instant, or null;
    /// <paramref name="scheduler"/> names it in the answer for a schedule that never fires.
    /// </summary>
    public static FireTimes Walking(Func<long, long?> next, string scheduler)
    {
        ArgumentNullException.ThrowIfNull(next);
        const long LongestBack = 12L * 366 * 86_400_000L;
        return (start, end) =>
        {
            var output = new List<long>();
            long at = start;
            for (long back = 1000; back <= LongestBack; back *= 8)
            {
                if (next(start - back - 1) is long found && found <= start)
                {
                    at = found;
                    while (next(at) is long following && following <= start)
                    {
                        at = following;
                    }
                    output.Add(at);
                    break;
                }
            }
            while (true)
            {
                if (next(at) is not long following)
                {
                    if (output.Count == 0)
                    {
                        throw ScheduleException.NeverFires(scheduler + " finds no fire time after " + Js.IsoOrWords(start));
                    }
                    return output;
                }
                output.Add(following);
                at = following;
                if ((end == null && output.Count > SampleRuns) || (end is long e && following > e))
                {
                    return output;
                }
            }
        };
    }

    /// <summary>
    /// Runs <paramref name="sync"/> (an integration's declarations,
    /// <see cref="Watch.SettleAsync"/>, and <see cref="Watch.UnscheduleAsync"/>) as a task of its
    /// own and waits at most <paramref name="limit"/> for it, so a store that hangs never holds the
    /// caller (a scheduler's thread) for good. A throw in it, or running past the limit (<c>the
    /// sync took longer than 30 seconds; gave up</c>), is reported to the client's error handler as
    /// <paramref name="where"/>. Says whether it finished without a throw.
    /// </summary>
    public static async Task<bool> SyncWithinAsync(CronwatchClient cw, TimeSpan limit, string where, Func<Task> sync)
    {
        ArgumentNullException.ThrowIfNull(cw);
        ArgumentNullException.ThrowIfNull(sync);
        Task work = CronwatchClient.WithoutFlow(() => Task.Run(sync));
        try
        {
            await work.WaitAsync(limit).ConfigureAwait(false);
            return true;
        }
        catch (TimeoutException)
        {
            cw.ReportError(new CronwatchException("the sync took longer than " + Js.FormatLong((long)limit.TotalSeconds) + " seconds; gave up"), where);
        }
        catch (Exception e)
        {
            cw.ReportError(e, where);
        }
        return false;
    }
}
