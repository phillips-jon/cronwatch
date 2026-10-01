using Cronwatch.Internal;

namespace Cronwatch;

/// <summary>
/// An alert in <see cref="JobState.Sending"/>, the outbox: the SDK's <c>SendingAlert</c>. It was
/// written with the state that opened its condition, while the process that wrote it sends it;
/// <see cref="Until"/> is when that process's lease runs out.
/// </summary>
public sealed record SendingAlert
{
    /// <summary>
    /// When the sender's lease runs out, in epoch milliseconds; null when the stored value is not
    /// a number, which counts as run out.
    /// </summary>
    public long? Until { get; init; }

    /// <summary>The alert, never with triage; null when the stored entry holds no alert.</summary>
    public Alert? Alert { get; init; }

    /// <summary>The entry as the SDK's JSON object, <c>until</c> then <c>alert</c>, each only when present.</summary>
    public JsObject ToValue()
    {
        var o = new JsObject();
        if (Until != null)
        {
            o.Set("until", Until.Value);
        }
        if (Alert != null)
        {
            o.Set("alert", Alert.ToValue());
        }
        return o;
    }

    /// <summary>
    /// An entry read leniently, as the SDK's <c>releaseSending</c> treats one: an <c>until</c>
    /// that is not a number reads as null, and an <c>alert</c> that is not one as null, so a
    /// malformed entry never makes the state unreadable.
    /// </summary>
    public static SendingAlert FromValue(object? v)
    {
        if (v is not JsObject o)
        {
            return new SendingAlert();
        }
        long? until = null;
        if (JsonText.TryNumber(o.Get("until"), out double d))
        {
            // A whole millisecond, rounded up, so a fractional end is past the same instants.
            until = Js.ToLong(System.Math.Ceiling(d));
        }
        Alert? alert = null;
        if (o.Get("alert") is JsObject a)
        {
            try
            {
                alert = Cronwatch.Alert.FromValue(a);
            }
            catch (JsonParseException)
            {
                // Not an alert: it could never be delivered.
            }
        }
        return new SendingAlert { Until = until, Alert = alert };
    }
}
