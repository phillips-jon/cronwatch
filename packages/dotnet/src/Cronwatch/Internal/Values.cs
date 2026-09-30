namespace Cronwatch.Internal;

/// <summary>Reading fields of a stored JSON object as the SDK reads them, leniently.</summary>
internal static class Values
{
    /// <summary>A string field, or "".</summary>
    public static string String(JsObject o, string key) => o.Get(key) as string ?? "";

    /// <summary>A string field, or null.</summary>
    public static string? NullableString(JsObject o, string key) => o.Get(key) as string;

    /// <summary>A number field as a <c>long</c> (truncated, held at the ends), or 0.</summary>
    public static long Integer(JsObject o, string key) => Json.TryNumber(o.Get(key), out double d) ? Js.ToLong(d) : 0;

    /// <summary>A number field as a <c>long</c>, or null when it is not a number.</summary>
    public static long? NullableInteger(JsObject o, string key) => Json.TryNumber(o.Get(key), out double d) ? Js.ToLong(d) : null;

    /// <summary>A number field, or NaN.</summary>
    public static double Number(JsObject o, string key) => Json.TryNumber(o.Get(key), out double d) ? d : double.NaN;
}
