using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.Threading;
using System.Threading.Tasks;
using Cronwatch.Internal;

namespace Cronwatch.Alerts;

/// <summary>Configures <see cref="SendGridChannel"/>. Its <see cref="ToString"/> never shows the API key.</summary>
[DebuggerDisplay("{ToString(),nq}")]
public sealed class SendGridOptions
{
    /// <summary>A SendGrid API key. Trimmed of the spaces and newlines a paste leaves.</summary>
    public string? ApiKey { internal get; init; }

    /// <summary><c>"eu"</c> for an EU subuser (<c>api.eu.sendgrid.com</c>). Default <c>"us"</c>.</summary>
    public string Region { get; init; } = "us";

    /// <summary>The sender, <c>alerts@example.com</c> or <c>CronWatch &lt;alerts@example.com&gt;</c>. SendGrid must allow it.</summary>
    public string? From { get; init; }

    /// <summary>The recipients, each an address or <c>Name &lt;address&gt;</c>. Blank ones are left out.</summary>
    public IList<string> To { get; init; } = new List<string>();

    /// <summary>Put in front of the title in the subject, <c>[prod]</c> say.</summary>
    public string? SubjectPrefix { get; init; }

    /// <summary>A link back to the job in your dashboard. Null or <c>""</c> is no link; only http and https links are put in a mail.</summary>
    public Func<Alert, string?>? Link { get; init; }

    /// <summary>Sends this channel's requests; by default the client's transport.</summary>
    public ITransport? Transport { get; init; }

    /// <summary>Names what is set, never the API key.</summary>
    public override string ToString() =>
        "SendGridOptions(apiKey " + ChannelShared.Set(ApiKey) + ", region " + Region + ", to " + To.Count.ToString(CultureInfo.InvariantCulture) + ")";
}

/// <summary>
/// Sends alerts as email through SendGrid (<c>alerts/sendgrid.ts</c>): <c>POST
/// https://api.sendgrid.com/v3/mail/send</c> (<c>api.eu.sendgrid.com</c> for EU subusers) with a
/// bearer API key.
/// </summary>
public sealed class SendGridChannel : IChannel
{
    private readonly string _apiKey;
    private readonly string _url;
    private readonly EmailSettings _email;
    private readonly ITransport? _transport;

    /// <summary>The channel.</summary>
    /// <exception cref="CronwatchException">Without an API key, a sender or a recipient.</exception>
    public SendGridChannel(SendGridOptions options)
    {
        ArgumentNullException.ThrowIfNull(options);
        _apiKey = ChannelShared.Trimmed(options.ApiKey);
        if (_apiKey.Length == 0)
        {
            throw ChannelShared.Invalid("SendGrid needs an ApiKey");
        }
        _url = options.Region == "eu" ? "https://api.eu.sendgrid.com/v3/mail/send" : "https://api.sendgrid.com/v3/mail/send";
        _email = EmailSettings.Of("SendGrid", options.From, options.To, options.SubjectPrefix, options.Link);
        _transport = options.Transport;
    }

    /// <inheritdoc/>
    public string Name => "sendgrid";

    /// <inheritdoc/>
    public Task SendAsync(Alert alert, ChannelContext context, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(alert);
        ArgumentNullException.ThrowIfNull(context);
        EmailMail mail = EmailText.Compose(alert, _email);
        var to = new List<object?>();
        foreach (string address in mail.To)
        {
            to.Add(EmailText.ParseAddress(address));
        }
        var body = new JsObject()
            .Set("personalizations", new List<object?> { new JsObject().Set("to", to) })
            .Set("from", EmailText.ParseAddress(mail.From))
            .Set("subject", mail.Subject)
            // text/plain must come before text/html.
            .Set(
                "content",
                new List<object?>
                {
                    new JsObject().Set("type", "text/plain").Set("value", mail.Text),
                    new JsObject().Set("type", "text/html").Set("value", mail.Html),
                })
            .Set("categories", new List<object?> { "cronwatch" });
        return ChannelShared.SendAsync(
            ChannelShared.Transport(_transport, context),
            "SendGrid",
            _url,
            ChannelShared.Headers("content-type", "application/json", "authorization", "Bearer " + _apiKey),
            body.ToJson(),
            [_apiKey],
            cancellationToken);
    }

    /// <summary>Names the channel.</summary>
    public override string ToString() => "SendGridChannel";
}
