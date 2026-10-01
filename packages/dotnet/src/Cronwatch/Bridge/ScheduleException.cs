using System;

namespace Cronwatch.Bridge;

/// <summary>
/// A scheduler's schedule that cannot be read, or cannot be taken as CronWatch's exactly: the job
/// is watched without a schedule, and the message reported once.
/// For integration authors, outside the 1.x promise: the bridge changes as the integrations need, in any minor release.
/// </summary>
public sealed class ScheduleException : Exception
{
    /// <summary>A refusal with no message.</summary>
    public ScheduleException()
    {
    }

    /// <summary>A refusal with its message.</summary>
    public ScheduleException(string message)
        : base(message)
    {
    }

    /// <summary>A refusal with its message and what caused it.</summary>
    public ScheduleException(string message, Exception inner)
        : base(message, inner)
    {
    }

    private ScheduleException(string message, bool never)
        : base(message)
    {
        Never = never;
    }

    /// <summary>What a <see cref="FireTimes"/> answers for a schedule that never fires again.</summary>
    public static ScheduleException NeverFires(string why) => new(why, true);

    internal bool Never { get; }
}

/// <summary>
/// A scheduler's own fire times, from its own code, for <see cref="SchedulerBridge.CheckFires"/>:
/// given <paramref name="start"/> and <paramref name="end"/> in epoch milliseconds, the one at or
/// before <paramref name="start"/> and every one after it up to the first past
/// <paramref name="end"/>, or <see cref="SchedulerBridge.SampleRuns"/> of them after that first one
/// when <paramref name="end"/> is null, ascending. A schedule that never fires again throws
/// <see cref="ScheduleException.NeverFires"/>.
/// </summary>
/// <param name="start">Where the walk starts, epoch milliseconds.</param>
/// <param name="end">Where it may stop, or null for a sample.</param>
public delegate System.Collections.Generic.IReadOnlyList<long> FireTimes(long start, long? end);
