using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Threading;
using System.Threading.Tasks;
using Cronwatch.Internal;

namespace Cronwatch.Alerts;

/// <summary>Configures <see cref="SlackChannel"/>. Its <see cref="ToString"/> never shows the webhook URL.</summary>
[DebuggerDisplay("{ToString(),nq}")]
public sealed class SlackOptions
{
    /// <summary>
    /// An incoming webhook URL from api.slack.com/messaging/webhooks. It is its own credential:
    /// errors never quote it.
    /// </summary>
    public string? WebhookUrl { internal get; init; }

    /// <summary>A link back to the job in your dashboard: <c>alert =&gt; "https://app.example.com/cronwatch/jobs/" + alert.Job</c>. Null or <c>""</c> is no link.</summary>
    public Func<Alert, string?>? Link { get; init; }

    /// <summary>Sends this channel's requests; by default the client's transport.</summary>
    public ITransport? Transport { get; init; }

    /// <summary>Names what is set, never the webhook URL.</summary>
    public override string ToString() => "SlackOptions(webhookUrl " + ChannelShared.Set(WebhookUrl) + (Link == null ? "" : ", link") + ")";
}

/// <summary>Sends alerts to a Slack channel through an incoming webhook (<c>alerts/slack.ts</c>).</summary>
public sealed class SlackChannel : IChannel
{
    private static readonly Dictionary<string, string> Emoji = new(StringComparer.Ordinal)
    {
        ["missed"] = ":hourglass_flowing_sand:",
        ["failed"] = ":x:",
        ["stuck"] = ":no_entry:",
        ["slow"] = ":turtle:",
        ["over_budget"] = ":moneybag:",
        ["recovered"] = ":white_check_mark:",
    };

    private readonly string _webhookUrl;
    private readonly Func<Alert, string?>? _link;
    private readonly ITransport? _transport;

    /// <summary>The channel. Refuses options without a webhook URL.</summary>
    /// <exception cref="CronwatchException">Without a webhook URL.</exception>
    public SlackChannel(SlackOptions options)
    {
        ArgumentNullException.ThrowIfNull(options);
        if (string.IsNullOrEmpty(options.WebhookUrl))
        {
            throw ChannelShared.Invalid("Slack needs a WebhookUrl");
        }
        _webhookUrl = options.WebhookUrl;
        _link = options.Link;
        _transport = options.Transport;
    }

    /// <inheritdoc/>
    public string Name => "slack";

    /// <inheritdoc/>
    public async Task SendAsync(Alert alert, ChannelContext context, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(alert);
        ArgumentNullException.ThrowIfNull(context);
        string url = ChannelShared.Link(_link, alert);
        string title = (Emoji.TryGetValue(alert.Type.Value, out string? emoji) ? emoji : "undefined")
            + " *" + Escape(alert.Title) + "*" + (url.Length == 0 ? "" : " (<" + url + "|open>)");
        string body = Js.Head(CodeBlockSafe(Escape(alert.Message)), 2900);
        var blocks = new List<object?> { Section(title), Section("```" + body + "```") };
        // Its own block, so a long diagnosis cannot push a block past Slack's 3000 character limit.
        string triage = ChannelShared.Triage(alert);
        if (triage.Length > 0)
        {
            blocks.Add(Section(Js.Head("_Triage:_ " + Escape(triage), 3000)));
        }
        var payload = new JsObject()
            // The notification fallback is parsed as mrkdwn too, so it is escaped like the blocks.
            .Set("text", Escape(alert.Title + "\n" + alert.Message))
            .Set("blocks", blocks);
        // A redirect is refused, not followed: a webhook URL is its own credential.
        var answer = await Post.FetchAsync(
            ChannelShared.Transport(_transport, context),
            Post.Timeout,
            _webhookUrl,
            ChannelShared.Headers("content-type", "application/json"),
            payload.ToJson(),
            cancellationToken).ConfigureAwait(false);
        if (!answer.Ok)
        {
            throw Post.Fail("Slack webhook answered " + answer.Status.ToString(System.Globalization.CultureInfo.InvariantCulture) + ": " + Js.Head(answer.Body, 200));
        }
    }

    private static JsObject Section(string text) =>
        new JsObject().Set("type", "section").Set("text", new JsObject().Set("type", "mrkdwn").Set("text", text));

    /// <summary>Slack's three control characters. Escaping &lt; and &gt; also stops <c>&lt;!channel&gt;</c> and links.</summary>
    internal static string Escape(string text) =>
        text.Replace("&", "&amp;", StringComparison.Ordinal).Replace("<", "&lt;", StringComparison.Ordinal).Replace(">", "&gt;", StringComparison.Ordinal);

    /// <summary>Breaks up <c>```</c> so text inside a code block cannot close it.</summary>
    internal static string CodeBlockSafe(string text) => text.Replace("```", "`\u200b`\u200b`", StringComparison.Ordinal);

    /// <summary>The channel for an incoming webhook URL, with no link: the common case.</summary>
    /// <exception cref="CronwatchException">For an empty URL.</exception>
    public static SlackChannel Webhook(string webhookUrl) => new(new SlackOptions { WebhookUrl = webhookUrl });

    /// <summary>Names the channel.</summary>
    public override string ToString() => "SlackChannel";
}

/// <summary><see cref="SlackChannel.Webhook"/>'s former home.</summary>
[Obsolete("Use SlackChannel.Webhook(url), on the channel type as every channel's constructor is. This class still works through 1.x and goes in 2.0.")]
public static class Slack
{
    /// <summary>The channel for an incoming webhook URL, with no link (<see cref="SlackChannel.Webhook"/>).</summary>
    /// <exception cref="CronwatchException">For an empty URL.</exception>
    public static SlackChannel Webhook(string webhookUrl) => SlackChannel.Webhook(webhookUrl);
}
