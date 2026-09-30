using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.Threading;
using System.Threading.Tasks;
using Cronwatch.Internal;

namespace Cronwatch.Alerts;

/// <summary>Configures <see cref="MailgunChannel"/>. Its <see cref="ToString"/> never shows the API key.</summary>
[DebuggerDisplay("{ToString(),nq}")]
public sealed class MailgunOptions
{
    /// <summary>A Mailgun API key. Trimmed of the spaces and newlines a paste leaves.</summary>
    public string? ApiKey { internal get; init; }

    /// <summary>The sending domain, <c>mg.example.com</c>.</summary>
    public string? Domain { get; init; }

    /// <summary><c>"eu"</c> for the EU region (<c>api.eu.mailgun.net</c>). Default <c>"us"</c>.</summary>
    public string Region { get; init; } = "us";

    /// <summary>The sender, <c>alerts@example.com</c> or <c>CronWatch &lt;alerts@example.com&gt;</c>. Mailgun must allow it.</summary>
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
    public override string ToString() =>
        "MailgunOptions(apiKey " + ChannelShared.Set(ApiKey) + ", region " + Region + ", to " + To.Count.ToString(CultureInfo.InvariantCulture) + ")";
}

/// <summary>
/// Sends alerts as email through Mailgun (<c>alerts/mailgun.ts</c>): <c>POST
/// https://api.mailgun.net/v3/&lt;domain&gt;/messages</c> (<c>api.eu.mailgun.net</c> for the EU
/// region), form encoded, with basic auth <c>api:&lt;key&gt;</c>.
/// </summary>
public sealed class MailgunChannel : IChannel
{
    private readonly string _apiKey;
    private readonly string _url;
    private readonly EmailSettings _email;
    private readonly ITransport? _transport;

    /// <summary>The channel.</summary>
    /// <exception cref="CronwatchException">Without an API key, a domain, a sender or a recipient.</exception>
    public MailgunChannel(MailgunOptions options)
    {
        ArgumentNullException.ThrowIfNull(options);
        _apiKey = ChannelShared.Trimmed(options.ApiKey);
        if (_apiKey.Length == 0)
        {
            throw ChannelShared.Invalid("Mailgun needs an ApiKey");
        }
        if (string.IsNullOrEmpty(options.Domain))
        {
            throw ChannelShared.Invalid("Mailgun needs a Domain");
        }
        string host = options.Region == "eu" ? "https://api.eu.mailgun.net" : "https://api.mailgun.net";
        _url = host + "/v3/" + ChannelShared.EncodeUriComponent(options.Domain) + "/messages";
        _email = EmailSettings.Of("Mailgun", options.From, options.To, options.SubjectPrefix, options.Link);
        _transport = options.Transport;
    }

    /// <inheritdoc/>
    public string Name => "mailgun";

    /// <inheritdoc/>
    public Task SendAsync(Alert alert, ChannelContext context, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(alert);
        ArgumentNullException.ThrowIfNull(context);
        EmailMail mail = EmailText.Compose(alert, _email);
        var form = new List<KeyValuePair<string, string>> { new("from", mail.From) };
        foreach (string address in mail.To)
        {
            form.Add(new("to", address));
        }
        form.Add(new("subject", mail.Subject));
        form.Add(new("text", mail.Text));
        form.Add(new("html", mail.Html));
        form.Add(new("o:tag", "cronwatch"));
        return ChannelShared.SendAsync(
            ChannelShared.Transport(_transport, context),
            "Mailgun",
            _url,
            ChannelShared.Headers(
                "content-type", "application/x-www-form-urlencoded",
                "authorization", ChannelShared.BasicAuth("api", _apiKey)),
            ChannelShared.Form(form),
            [_apiKey],
            cancellationToken);
    }

    /// <summary>Names the channel.</summary>
    public override string ToString() => "MailgunChannel";
}
