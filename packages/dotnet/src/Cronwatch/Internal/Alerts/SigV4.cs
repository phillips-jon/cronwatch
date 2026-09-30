using System;
using System.Collections.Generic;
using System.Globalization;
using System.Linq;
using System.Text;

namespace Cronwatch.Internal;

/// <summary>
/// AWS Signature Version 4, for the SES channel (<c>alerts/sigv4.ts</c>), with .NET's HMAC and
/// SHA-256, so no AWS SDK is needed.
/// </summary>
internal static class SigV4
{
    /// <summary>
    /// The headers to send: the given ones (names lowercased), then <c>x-amz-date</c>, the session
    /// token when there is one, and <c>authorization</c>. <c>host</c> is signed but not returned,
    /// since the transport sets it.
    /// </summary>
    public static List<KeyValuePair<string, string>> Sign(
        string method,
        string url,
        IEnumerable<KeyValuePair<string, string>> given,
        string body,
        string region,
        string service,
        long now,
        string accessKeyId,
        string secretAccessKey,
        string? sessionToken)
    {
        var (kind, _, u) = WhatwgUrl.Parse(url);
        if (kind != UrlKind.Special || u == null)
        {
            throw new CronwatchException("Invalid URL");
        }
        string iso = ChannelShared.IsoString(now);
        // "2026-01-05T09:30:00.000Z" to "20260105T093000Z".
        string amzDate = iso.Replace("-", "", StringComparison.Ordinal).Replace(":", "", StringComparison.Ordinal);
        int dot = amzDate.IndexOf('.', StringComparison.Ordinal);
        if (dot >= 0 && dot + 4 <= amzDate.Length)
        {
            amzDate = amzDate[..dot] + amzDate[(dot + 4)..];
        }
        string day = amzDate[..8];
        // A JavaScript object: a name given again keeps its first place.
        var headers = new JsObject();
        foreach (var h in given)
        {
            headers.Set(WhatwgUrl.AsciiLower(h.Key), h.Value);
        }
        headers.Set("x-amz-date", amzDate);
        if (!string.IsNullOrEmpty(sessionToken))
        {
            headers.Set("x-amz-security-token", sessionToken);
        }
        JsObject signed = headers.Copy();
        signed.Set("host", u.Port < 0 ? u.Host : u.Host + ":" + u.Port.ToString(CultureInfo.InvariantCulture));
        var names = signed.Keys.OrderBy(n => n, StringComparer.Ordinal).ToList();
        var canonicalHeaders = new StringBuilder();
        foreach (string n in names)
        {
            canonicalHeaders.Append(n).Append(':').Append(Collapse(Js.Trim(Convert.ToString(signed.Get(n), CultureInfo.InvariantCulture) ?? ""))).Append('\n');
        }
        string signedHeaders = string.Join(';', names);
        string canonicalRequest = string.Join(
            '\n',
            method.ToUpperInvariant(),
            CanonicalUri(u.Path),
            CanonicalQuery(u.Query),
            canonicalHeaders.ToString(),
            signedHeaders,
            ChannelShared.Sha256Hex(body));
        string scope = day + "/" + region + "/" + service + "/aws4_request";
        string stringToSign = string.Join('\n', "AWS4-HMAC-SHA256", amzDate, scope, ChannelShared.Sha256Hex(canonicalRequest));
        byte[] key = ChannelShared.HmacSha256(Js.Utf8("AWS4" + secretAccessKey), day);
        key = ChannelShared.HmacSha256(key, region);
        key = ChannelShared.HmacSha256(key, service);
        key = ChannelShared.HmacSha256(key, "aws4_request");
        string signature = ChannelShared.Hex(ChannelShared.HmacSha256(key, stringToSign));
        headers.Set(
            "authorization",
            "AWS4-HMAC-SHA256 Credential=" + accessKeyId + "/" + scope + ", SignedHeaders=" + signedHeaders + ", Signature=" + signature);
        var output = new List<KeyValuePair<string, string>>();
        foreach (var e in headers)
        {
            output.Add(new(e.Key, Convert.ToString(e.Value, CultureInfo.InvariantCulture) ?? ""));
        }
        return output;
    }

    /// <summary><c>.replace(/\s+/g, " ")</c>, JavaScript's whitespace.</summary>
    private static string Collapse(string text)
    {
        var b = new StringBuilder(text.Length);
        bool space = false;
        foreach (char c in text)
        {
            if (Js.IsSpace(c))
            {
                if (!space)
                {
                    b.Append(' ');
                }
                space = true;
            }
            else
            {
                b.Append(c);
                space = false;
            }
        }
        return b.ToString();
    }

    /// <summary>RFC 3986 encoding of every byte but the unreserved characters.</summary>
    private static string UriEncode(string text) => ChannelShared.Percent(text, "-_.~", false);

    private static string CanonicalUri(string path)
    {
        if (path.Length == 0)
        {
            return "/";
        }
        // The path is already encoded once; every AWS service but S3 expects each segment encoded
        // again.
        return string.Join('/', path.Split('/').Select(UriEncode));
    }

    /// <summary>The query as <c>URLSearchParams</c> reads it, each part encoded again and sorted.</summary>
    private static string CanonicalQuery(string? query)
    {
        if (string.IsNullOrEmpty(query))
        {
            return "";
        }
        var pairs = new List<(string Name, string Value)>();
        foreach (string part in query.Split('&'))
        {
            if (part.Length == 0)
            {
                continue;
            }
            int eq = part.IndexOf('=', StringComparison.Ordinal);
            string name = eq < 0 ? part : part[..eq];
            string value = eq < 0 ? "" : part[(eq + 1)..];
            pairs.Add((UriEncode(FormDecode(name)), UriEncode(FormDecode(value))));
        }
        pairs.Sort((a, b) =>
        {
            int c = string.CompareOrdinal(a.Name, b.Name);
            return c != 0 ? c : string.CompareOrdinal(a.Value, b.Value);
        });
        return string.Join('&', pairs.Select(p => p.Name + "=" + p.Value));
    }

    /// <summary>A form's <c>+</c> as a space and <c>%XX</c> decoded, U+FFFD for bytes that are not UTF-8.</summary>
    private static string FormDecode(string text) => Encoding.UTF8.GetString(WhatwgUrl.PercentDecodeBytes(text.Replace('+', ' ')));
}
