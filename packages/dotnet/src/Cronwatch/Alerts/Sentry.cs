using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using Cronwatch.Internal;

namespace Cronwatch.Alerts;

/// <summary>Configures <see cref="SentryChannel"/>. Its <see cref="ToString"/> never shows the DSN.</summary>
[DebuggerDisplay("{ToString(),nq}")]
public sealed class SentryOptions
{
    /// <summary>The project's DSN, <c>https://&lt;key&gt;@&lt;host&gt;/&lt;project&gt;</c>. Trimmed of the spaces and newlines a paste leaves.</summary>
    public string? Dsn { internal get; init; }

    /// <summary>The event's environment. Default <c>"production"</c>.</summary>
    public string Environment { get; init; } = "production";

    /// <summary>The event's release, or none.</summary>
    public string? Release { get; init; }

    /// <summary>Also send recoveries, as info events. Default true.</summary>
    public bool Recovered { get; init; } = true;

    /// <summary>A link back to the job in your dashboard. Null or <c>""</c> is no link.</summary>
    public Func<Alert, string?>? Link { get; init; }

    /// <summary>Sends this channel's requests; by default the client's transport.</summary>
    public ITransport? Transport { get; init; }

    /// <summary>Names what is set, never the DSN.</summary>
    public override string ToString() =>
        "SentryOptions(dsn " + ChannelShared.Set(Dsn) + ", environment " + Environment + ", recovered " + (Recovered ? "true" : "false") + ")";
}

/// <summary>
/// Sends alerts to Sentry as events through its envelope endpoint (<c>alerts/sentry.ts</c>), one
/// issue per job and alert type.
/// </summary>
public sealed class SentryChannel : IChannel
{
    private readonly string _endpoint;
    private readonly string _publicKey;
    private readonly string _environment;
    private readonly string _release;
    private readonly bool _recovered;
    private readonly Func<Alert, string?>? _link;
    private readonly ITransport? _transport;

    /// <summary>The channel.</summary>
    /// <exception cref="CronwatchException">Without a DSN, or with one that is not a Sentry DSN.</exception>
    public SentryChannel(SentryOptions options)
    {
        ArgumentNullException.ThrowIfNull(options);
        // A pasted credential often carries a stray space or newline, which a header would refuse.
        string dsn = ChannelShared.Trimmed(options.Dsn);
        if (dsn.Length == 0)
        {
            throw ChannelShared.Invalid("Sentry needs a Dsn");
        }
        (_endpoint, _publicKey) = ParseDsn(dsn);
        _environment = options.Environment ?? "production";
        _release = options.Release ?? "";
        _recovered = options.Recovered;
        _link = options.Link;
        _transport = options.Transport;
    }

    /// <summary>The envelope endpoint and the public key of a DSN.</summary>
    internal static (string Endpoint, string PublicKey) ParseDsn(string dsn)
    {
        var (kind, _, url) = WhatwgUrl.Parse(dsn);
        if (kind != UrlKind.Special || url == null)
        {
            throw ChannelShared.Invalid("Sentry needs a valid Dsn");
        }
        var segments = new List<string>();
        foreach (string seg in url.Path.Split('/'))
        {
            if (seg.Length > 0)
            {
                segments.Add(seg);
            }
        }
        string project = "";
        if (segments.Count > 0)
        {
            project = segments[^1];
            segments.RemoveAt(segments.Count - 1);
        }
        if (url.Username.Length == 0 || !IsDigits(project))
        {
            throw ChannelShared.Invalid("Sentry needs a Dsn like https://<key>@<host>/<project>");
        }
        string prefix = segments.Count == 0 ? "" : "/" + string.Join('/', segments);
        string host = url.Port < 0 ? url.Host : url.Host + ":" + url.Port.ToString(CultureInfo.InvariantCulture);
        string endpoint = url.Scheme + "://" + host + prefix + "/api/" + project + "/envelope/";
        return (endpoint, DecodeUriComponent(url.Username));
    }

    private static bool IsDigits(string s)
    {
        if (s.Length == 0)
        {
            return false;
        }
        foreach (char c in s)
        {
            if (c < '0' || c > '9')
            {
                return false;
            }
        }
        return true;
    }

    /// <summary><c>decodeURIComponent</c>, which refuses a bad escape or bytes that are not UTF-8.</summary>
    private static string DecodeUriComponent(string text)
    {
        byte[] input = Js.Utf8(text);
        var output = new List<byte>(input.Length);
        for (int i = 0; i < input.Length; i++)
        {
            if (input[i] == '%')
            {
                int h = i + 2 < input.Length ? WhatwgUrl.HexValue((char)input[i + 1]) : -1;
                int l = i + 2 < input.Length ? WhatwgUrl.HexValue((char)input[i + 2]) : -1;
                if (h < 0 || l < 0)
                {
                    throw ChannelShared.Invalid("Sentry needs a valid Dsn");
                }
                output.Add((byte)((h << 4) | l));
                i += 2;
            }
            else
            {
                output.Add(input[i]);
            }
        }
        try
        {
            return new UTF8Encoding(false, true).GetString(output.ToArray());
        }
        catch (DecoderFallbackException)
        {
            throw ChannelShared.Invalid("Sentry needs a valid Dsn");
        }
    }

    /// <inheritdoc/>
    public string Name => "sentry";

    /// <inheritdoc/>
    public Task SendAsync(Alert alert, ChannelContext context, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(alert);
        ArgumentNullException.ThrowIfNull(context);
        if (alert.Type == AlertType.Recovered && !_recovered)
        {
            return Task.CompletedTask;
        }
        string eventId = ChannelShared.AlertId(alert);
        string link = ChannelShared.Link(_link, alert);
        var extra = new JsObject();
        string triage = ChannelShared.Triage(alert);
        if (triage.Length > 0)
        {
            extra.Set("triage", triage);
        }
        if (link.Length > 0)
        {
            extra.Set("link", link);
        }
        extra.Set("details", alert.Details.ToValue()).Set("run", ChannelShared.RunSummary(alert));
        var e = new JsObject()
            .Set("event_id", eventId)
            .Set("timestamp", alert.At / 1000.0)
            .Set("platform", "other")
            .Set("level", ChannelShared.Severity(alert.Type))
            .Set("logger", "cronwatch")
            .Set("transaction", alert.Job)
            .Set("environment", _environment);
        if (_release.Length > 0)
        {
            e.Set("release", _release);
        }
        e
            // The first line is the issue title.
            .Set("logentry", new JsObject().Set("formatted", Post.Cut(alert.Title + "\n\n" + alert.Message, 8192)))
            .Set("fingerprint", new List<object?> { "cronwatch", alert.Job, alert.Type.Value })
            .Set("tags", new JsObject().Set("job", Post.Cut(alert.Job, 199)).Set("type", alert.Type.Value))
            .Set("extra", extra);
        string payload = e.ToJson();
        string envelope = new JsObject().Set("event_id", eventId).ToJson() + "\n"
            + new JsObject().Set("type", "event").Set("content_type", "application/json").Set("length", Js.Utf8(payload).Length).ToJson() + "\n"
            + payload + "\n";
        return ChannelShared.SendAsync(
            ChannelShared.Transport(_transport, context),
            "Sentry",
            _endpoint,
            ChannelShared.Headers(
                "content-type", "application/x-sentry-envelope",
                "x-sentry-auth", "Sentry sentry_version=7, sentry_key=" + _publicKey + ", sentry_client=cronwatch"),
            envelope,
            [_publicKey],
            cancellationToken);
    }

    /// <summary>Names the channel.</summary>
    public override string ToString() => "SentryChannel";
}
