namespace Cronwatch.Internal;

/// <summary>Reading fields of a stored JSON object as the SDK reads them, leniently.</summary>
internal static class Values
{
    /// <summary>A string field, or "".</summary>
    public static string String(JsObject o, string key) => o.Get(key) as string ?? "";

    /// <summary>A string field, or null.</summary>
    public static string? NullableString(JsObject o, string key) => o.Get(key) as string;

    /// <summary>A number field as a <c>long</c> (truncated, held at the ends), or 0.</summary>
    public static long Integer(JsObject o, string key) => JsonText.TryNumber(o.Get(key), out double d) ? Js.ToLong(d) : 0;

    /// <summary>A number field as a <c>long</c>, or null when it is not a number.</summary>
    public static long? NullableInteger(JsObject o, string key) => JsonText.TryNumber(o.Get(key), out double d) ? Js.ToLong(d) : null;

    /// <summary>A number field, or NaN.</summary>
    public static double Number(JsObject o, string key) => JsonText.TryNumber(o.Get(key), out double d) ? d : double.NaN;

    /// <summary>
    /// The keys of <paramref name="o"/> this port does not know, as JSON in their order, or null
    /// when there are none: kept as text so a record holding them stays equal by value.
    /// </summary>
    public static string? Unknown(JsObject o, params string[] known)
    {
        JsObject? extra = null;
        foreach (var e in o)
        {
            if (System.Array.IndexOf(known, e.Key) < 0)
            {
                (extra ??= new JsObject()).Set(e.Key, JsonText.Copy(e.Value));
            }
        }
        return extra?.ToJson();
    }

    /// <summary>
    /// <paramref name="target"/> with the keys <see cref="Unknown"/> kept added after its own, a
    /// key it already has left as it is.
    /// </summary>
    public static JsObject WithUnknown(JsObject target, string? unknown)
    {
        if (unknown != null)
        {
            foreach (var e in Json.ParseObject(unknown))
            {
                if (!target.Has(e.Key))
                {
                    target.Set(e.Key, e.Value);
                }
            }
        }
        return target;
    }
}
