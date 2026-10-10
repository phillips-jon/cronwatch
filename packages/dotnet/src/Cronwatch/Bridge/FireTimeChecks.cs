using System;
using System.Collections.Generic;
using System.Threading;

namespace Cronwatch.Bridge;

/// <summary>
/// Each cron's check against its scheduler's own fire times (<see cref="SchedulerBridge.CheckFires"/>),
/// kept by the job, the expression, the zone, and the year, so an integration that reads its
/// scheduler every minute walks only what changed: a cron that fires each second in a zone with
/// daylight saving takes most of a second to walk. Only what the last read saw is kept. Safe to
/// use from many threads at once.
/// For integration authors, outside the 1.x promise: the bridge changes as the integrations need, in any minor release.
/// </summary>
public sealed class FireTimeChecks
{
    private readonly Lock _lock = new();
    private readonly Dictionary<string, Checked> _checked = new(StringComparer.Ordinal);
    private readonly HashSet<string> _seen = new(StringComparer.Ordinal);
    private int _walks;
    private int _reading;

    private sealed record Checked(string? Schedule, string? Problem);

    /// <summary>How many crons were walked, rather than answered from what was kept.</summary>
    public int Walks => Volatile.Read(ref _walks);

    /// <summary>
    /// The schedule to declare for a cron, or the problem to report: <paramref name="walk"/>'s
    /// answer (the schedule as CronWatch reads it, or a <see cref="ScheduleException"/>), kept by
    /// <paramref name="job"/>, <paramref name="expression"/>, <paramref name="zone"/>, and the UTC
    /// year of <paramref name="now"/>, so it is walked again only when one of them changes.
    /// </summary>
    public (string? Schedule, string? Problem) Check(string job, string expression, string zone, long now, Func<string> walk)
    {
        ArgumentNullException.ThrowIfNull(walk);
        long year = Internal.CronZones.WallAt(Internal.Js.FloorDiv(now, 1000), TimeZoneInfo.Utc)[0];
        string key = job + "\0" + expression + "\0" + zone + "\0" + Internal.Js.FormatLong(year);
        Checked? found;
        lock (_lock)
        {
            _seen.Add(key);
            _checked.TryGetValue(key, out found);
        }
        if (found == null)
        {
            Interlocked.Increment(ref _walks);
            try
            {
                found = new Checked(walk(), null);
            }
            catch (ScheduleException e)
            {
                found = new Checked(null, e.Message);
            }
            lock (_lock)
            {
                _checked[key] = found;
            }
        }
        return (found.Schedule, found.Problem);
    }

    /// <summary>
    /// Starts one read of the scheduler. Reads may overlap (a read loop and a check job, say):
    /// what is dropped waits until the last of them ends.
    /// </summary>
    public void BeginRead()
    {
        lock (_lock)
        {
            _reading++;
        }
    }

    /// <summary>
    /// Ends one read of the scheduler: once no read is left, what none of them asked about is
    /// dropped, so a cron changed or removed is not kept for good. Without a
    /// <see cref="BeginRead"/> it ends the read at once.
    /// </summary>
    public void EndRead()
    {
        lock (_lock)
        {
            if (_reading > 0)
            {
                _reading--;
            }
            if (_reading > 0)
            {
                return;
            }
            var drop = new List<string>();
            foreach (string key in _checked.Keys)
            {
                if (!_seen.Contains(key))
                {
                    drop.Add(key);
                }
            }
            foreach (string key in drop)
            {
                _checked.Remove(key);
            }
            _seen.Clear();
        }
    }

    /// <summary>Names how many crons are kept.</summary>
    public override string ToString()
    {
        lock (_lock)
        {
            return "FireTimeChecks(" + _checked.Count + " kept)";
        }
    }
}
