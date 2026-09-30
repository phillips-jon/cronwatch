using System;
using System.Collections.Generic;
using Cronos;
using Cronwatch.Bridge;

namespace Cronwatch.Hangfire;

/// <summary>
/// A Hangfire cron as CronWatch reads it: Hangfire parses with Cronos (five fields, or six with
/// seconds first, and macros such as <c>@daily</c>), which CronWatch's croner reads the same but
/// for a <c>?</c>, which croner takes as a day field naming every day, and the macros croner lacks.
/// Each cron is declared as written with those rewritten, and checked against Cronos's own fire
/// times before it is.
/// </summary>
internal static class HangfireCrons
{
    private const string Scheduler = "Hangfire";

    private static readonly char[] Separators = [' ', '\t'];

    /// <summary>
    /// The zone Hangfire reads a recurring job's cron in, as an IANA name with its
    /// <see cref="TimeZoneInfo"/>: Hangfire's own default of UTC when it has none, a Windows id
    /// converted, or nulls when the system knows no such zone.
    /// </summary>
    public static (string? Zone, TimeZoneInfo? Info) Zone(string? id)
    {
        string name = string.IsNullOrWhiteSpace(id) ? "UTC" : id.Trim();
        if (!string.Equals(name, "UTC", StringComparison.Ordinal) && TimeZoneInfo.TryConvertWindowsIdToIanaId(name, out string? iana))
        {
            name = iana;
        }
        try
        {
            return (name, TimeZoneInfo.FindSystemTimeZoneById(name));
        }
        catch (Exception e) when (e is TimeZoneNotFoundException or InvalidTimeZoneException)
        {
            return (null, null);
        }
    }

    /// <summary>
    /// The cron CronWatch declares for <paramref name="cron"/> in <paramref name="zone"/>, checked
    /// against Cronos's fire times.
    /// </summary>
    /// <exception cref="ScheduleException">When the two read it differently, or either cannot read it.</exception>
    public static string Convert(string label, string cron, string zone, TimeZoneInfo info, long now)
    {
        string text = cron.Trim();
        CronExpression cronos;
        try
        {
            cronos = Parse(text);
        }
        catch (CronFormatException e)
        {
            throw new ScheduleException("cronwatch: " + label + " is " + Json.Quote(cron) + ", which Hangfire cannot read: " + e.Message);
        }
        string expr;
        bool daily;
        if (text.StartsWith('@'))
        {
            (expr, daily) = text.ToUpperInvariant() switch
            {
                "@EVERY_SECOND" => ("* * * * * *", true),
                "@EVERY_MINUTE" => ("* * * * *", true),
                "@HOURLY" => ("@hourly", true),
                "@DAILY" or "@MIDNIGHT" => ("@daily", true),
                "@WEEKLY" => ("@weekly", false),
                "@MONTHLY" => ("@monthly", false),
                _ => ("@yearly", false),
            };
        }
        else
        {
            string[] fields = text.Split(Separators, StringSplitOptions.RemoveEmptyEntries);
            var kept = new List<string>(fields.Length);
            foreach (string f in fields)
            {
                // Cronos reads ? as *; croner reads a ? as a day field naming every day, so that a
                // day of the month and ? would be every day. Declared as *, which croner reads as
                // Cronos does.
                kept.Add(f == "?" ? "*" : f);
            }
            expr = string.Join(' ', kept);
            int day = fields.Length == 6 ? 3 : 2;
            daily = IsAny(fields[day]) && IsAny(fields[day + 1]) && IsAny(fields[day + 2]);
        }
        SchedulerBridge.CheckFires(
            SchedulerBridge.Walking(at => Next(cronos, info, at), Scheduler),
            expr,
            zone,
            "cronwatch: " + label,
            Scheduler,
            daily,
            now);
        return expr;
    }

    private static bool IsAny(string field) => field is "*" or "?";

    /// <summary>Hangfire's own reading (<c>RecurringJobEntity.ParseCronExpression</c>): six fields include seconds.</summary>
    private static CronExpression Parse(string cron)
    {
        CronFormat format = CronFormat.Standard;
        if (!cron.StartsWith('@'))
        {
            int parts = cron.Split(Separators, StringSplitOptions.RemoveEmptyEntries).Length;
            if (parts == 6)
            {
                format |= CronFormat.IncludeSeconds;
            }
            else if (parts != 5)
            {
                throw new CronFormatException("Wrong number of parts in the `" + cron + "` cron expression, you can only use 5 or 6 (with seconds) part-based expressions.");
            }
        }
        return CronExpression.Parse(cron, format);
    }

    private static long? Next(CronExpression cron, TimeZoneInfo zone, long at)
    {
        DateTimeOffset from;
        try
        {
            from = DateTimeOffset.FromUnixTimeMilliseconds(at);
        }
        catch (ArgumentOutOfRangeException)
        {
            return null;
        }
        return cron.GetNextOccurrence(from, zone)?.ToUnixTimeMilliseconds();
    }
}
