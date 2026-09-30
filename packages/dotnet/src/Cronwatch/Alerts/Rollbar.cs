using System;
using System.Diagnostics;
using System.Threading;
using System.Threading.Tasks;
using Cronwatch.Internal;

namespace Cronwatch.Alerts;

/// <summary>Configures <see cref="RollbarChannel"/>. Its <see cref="ToString"/> never shows the access token.</summary>
[DebuggerDisplay("{ToString(),nq}")]
public sealed class RollbarOptions
{
    /// <summary>A project access token with the <c>post_server_item</c> scope. Trimmed of the spaces and newlines a paste leaves.</summary>
    public string? AccessToken { internal get; init; }

    /// <summary>The item's environment. Default <c>"production"</c>.</summary>
    public string Environment { get; init; } = "production";

    /// <summary>Also send recoveries, as info items. Default true.</summary>
    public bool Recovered { get; init; } = true;

    /// <summary>A link back to the job in your dashboard. Null or <c>""</c> is no link.</summary>
    public Func<Alert, string?>? Link { get; init; }

    /// <summary>Sends this channel's requests; by default the client's transport.</summary>
    public ITransport? Transport { get; init; }

    /// <summary>Names what is set, never the access token.</summary>
    public override string ToString() =>
        "RollbarOptions(accessToken " + ChannelShared.Set(AccessToken) + ", environment " + Environment + ", recovered " + (Recovered ? "true" : "false") + ")";
}

/// <summary>
/// Reports alerts to Rollbar, one item per job and alert type (<c>alerts/rollbar.ts</c>):
/// <c>POST https://api.rollbar.com/api/1/item/</c> with <c>X-Rollbar-Access-Token</c>.
/// </summary>
public sealed class RollbarChannel : IChannel
{
    private const string Endpoint = "https://api.rollbar.com/api/1/item/";

    private readonly string _accessToken;
    private readonly string _environment;
    private readonly bool _recovered;
    private readonly Func<Alert, string?>? _link;
    private readonly ITransport? _transport;

    /// <summary>The channel.</summary>
    /// <exception cref="CronwatchException">Without an access token.</exception>
    public RollbarChannel(RollbarOptions options)
    {
        ArgumentNullException.ThrowIfNull(options);
        _accessToken = ChannelShared.Trimmed(options.AccessToken);
        if (_accessToken.Length == 0)
        {
            throw ChannelShared.Invalid("Rollbar needs an AccessToken");
        }
        _environment = options.Environment ?? "production";
        _recovered = options.Recovered;
        _link = options.Link;
        _transport = options.Transport;
    }

    /// <inheritdoc/>
    public string Name => "rollbar";

    /// <inheritdoc/>
    public Task SendAsync(Alert alert, ChannelContext context, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(alert);
        ArgumentNullException.ThrowIfNull(context);
        if (alert.Type == AlertType.Recovered && !_recovered)
        {
            return Task.CompletedTask;
        }
        string link = ChannelShared.Link(_link, alert);
        string type = alert.Type.Value;
        var custom = new JsObject().Set("job", alert.Job).Set("type", type);
        string triage = ChannelShared.Triage(alert);
        if (triage.Length > 0)
        {
            custom.Set("triage", triage);
        }
        if (link.Length > 0)
        {
            custom.Set("link", link);
        }
        custom.Set("details", alert.Details.ToValue()).Set("run", ChannelShared.RunSummary(alert));
        var data = new JsObject()
            .Set("environment", Post.Cut(_environment, 255))
            .Set("level", ChannelShared.Severity(alert.Type))
            .Set("timestamp", Js.FloorDiv(alert.At, 1000))
            .Set("title", Post.Cut(alert.Title, 255))
            // Rollbar hashes a fingerprint longer than 40 characters itself.
            .Set("fingerprint", "cronwatch:" + alert.Job + ":" + type)
            .Set("uuid", ChannelShared.AsUuid(ChannelShared.AlertId(alert)))
            .Set("body", new JsObject().Set("message", new JsObject().Set("body", alert.Message)))
            .Set("custom", custom)
            .Set("notifier", new JsObject().Set("name", "cronwatch"));
        return ChannelShared.SendAsync(
            ChannelShared.Transport(_transport, context),
            "Rollbar",
            Endpoint,
            ChannelShared.Headers("content-type", "application/json", "x-rollbar-access-token", _accessToken),
            new JsObject().Set("data", data).ToJson(),
            [_accessToken],
            cancellationToken);
    }

    /// <summary>Names the channel.</summary>
    public override string ToString() => "RollbarChannel";
}
