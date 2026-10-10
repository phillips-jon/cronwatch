namespace Cronwatch.Internal;

/// <summary>
/// The JSON helpers beyond parse and stringify, for the port's own code: what <c>Json</c>'s
/// <c>Quote</c>, <c>Kind</c>, <c>Copy</c>, <c>TryNumber</c>, and <c>MaxDepth</c> were until 0.11
/// deprecated them.
/// </summary>
internal static class JsonText
{
    /// <summary>
    /// How deep arrays and objects may nest. The reader and writer recurse, so text nested
    /// thousands deep (a request body, a stored row) would overflow a thread's stack; nothing
    /// CronWatch or an app stores comes near this.
    /// </summary>
    public const int MaxDepth = 256;

    /// <summary><c>JSON.stringify</c> of a string.</summary>
    public static string Quote(string s) => Json.QuoteString(s);

    /// <summary>A value's type as JavaScript's <c>typeof</c> names it, for messages.</summary>
    public static string Kind(object? v) => Json.KindOf(v);

    /// <summary>A deep copy of a JSON value: nested objects and lists are copied, the rest is immutable.</summary>
    public static object? Copy(object? value) => JsObject.CopyValue(value);

    /// <summary>Whether a value is a JSON number, and which.</summary>
    public static bool TryNumber(object? v, out double n) => Json.TryNumberOf(v, out n);
}
