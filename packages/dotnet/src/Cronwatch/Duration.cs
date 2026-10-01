using System;
using System.Globalization;
using Cronwatch.Internal;

namespace Cronwatch;

/// <summary>
/// A duration as the SDK takes one: its text (<c>"15m"</c>, <c>"1h30m"</c>), a
/// <see cref="TimeSpan"/>, or plain milliseconds, each converted implicitly, so a property takes
/// all three. Text is stored as written and everything else as its milliseconds. Text longer than
/// 64 characters is refused before it is read.
/// </summary>
public readonly struct Duration : IEquatable<Duration>
{
    private readonly string? _text;
    private readonly double _ms;

    private Duration(string? text, double ms)
    {
        _text = text;
        _ms = ms;
    }

    /// <summary>The SDK's text.</summary>
    public static implicit operator Duration(string text) => new(text ?? throw new ArgumentNullException(nameof(text)), 0);

    /// <summary>A <see cref="TimeSpan"/>, as its milliseconds (a fraction kept).</summary>
    public static implicit operator Duration(TimeSpan span) => new(null, span.Ticks / (double)TimeSpan.TicksPerMillisecond);

    /// <summary>Milliseconds.</summary>
    public static implicit operator Duration(double milliseconds) => new(null, milliseconds);

    /// <summary>A duration of this many milliseconds.</summary>
    public static Duration FromMilliseconds(double milliseconds) => new(null, milliseconds);

    /// <summary>The text as given, or null for a number of milliseconds.</summary>
    public string? Text => _text;

    /// <summary>The value as stored in a definition: the text, or the milliseconds.</summary>
    internal object JsonValue => _text ?? (object)_ms;

    /// <summary>
    /// The milliseconds, read as the SDK reads a duration, so a value can be checked before it is
    /// used (a host checks its check interval as it starts). <paramref name="name"/> names the value
    /// in the error.
    /// </summary>
    /// <exception cref="CronwatchException">Of kind <see cref="CronwatchErrorKind.Invalid"/>, with the SDK's message.</exception>
    public double ToMilliseconds(string name = "duration") => Milliseconds(name ?? "duration");

    /// <summary>The milliseconds, read as the SDK reads the option <paramref name="label"/>.</summary>
    /// <exception cref="CronwatchException">Of kind <see cref="CronwatchErrorKind.Invalid"/>, with the SDK's message.</exception>
    internal double Milliseconds(string label)
    {
        try
        {
            return _text != null ? Durations.Parse(_text, label) : Durations.Parse(_ms, label);
        }
        catch (ArgumentException e)
        {
            throw CronwatchException.Invalid(e.Message);
        }
    }

    /// <inheritdoc/>
    public bool Equals(Duration other) => string.Equals(_text, other._text, StringComparison.Ordinal) && _ms.Equals(other._ms);

    /// <inheritdoc/>
    public override bool Equals(object? obj) => obj is Duration d && Equals(d);

    /// <inheritdoc/>
    public override int GetHashCode() => HashCode.Combine(_text, _ms);

    /// <summary>The text, or the milliseconds followed by <c>ms</c>.</summary>
    public override string ToString() => _text ?? Js.FormatNumber(_ms) + "ms";

    /// <summary>Whether two durations were given the same way.</summary>
    public static bool operator ==(Duration left, Duration right) => left.Equals(right);

    /// <summary>Whether two durations were given differently.</summary>
    public static bool operator !=(Duration left, Duration right) => !left.Equals(right);

    internal static string Describe(double ms) => ms.ToString(CultureInfo.InvariantCulture);
}
