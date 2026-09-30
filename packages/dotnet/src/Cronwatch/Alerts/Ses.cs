using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.Threading;
using System.Threading.Tasks;
using Cronwatch.Internal;

namespace Cronwatch.Alerts;

/// <summary>Configures <see cref="SesChannel"/>. Its <see cref="ToString"/> never shows a credential.</summary>
[DebuggerDisplay("{ToString(),nq}")]
public sealed class SesOptions
{
    /// <summary>The AWS region, <c>us-east-1</c>.</summary>
    public string? Region { get; init; }

    /// <summary>The access key id. Trimmed of the spaces and newlines a paste leaves.</summary>
    public string? AccessKeyId { internal get; init; }

    /// <summary>The secret access key. Trimmed of the spaces and newlines a paste leaves.</summary>
    public string? SecretAccessKey { internal get; init; }

    /// <summary>A session token, for temporary credentials. Trimmed; empty is none.</summary>
    public string? SessionToken { internal get; init; }

    /// <summary>A configuration set to send through, or none.</summary>
    public string? ConfigurationSetName { get; init; }

    /// <summary>The clock the signature's time comes from. Default <see cref="TimeProvider.System"/>.</summary>
    public TimeProvider? Clock { get; init; }

    /// <summary>The sender, <c>alerts@example.com</c> or <c>CronWatch &lt;alerts@example.com&gt;</c>. SES must allow it.</summary>
    public string? From { get; init; }

    /// <summary>The recipients. Blank ones are left out.</summary>
    public IList<string> To { get; init; } = new List<string>();

    /// <summary>Put in front of the title in the subject, <c>[prod]</c> say.</summary>
    public string? SubjectPrefix { get; init; }

    /// <summary>A link back to the job in your dashboard. Null or <c>""</c> is no link; only http and https links are put in a mail.</summary>
    public Func<Alert, string?>? Link { get; init; }

    /// <summary>Sends this channel's requests; by default the client's transport.</summary>
    public ITransport? Transport { get; init; }

    /// <summary>Names what is set, never a credential.</summary>
    public override string ToString() =>
        "SesOptions(region " + (Region ?? "unset") + ", accessKeyId " + ChannelShared.Set(AccessKeyId) + ", secretAccessKey " + ChannelShared.Set(SecretAccessKey)
        + (string.IsNullOrEmpty(SessionToken) ? "" : ", sessionToken set") + ", to " + To.Count.ToString(CultureInfo.InvariantCulture) + ")";
}

/// <summary>
/// Sends alerts as email through Amazon SES, API v2 SendEmail (<c>alerts/ses.ts</c>): <c>POST
/// https://email.&lt;region&gt;.amazonaws.com/v2/email/outbound-emails</c>, signed with AWS
/// Signature Version 4, so no AWS SDK is needed.
/// </summary>
public sealed class SesChannel : IChannel
{
    private readonly string _region;
    private readonly string _accessKeyId;
    private readonly string _secretAccessKey;
    private readonly string? _sessionToken;
    private readonly string _configurationSetName;
    private readonly TimeProvider _clock;
    private readonly string _url;
    private readonly EmailSettings _email;
    private readonly ITransport? _transport;

    /// <summary>The channel.</summary>
    /// <exception cref="CronwatchException">Without a region, the credentials, a sender or a recipient.</exception>
    public SesChannel(SesOptions options)
    {
        ArgumentNullException.ThrowIfNull(options);
        string region = options.Region ?? "";
        if (region.Length == 0)
        {
            throw ChannelShared.Invalid("SES needs a Region");
        }
        foreach (char c in region)
        {
            if (!((c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '-'))
            {
                throw ChannelShared.Invalid("SES needs a Region like us-east-1");
            }
        }
        // A pasted credential often carries a stray space or newline, which would spoil the
        // signature.
        _accessKeyId = ChannelShared.Trimmed(options.AccessKeyId);
        _secretAccessKey = ChannelShared.Trimmed(options.SecretAccessKey);
        if (_accessKeyId.Length == 0 || _secretAccessKey.Length == 0)
        {
            throw ChannelShared.Invalid("SES needs an AccessKeyId and SecretAccessKey");
        }
        string token = ChannelShared.Trimmed(options.SessionToken);
        _sessionToken = token.Length == 0 ? null : token;
        _region = region;
        _configurationSetName = options.ConfigurationSetName ?? "";
        _clock = options.Clock ?? TimeProvider.System;
        _url = "https://email." + region + ".amazonaws.com/v2/email/outbound-emails";
        _email = EmailSettings.Of("SES", options.From, options.To, options.SubjectPrefix, options.Link);
        _transport = options.Transport;
    }

    /// <inheritdoc/>
    public string Name => "ses";

    /// <inheritdoc/>
    public Task SendAsync(Alert alert, ChannelContext context, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(alert);
        ArgumentNullException.ThrowIfNull(context);
        EmailMail mail = EmailText.Compose(alert, _email);
        var body = new JsObject()
            .Set("FromEmailAddress", mail.From)
            .Set("Destination", new JsObject().Set("ToAddresses", mail.To))
            .Set(
                "Content",
                new JsObject().Set(
                    "Simple",
                    new JsObject()
                        .Set("Subject", Data(mail.Subject))
                        .Set("Body", new JsObject().Set("Text", Data(mail.Text)).Set("Html", Data(mail.Html)))));
        if (_configurationSetName.Length > 0)
        {
            body.Set("ConfigurationSetName", _configurationSetName);
        }
        body.Set("EmailTags", new List<object?> { new JsObject().Set("Name", "source").Set("Value", "cronwatch") });
        string text = body.ToJson();
        var headers = SigV4.Sign(
            "POST",
            _url,
            ChannelShared.Headers("content-type", "application/json"),
            text,
            _region,
            "ses",
            _clock.GetUtcNow().ToUnixTimeMilliseconds(),
            _accessKeyId,
            _secretAccessKey,
            _sessionToken);
        return ChannelShared.SendAsync(
            ChannelShared.Transport(_transport, context),
            "SES",
            _url,
            headers,
            text,
            [_secretAccessKey, _sessionToken],
            cancellationToken);
    }

    private static JsObject Data(string text) => new JsObject().Set("Data", text).Set("Charset", "UTF-8");

    /// <summary>Names the channel.</summary>
    public override string ToString() => "SesChannel";
}
