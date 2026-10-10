using System;
using System.Collections.Generic;
using System.Security.Cryptography;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using Cronwatch.Alerts;

namespace Cronwatch.Internal;

/// <summary>
/// What the channels share (<c>alerts/shared.ts</c>): severity, the stable alert id, the run
/// summary trackers attach, the plain text every channel reads, the encodings the requests use,
/// and the POST through the channel's transport or the client's.
/// </summary>
internal static class ChannelShared
{
    /// <summary>The level for trackers that have levels. Recovered is informational.</summary>
    public static string Severity(AlertType type)
    {
        if (type == AlertType.Recovered)
        {
            return "info";
        }
        return type == AlertType.Slow || type == AlertType.OverBudget || type == AlertType.UnderFloor ? "warning" : "error";
    }

    /// <summary>Lowercase hex.</summary>
    public static string Hex(ReadOnlySpan<byte> bytes) => Convert.ToHexStringLower(bytes);

    /// <summary>SHA-256 of the text's UTF-8, as lowercase hex.</summary>
    public static string Sha256Hex(string text) => Hex(SHA256.HashData(Js.Utf8(text)));

    /// <summary>HMAC-SHA256 of the text's UTF-8 with the key.</summary>
    public static byte[] HmacSha256(byte[] key, string data) => HMACSHA256.HashData(key, Js.Utf8(data));

    /// <summary>
    /// A stable 32 hex character id for one alert: the same job, type, and time always give the
    /// same id, so a provider that deduplicates on it drops a resend of an alert it already took.
    /// </summary>
    public static string AlertId(Alert a) => Sha256Hex(a.Job + "\n" + a.Type.Value + "\n" + Js.FormatLong(a.At))[..32];

    /// <summary>The same id laid out as a UUID, for APIs that ask for one.</summary>
    public static string AsUuid(string id) => id[..8] + "-" + id[8..12] + "-" + id[12..16] + "-" + id[16..20] + "-" + id[20..32];

    /// <summary>The run fields worth attaching to a tracker event, or null. A start before the year 1 or after 9999 is null.</summary>
    public static JsObject? RunSummary(Alert a)
    {
        Run? r = a.Run;
        if (r == null)
        {
            return null;
        }
        return new JsObject()
            .Set("id", r.Id)
            .Set("status", r.Status.Value)
            .Set("startedAt", Js.IsoTime(r.StartedAt))
            .Set("durationMs", r.DurationMs)
            .Set("trigger", r.Trigger);
    }

    /// <summary>The largest time a JavaScript <c>Date</c> holds, either side of 1970.</summary>
    private const long MaxDateMs = 8_640_000_000_000_000L;

    /// <summary>
    /// <c>new Date(ms).toISOString()</c>, which throws past what a <c>Date</c> holds, as it throws
    /// in JavaScript (so the send fails, as the SDK's does).
    /// </summary>
    public static string IsoString(long ms)
    {
        if (ms > MaxDateMs || ms < -MaxDateMs)
        {
            throw new CronwatchException("Invalid time value");
        }
        return Js.IsoString(ms);
    }

    /// <summary>The alert's diagnosis, <c>""</c> for none (JavaScript reads null and "" alike as absent).</summary>
    public static string Triage(Alert a) => a.Triage ?? "";

    /// <summary>The link option's answer for this alert, <c>""</c> for none.</summary>
    public static string Link(Func<Alert, string?>? link, Alert a) => link == null ? "" : link(a) ?? "";

    /// <summary>The title, message, triage, and link as one plain text block, the way every channel reads.</summary>
    public static string PlainText(Alert a, string link)
    {
        var lines = new List<string> { a.Title, "", a.Message };
        if (Triage(a).Length > 0)
        {
            lines.Add("");
            lines.Add("Triage: " + Triage(a));
        }
        if (link.Length > 0)
        {
            lines.Add("");
            lines.Add("Open: " + link);
        }
        return string.Join('\n', lines);
    }

    /// <summary>A credential with the spaces and newlines a paste leaves around it taken off; null is empty.</summary>
    public static string Trimmed(string? value) => value == null ? "" : Js.Trim(value);

    /// <summary><c>Basic</c> authorization of a user and password, as UTF-8.</summary>
    public static string BasicAuth(string user, string password) => "Basic " + Convert.ToBase64String(Js.Utf8(user + ":" + password));

    /// <summary>JavaScript's <c>encodeURIComponent</c>.</summary>
    public static string EncodeUriComponent(string text) => Percent(text, "-_.!~*'()", false);

    /// <summary><c>URLSearchParams#toString</c> for these pairs: a space as <c>+</c>.</summary>
    public static string Form(IEnumerable<KeyValuePair<string, string>> pairs)
    {
        var output = new List<string>();
        foreach (var p in pairs)
        {
            output.Add(Percent(p.Key, "*-._", true) + "=" + Percent(p.Value, "*-._", true));
        }
        return string.Join('&', output);
    }

    private const string HexDigits = "0123456789ABCDEF";

    /// <summary>The text's UTF-8 with each byte but ASCII letters, digits, and <paramref name="safe"/> as <c>%XX</c>.</summary>
    public static string Percent(string text, string safe, bool plus)
    {
        var b = new StringBuilder(text.Length);
        foreach (byte c in Js.Utf8(text))
        {
            if ((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || safe.Contains((char)c, StringComparison.Ordinal))
            {
                b.Append((char)c);
            }
            else if (c == ' ' && plus)
            {
                b.Append('+');
            }
            else
            {
                b.Append('%').Append(HexDigits[c >> 4]).Append(HexDigits[c & 15]);
            }
        }
        return b.ToString();
    }

    /// <summary>The channel's own transport, else the client's.</summary>
    public static ITransport Transport(ITransport? own, ChannelContext context) => own ?? context.Transport;

    /// <summary>Headers in the order given, as name and value pairs.</summary>
    public static List<KeyValuePair<string, string>> Headers(params string[] pairs)
    {
        var output = new List<KeyValuePair<string, string>>(pairs.Length / 2);
        for (int i = 0; i + 1 < pairs.Length; i += 2)
        {
            output.Add(new(pairs[i], pairs[i + 1]));
        }
        return output;
    }

    /// <summary>Posts a body and fails on an answer outside 2xx, the secrets cut out of a quoted answer.</summary>
    public static Task SendAsync(
        ITransport transport,
        string provider,
        string url,
        IEnumerable<KeyValuePair<string, string>> headers,
        string body,
        IEnumerable<string?> secrets,
        CancellationToken cancellationToken) =>
        Post.SendAsync(transport, provider, url, headers, body, secrets, cancellationToken);

    /// <summary>A refusal of a channel's options, which never quotes their values.</summary>
    public static CronwatchException Invalid(string message) => CronwatchException.Invalid(message);

    /// <summary>A secret's presence, for a <c>ToString</c> that never shows its value.</summary>
    public static string Set(string? value) => string.IsNullOrEmpty(value) ? "unset" : "set";
}
