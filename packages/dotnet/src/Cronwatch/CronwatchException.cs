using System;

namespace Cronwatch;

/// <summary>What kind of failure a <see cref="CronwatchException"/> is.</summary>
public enum CronwatchErrorKind
{
    /// <summary>Something the SDK refuses: a bad option, schedule, zone, or argument, with the SDK's message.</summary>
    Invalid,

    /// <summary>The store failed; its own exception is the <see cref="Exception.InnerException"/>.</summary>
    Store,

    /// <summary>Anything else.</summary>
    Other,
}

/// <summary>A failure of CronWatch's own, with a <see cref="Kind"/>.</summary>
public sealed class CronwatchException : Exception
{
    /// <summary>An error of kind <see cref="CronwatchErrorKind.Other"/>.</summary>
    public CronwatchException()
    {
    }

    /// <summary>An error of kind <see cref="CronwatchErrorKind.Other"/> with this message.</summary>
    public CronwatchException(string message)
        : base(message)
    {
    }

    /// <summary>An error of kind <see cref="CronwatchErrorKind.Other"/> with this message and cause.</summary>
    public CronwatchException(string message, Exception innerException)
        : base(message, innerException)
    {
    }

    /// <summary>An error of this kind, message, and cause.</summary>
    public CronwatchException(CronwatchErrorKind kind, string message, Exception? innerException = null)
        : base(message, innerException)
    {
        Kind = kind;
    }

    /// <summary>What kind of failure it is.</summary>
    public CronwatchErrorKind Kind { get; } = CronwatchErrorKind.Other;

    /// <summary>Something the SDK refuses, with its message.</summary>
    internal static CronwatchException Invalid(string message) => new(CronwatchErrorKind.Invalid, message);

    /// <summary>The store's failure.</summary>
    internal static CronwatchException Store(Exception inner) =>
        new(CronwatchErrorKind.Store, inner.GetType().Name + ": " + inner.Message, inner);
}
