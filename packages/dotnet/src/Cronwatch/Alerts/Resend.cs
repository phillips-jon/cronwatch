using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.Threading;
using System.Threading.Tasks;
using Cronwatch.Internal;

namespace Cronwatch.Alerts;

/// <summary>Configures <see cref="ResendChannel"/>. Its <see cref="ToString"/> never shows the API key.</summary>
[DebuggerDisplay("{ToString(),nq}")]
public sealed class ResendOptions
{
    /// <summary>A Resend API key. Trimmed of the spaces and newlines a paste leaves.</summary>
    public string? ApiKey { internal get; init; }

    /// <summary>The sender, <c>alerts@example.com</c> or <c>CronWatch &lt;alerts@example.com&gt;</c>. Resend must allow it.</summary>
    public string? From { get; init; }

    /// <summary>The recipients. Blank ones are left out.</summary>
    public IList<string> To { get; init; } = new List<string>();

    /// <summary>Put in front of the title in the subject, <c>[prod]</c> say.</summary>
    public string? SubjectPrefix { get; init; }

    /// <summary>A link back to the job in your dashboard. Null or <c>""</c> is no link; only http and https links are put in a mail.</summary>
    public Func<Alert, string?>? Link { get; init; }

    /// <summary>Sends this channel's requests; by default the client's transport.</summary>
    public ITransport? Transport { get; init; }

    /// <summary>Names what is set, never the API key.</summary>
    public override string ToString() => "ResendOptions(apiKey " + ChannelShared.Set(ApiKey) + ", to " + To.Count.ToString(CultureInfo.InvariantCulture) + ")";
}

/// <summary>
/// Sends alerts as email through Resend (<c>alerts/resend.ts</c>): <c>POST
/// https://api.resend.com/emails</c> with a bearer API key, and an idempotency key so the same
/// alert sent twice within 24 hours is delivered once.
/// </summary>
public sealed class ResendChannel : IChannel
{
    private const string Endpoint = "https://api.resend.com/emails";

    private readonly string _apiKey;
    private readonly EmailSettings _email;
    private readonly ITransport? _transport;

    /// <summary>The channel.</summary>
    /// <exception cref="CronwatchException">Without an API key, a sender or a recipient.</exception>
    public ResendChannel(ResendOptions options)
    {
        ArgumentNullException.ThrowIfNull(options);
        // A pasted credential often carries a stray space or newline, which a header would refuse.
        _apiKey = ChannelShared.Trimmed(options.ApiKey);
        if (_apiKey.Length == 0)
        {
            throw ChannelShared.Invalid("Resend needs an ApiKey");
        }
        _email = EmailSettings.Of("Resend", options.From, options.To, options.SubjectPrefix, options.Link);
        _transport = options.Transport;
    }

    /// <inheritdoc/>
    public string Name => "resend";

    /// <inheritdoc/>
    public Task SendAsync(Alert alert, ChannelContext context, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(alert);
        ArgumentNullException.ThrowIfNull(context);
        EmailMail mail = EmailText.Compose(alert, _email);
        var body = new JsObject()
            .Set("from", mail.From)
            .Set("to", mail.To)
            .Set("subject", mail.Subject)
            .Set("text", mail.Text)
            .Set("html", mail.Html);
        return ChannelShared.SendAsync(
            ChannelShared.Transport(_transport, context),
            "Resend",
            Endpoint,
            ChannelShared.Headers(
                "content-type", "application/json",
                "authorization", "Bearer " + _apiKey,
                "idempotency-key", "cronwatch-" + ChannelShared.AlertId(alert)),
            body.ToJson(),
            [_apiKey],
            cancellationToken);
    }

    /// <summary>Names the channel.</summary>
    public override string ToString() => "ResendChannel";
}
