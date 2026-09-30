using System;
using System.Collections.Generic;
using Cronwatch.Internal;

namespace Cronwatch.Web;

/// <summary>
/// What an adapter needs to hand a server's request to <see cref="Routes.HandleAsync"/> or
/// <see cref="Handler.HandleAsync"/> as the SDK reads a fetch <c>Request</c>:
/// <c>Cronwatch.AspNetCore</c> uses it, and so can an adapter for a server this library has none
/// for.
/// </summary>
public static class WebAdapters
{
    /// <summary>
    /// The request target as sent, from the text a server read: a server that reads the request
    /// line a byte a character hands a target sent as UTF-8 back as that UTF-8 (and one that is not
    /// is left as it is).
    /// </summary>
    public static string Target(string rawTarget)
    {
        ArgumentNullException.ThrowIfNull(rawTarget);
        return WebText.Utf8OrAsIs(rawTarget);
    }

    /// <summary>
    /// A form body written back from a server's parsed form, for a body something ahead of the
    /// dashboard already read: every field in order, written as <c>URLSearchParams</c> writes a
    /// form.
    /// </summary>
    public static byte[] FormBody(IEnumerable<KeyValuePair<string, string>> fields)
    {
        ArgumentNullException.ThrowIfNull(fields);
        var pairs = new List<string>();
        foreach (var f in fields)
        {
            pairs.Add(Requests.FormEncode(f.Key) + "=" + Requests.FormEncode(f.Value));
        }
        return Js.Utf8(string.Join('&', pairs));
    }
}
