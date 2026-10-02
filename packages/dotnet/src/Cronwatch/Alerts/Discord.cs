using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using Cronwatch.Internal;

namespace Cronwatch.Alerts;

/// <summary>Configures <see cref="DiscordChannel"/>. Its <see cref="ToString"/> never shows the webhook URL.</summary>
[DebuggerDisplay("{ToString(),nq}")]
public sealed class DiscordOptions
{
    /// <summary>A channel webhook URL (Server Settings, Integrations, Webhooks). It is its own credential: errors never quote it.</summary>
    public string? WebhookUrl { internal get; init; }

    /// <summary>A link back to the job in your dashboard. Null or <c>""</c> is no link.</summary>
    public Func<Alert, string?>? Link { get; init; }

    /// <summary>Sends this channel's requests; by default the client's transport.</summary>
    public ITransport? Transport { get; init; }

    /// <summary>Names what is set, never the webhook URL.</summary>
    public override string ToString() => "DiscordOptions(webhookUrl " + ChannelShared.Set(WebhookUrl) + (Link == null ? "" : ", link") + ")";
}

/// <summary>Sends alerts to a Discord channel through a webhook (<c>alerts/discord.ts</c>).</summary>
public sealed class DiscordChannel : IChannel
{
    private static readonly Dictionary<string, int> Color = new(StringComparer.Ordinal)
    {
        ["missed"] = 0xb7791f,
        ["failed"] = 0xc62828,
        ["stuck"] = 0xc62828,
        ["slow"] = 0xb7791f,
        ["over_budget"] = 0xb7791f,
        ["under_floor"] = 0xb7791f,
        ["recovered"] = 0x1f8a4c,
    };

    private readonly string _webhookUrl;
    private readonly Func<Alert, string?>? _link;
    private readonly ITransport? _transport;

    /// <summary>The channel.</summary>
    /// <exception cref="CronwatchException">Without a webhook URL.</exception>
    public DiscordChannel(DiscordOptions options)
    {
        ArgumentNullException.ThrowIfNull(options);
        if (string.IsNullOrEmpty(options.WebhookUrl))
        {
            throw ChannelShared.Invalid("Discord needs a WebhookUrl");
        }
        _webhookUrl = options.WebhookUrl;
        _link = options.Link;
        _transport = options.Transport;
    }

    /// <inheritdoc/>
    public string Name => "discord";

    /// <inheritdoc/>
    public async Task SendAsync(Alert alert, ChannelContext context, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(alert);
        ArgumentNullException.ThrowIfNull(context);
        string url = ChannelShared.Link(_link, alert);
        var embed = new JsObject().Set("title", alert.Title);
        if (url.Length > 0)
        {
            embed.Set("url", url);
        }
        embed.Set("description", EmbedDescription(alert));
        // An unknown type has no colour, which JSON.stringify leaves out.
        if (Color.TryGetValue(alert.Type.Value, out int color))
        {
            embed.Set("color", color);
        }
        embed.Set("timestamp", ChannelShared.IsoString(alert.At));
        var payload = new JsObject()
            .Set("content", alert.Title)
            // Job output can hold anything, "@everyone" included; ping no one.
            .Set("allowed_mentions", new JsObject().Set("parse", new List<object?>()))
            .Set("embeds", new List<object?> { embed });
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
            throw Post.Fail("Discord webhook answered " + answer.Status.ToString(CultureInfo.InvariantCulture) + ": " + Js.Head(answer.Body, 200));
        }
    }

    /// <summary>The longest embed description Discord takes. The title (under 256) and it stay well inside the embed's 6000.</summary>
    internal const int DescriptionMax = 4096;

    /// <summary>
    /// The message in a code block, then the triage. Each part has its own cap, and escaping can
    /// grow both, so the whole is held to <see cref="DescriptionMax"/> (in UTF-16 units) by
    /// cutting the message's block, never the triage: Discord refuses a longer one on every retry.
    /// </summary>
    internal static string EmbedDescription(Alert alert)
    {
        string triage = ChannelShared.Triage(alert);
        string section = triage.Length == 0 ? "" : "\n**Triage:** " + EscapeMarkdown(Js.Head(triage, 1000));
        const int fences = 8;
        return "```\n" + Post.Cut(SlackChannel.CodeBlockSafe(Js.Head(alert.Message, 3800)), DescriptionMax - fences - section.Length) + "\n```" + section;
    }

    /// <summary>Escapes the characters Discord reads as markdown, links included.</summary>
    internal static string EscapeMarkdown(string text)
    {
        var b = new StringBuilder(text.Length);
        foreach (char c in text)
        {
            if ("\\`*_~|[]()<>".Contains(c, StringComparison.Ordinal))
            {
                b.Append('\\');
            }
            b.Append(c);
        }
        return b.ToString();
    }

    /// <summary>The channel for a webhook URL, with no link: the common case.</summary>
    /// <exception cref="CronwatchException">For an empty URL.</exception>
    public static DiscordChannel Webhook(string webhookUrl) => new(new DiscordOptions { WebhookUrl = webhookUrl });

    /// <summary>Names the channel.</summary>
    public override string ToString() => "DiscordChannel";
}

/// <summary><see cref="DiscordChannel.Webhook"/>'s former home.</summary>
[Obsolete("Use DiscordChannel.Webhook(url), on the channel type as every channel's constructor is. This class still works through 1.x and goes in 2.0.")]
public static class Discord
{
    /// <summary>The channel for a webhook URL, with no link (<see cref="DiscordChannel.Webhook"/>).</summary>
    /// <exception cref="CronwatchException">For an empty URL.</exception>
    public static DiscordChannel Webhook(string webhookUrl) => DiscordChannel.Webhook(webhookUrl);
}
