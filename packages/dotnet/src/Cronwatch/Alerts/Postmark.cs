using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.Threading;
using System.Threading.Tasks;
using Cronwatch.Internal;

namespace Cronwatch.Alerts;

/// <summary>Configures <see cref="PostmarkChannel"/>. Its <see cref="ToString"/> never shows the server token.</summary>
[DebuggerDisplay("{ToString(),nq}")]
public sealed class PostmarkOptions
{
    /// <summary>A Postmark server token. Trimmed of the spaces and newlines a paste leaves.</summary>
    public string? ServerToken { internal get; init; }

    /// <summary>The message stream. Default <c>"outbound"</c>.</summary>
    public string MessageStream { get; init; } = "outbound";

    /// <summary>The sender, <c>alerts@example.com</c> or <c>CronWatch &lt;alerts@example.com&gt;</c>. Postmark must allow it.</summary>
    public string? From { get; init; }

    /// <summary>The recipients. Blank ones are left out.</summary>
    public IList<string> To { get; init; } = new List<string>();

    /// <summary>Put in front of the title in the subject, <c>[prod]</c> say.</summary>
    public string? SubjectPrefix { get; init; }

    /// <summary>A link back to the job in your dashboard. Null or <c>""</c> is no link; only http and https links are put in a mail.</summary>
    public Func<Alert, string?>? Link { get; init; }

    /// <summary>Sends this channel's requests; by default the client's transport.</summary>
    public ITransport? Transport { get; init; }

    /// <summary>Names what is set, never the server token.</summary>
    public override string ToString() => "PostmarkOptions(serverToken " + ChannelShared.Set(ServerToken) + ", to " + To.Count.ToString(CultureInfo.InvariantCulture) + ")";
}

/// <summary>
/// Sends alerts as email through Postmark (<c>alerts/postmark.ts</c>): <c>POST
/// https://api.postmarkapp.com/email</c> with <c>X-Postmark-Server-Token</c>.
/// </summary>
public sealed class PostmarkChannel : IChannel
{
    private const string Endpoint = "https://api.postmarkapp.com/email";

    private readonly string _serverToken;
    private readonly string _messageStream;
    private readonly EmailSettings _email;
    private readonly ITransport? _transport;

    /// <summary>The channel.</summary>
    /// <exception cref="CronwatchException">Without a server token, a sender or a recipient.</exception>
    public PostmarkChannel(PostmarkOptions options)
    {
        ArgumentNullException.ThrowIfNull(options);
        _serverToken = ChannelShared.Trimmed(options.ServerToken);
        if (_serverToken.Length == 0)
        {
            throw ChannelShared.Invalid("Postmark needs a ServerToken");
        }
        _messageStream = options.MessageStream ?? "outbound";
        _email = EmailSettings.Of("Postmark", options.From, options.To, options.SubjectPrefix, options.Link);
        _transport = options.Transport;
    }

    /// <inheritdoc/>
    public string Name => "postmark";

    /// <inheritdoc/>
    public Task SendAsync(Alert alert, ChannelContext context, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(alert);
        ArgumentNullException.ThrowIfNull(context);
        EmailMail mail = EmailText.Compose(alert, _email);
        var body = new JsObject()
            .Set("From", mail.From)
            .Set("To", string.Join(", ", mail.To))
            .Set("Subject", mail.Subject)
            .Set("TextBody", mail.Text)
            .Set("HtmlBody", mail.Html)
            .Set("MessageStream", _messageStream)
            .Set("Tag", "cronwatch");
        return ChannelShared.SendAsync(
            ChannelShared.Transport(_transport, context),
            "Postmark",
            Endpoint,
            ChannelShared.Headers(
                "content-type", "application/json",
                "accept", "application/json",
                "x-postmark-server-token", _serverToken),
            body.ToJson(),
            [_serverToken],
            cancellationToken);
    }

    /// <summary>Names the channel.</summary>
    public override string ToString() => "PostmarkChannel";
}
