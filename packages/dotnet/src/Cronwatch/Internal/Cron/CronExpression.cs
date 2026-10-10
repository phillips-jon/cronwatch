using System;
using System.Collections.Generic;

namespace Cronwatch.Internal;

/// <summary>
/// A port of croner 10, the cron library the SDK uses: its reading of an expression
/// (<see cref="CronPattern"/>, with its checks and its messages word for word) and its walk to the
/// next matching time (<see cref="CronDate"/>), habits included: a day the month does not have
/// rolls over, a wall-clock time in a spring-forward gap moves forward by the gap, and a time that
/// happens twice is the earlier one. The names and the order of every step follow croner's
/// source, as the Go, Python, PHP, Rust, Elixir, and Java ports do, so they agree on every
/// expression they read, every one they refuse, and every fire time.
/// </summary>
/// <remarks>
/// As the SDK settles the two schedules croner itself does not: a date no month has
/// (<c>0 0 30 2 *</c>), which makes croner run out of stack, is an expression that never fires;
/// and a string with a colon after its first character, which croner reads as a one-time date, is
/// refused: one that looks like an ISO date with "CronPattern: a one-time date is not supported",
/// anything else with the message croner gives for text <c>Date.parse</c> cannot read, "Invalid
/// ISO8601 passed to timezone parser.". An expression
/// schedules nothing and only answers <see cref="NextRuns"/>; safe to share between threads.
/// </remarks>
internal sealed class CronExpression
{
    /// <summary>The instants a JavaScript Date holds, in milliseconds either side of the epoch.</summary>
    private const long DateRange = 8_640_000_000_000_000L;

    private readonly CronPattern _pattern;

    private CronExpression(CronPattern pattern, TimeZoneInfo zone)
    {
        _pattern = pattern;
        Zone = zone;
    }

    /// <summary>The zone the expression is walked in.</summary>
    public TimeZoneInfo Zone { get; }

    /// <summary>Reads an expression, to be walked in <paramref name="zone"/>.</summary>
    /// <exception cref="CronException">With croner's message when it is not one.</exception>
    public static CronExpression Parse(string text, TimeZoneInfo zone)
    {
        if (text.Length > 1 && text.IndexOf(':', 1) >= 0)
        {
            // Croner reads a string with a colon after its first character as a one-time date to
            // fire at, not as a cron expression.
            if (IsIsoDate(text))
            {
                throw new CronException("CronPattern: a one-time date is not supported");
            }
            throw new CronException("Invalid ISO8601 passed to timezone parser.");
        }
        return new CronExpression(new CronPattern(text), zone);
    }

    /// <summary><c>/^\d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2}/</c>, the start of an ISO date and time.</summary>
    private static bool IsIsoDate(string t)
    {
        if (t.Length < 16)
        {
            return false;
        }
        return Digits(t, 0, 4) && t[4] == '-' && Digits(t, 5, 7) && t[7] == '-' && Digits(t, 8, 10)
            && (t[10] == 'T' || t[10] == ' ') && Digits(t, 11, 13) && t[13] == ':' && Digits(t, 14, 16);
    }

    private static bool Digits(string t, int from, int to)
    {
        for (int i = from; i < to; i++)
        {
            if (t[i] < '0' || t[i] > '9')
            {
                return false;
            }
        }
        return true;
    }

    /// <summary>
    /// Croner's <c>nextRuns</c>: up to <paramref name="count"/> fires after
    /// <paramref name="start"/> (epoch ms), each found from the one before. Fewer when the
    /// expression stops firing.
    /// </summary>
    public List<long> NextRuns(int count, long start)
    {
        var runs = new List<long>(Math.Max(0, count));
        // Croner is only ever given a time a JavaScript Date holds. A start outside that (a
        // foreign row's time near long.MinValue, say) has no fire after it.
        if (start < -DateRange || start > DateRange)
        {
            return runs;
        }
        CronDate d = CronDate.FromMs(start, Zone);
        try
        {
            for (int i = 0; i < count; i++)
            {
                if (!d.Increment(_pattern))
                {
                    break;
                }
                runs.Add(d.TimeMs(Zone));
            }
        }
        catch (CronException)
        {
            // Croner throws from the walk for a day-of-week bit it does not know; no fire is found.
            return runs;
        }
        return runs;
    }
}
