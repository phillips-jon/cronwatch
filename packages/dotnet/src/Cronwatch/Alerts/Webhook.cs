using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;
using Cronwatch.Internal;

namespace Cronwatch.Alerts;

/// <summary>Configures <see cref="WebhookChannel"/>. Its <see cref="ToString"/> never shows the URL, a header's value or the secret.</summary>
[DebuggerDisplay("{ToString(),nq}")]
public sealed class WebhookOptions
{
    /// <summary>
    /// Where each alert is posted. Errors name only its origin, since a webhook URL's path or
    /// query is often the credential.
    /// </summary>
    public string? Url { internal get; init; }

    /// <summary>
    /// Extra request headers, an <c>authorization</c> header say, as name and value pairs sent in
    /// the order given; a name given again keeps its place and takes the new value. Values are
    /// trimmed of the spaces and newlines a paste leaves. <c>host</c>, <c>content-length</c>,
    /// <c>connection</c>, <c>expect</c>, <c>upgrade</c> and <c>transfer-encoding</c> are set by the
    /// default transport itself, which drops them.
    /// </summary>
    public IEnumerable<KeyValuePair<string, string>>? Headers { internal get; init; }

    /// <summary>
    /// When set, each request carries <c>x-cronwatch-signature: sha256=&lt;hex&gt;</c>, the
    /// HMAC-SHA256 of the raw body with this secret, so the receiver can verify it
    /// (<see cref="WebhookChannel.Signature"/>).
    /// </summary>
    public string? Secret { internal get; init; }

    /// <summary>Sends this channel's requests; by default the client's transport.</summary>
    public ITransport? Transport { get; init; }

    /// <summary>Names what is set, never a value.</summary>
    public override string ToString() =>
        "WebhookOptions(url " + ChannelShared.Set(Url) + ", headers " + (Headers?.Count() ?? 0).ToString(CultureInfo.InvariantCulture)
        + (string.IsNullOrEmpty(Secret) ? "" : ", secret set") + ")";
}

/// <summary>
/// POSTs each alert as JSON to any URL (<c>alerts/webhook.ts</c>). The body is the payload's
/// version, <c>"schema":1</c>, first, then the <see cref="Alert"/> as the SDK writes it
/// (<see cref="Alert.ToJson"/>); its JSON Schema is https://cronwatch.dev/schemas/webhook/1.json.
/// A redirect is an error: point the URL at where the receiver really is.
/// </summary>
public sealed class WebhookChannel : IChannel
{
    /// <summary>
    /// The payload's version, sent as its first field. It goes up only if a major release changes
    /// the payload in a way that is not additive.
    /// </summary>
    private const int Schema = 1;

    private readonly string _url;
    private readonly List<KeyValuePair<string, string>> _headers;
    private readonly string _secret;
    private readonly ITransport? _transport;

    /// <summary>The channel.</summary>
    /// <exception cref="CronwatchException">Without a URL.</exception>
    public WebhookChannel(WebhookOptions options)
    {
        ArgumentNullException.ThrowIfNull(options);
        if (string.IsNullOrEmpty(options.Url))
        {
            throw ChannelShared.Invalid("Webhook needs a Url");
        }
        _url = options.Url;
        _headers = (options.Headers ?? []).ToList();
        _secret = options.Secret ?? "";
        _transport = options.Transport;
    }

    /// <summary>
    /// The webhook's signature of a body: the HMAC-SHA256 of the body with the secret, as
    /// lowercase hex. The request carries it as <c>x-cronwatch-signature: sha256=&lt;signature&gt;</c>.
    /// </summary>
    public static string Signature(string secret, string body)
    {
        ArgumentNullException.ThrowIfNull(secret);
        ArgumentNullException.ThrowIfNull(body);
        return ChannelShared.Hex(ChannelShared.HmacSha256(Js.Utf8(secret), body));
    }

    /// <inheritdoc/>
    public string Name => "webhook";

    /// <inheritdoc/>
    public async Task SendAsync(Alert alert, ChannelContext context, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(alert);
        ArgumentNullException.ThrowIfNull(context);
        var payload = new JsObject().Set("schema", Schema);
        foreach (var field in alert.ToValue())
        {
            payload.Set(field.Key, field.Value);
        }
        string body = payload.ToJson();
        // A JavaScript object's keys: an exact name given again keeps its place.
        var headers = new JsObject().Set("content-type", "application/json").Set("user-agent", "cronwatch");
        foreach (var h in _headers)
        {
            // A pasted Authorization value often carries a stray space or newline, which fetch
            // would refuse.
            headers.Set(h.Key, Js.Trim(h.Value ?? ""));
        }
        if (_secret.Length > 0)
        {
            headers.Set("x-cronwatch-signature", "sha256=" + Signature(_secret, body));
        }
        var list = new List<KeyValuePair<string, string>>();
        foreach (var e in headers)
        {
            list.Add(new(e.Key, (string)e.Value!));
        }
        // A redirect is refused, not followed: the headers (and the signature) would go with it.
        var answer = await Post.FetchAsync(ChannelShared.Transport(_transport, context), Post.Timeout, _url, list, body, cancellationToken).ConfigureAwait(false);
        if (!answer.Ok)
        {
            // Only the origin: a webhook URL's path or query often is the credential.
            throw Post.Fail("Webhook " + Post.Origin(_url) + " answered " + answer.Status.ToString(CultureInfo.InvariantCulture));
        }
    }

    /// <summary>Names the channel.</summary>
    public override string ToString() => "WebhookChannel";
}
