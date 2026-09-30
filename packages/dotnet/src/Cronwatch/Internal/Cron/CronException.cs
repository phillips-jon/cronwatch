using System;

namespace Cronwatch.Internal;

/// <summary>What croner throws for an expression it will not read or walk: its message, word for word.</summary>
internal sealed class CronException : ArgumentException
{
    public CronException()
    {
    }

    public CronException(string message)
        : base(message)
    {
    }

    public CronException(string message, Exception inner)
        : base(message, inner)
    {
    }
}
