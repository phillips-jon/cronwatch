using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Threading;
using System.Threading.Tasks;
using Cronwatch.Internal;

namespace Cronwatch.Alerts;

/// <summary>Configures <see cref="BugsnagChannel"/>. Its <see cref="ToString"/> never shows the API key.</summary>
[DebuggerDisplay("{ToString(),nq}")]
public sealed class BugsnagOptions
{
    /// <summary>The project's notifier API key. Trimmed of the spaces and newlines a paste leaves.</summary>
    public string? ApiKey { internal get; init; }

    /// <summary>The event's release stage. Default <c>"production"</c>.</summary>
    public string ReleaseStage { get; init; } = "production";

    /// <summary>The notify endpoint, for an on-premise Bugsnag. Default <c>https://notify.bugsnag.com/</c>.</summary>
    public string Endpoint { get; init; } = "https://notify.bugsnag.com/";

    /// <summary>Also send recoveries. Default false.</summary>
    public bool Recovered { get; init; }

    /// <summary>The clock the <c>Bugsnag-Sent-At</c> header's time comes from. Default <see cref="TimeProvider.System"/>.</summary>
    public TimeProvider? Clock { get; init; }

    /// <summary>A link back to the job in your dashboard. Null or <c>""</c> is no link.</summary>
    public Func<Alert, string?>? Link { get; init; }

    /// <summary>Sends this channel's requests; by default the client's transport.</summary>
    public ITransport? Transport { get; init; }

    /// <summary>Names what is set, never the API key.</summary>
    public override string ToString() =>
        "BugsnagOptions(apiKey " + ChannelShared.Set(ApiKey) + ", releaseStage " + ReleaseStage + ", recovered " + (Recovered ? "true" : "false") + ")";
}

/// <summary>
/// Reports alerts to Bugsnag, grouped per job and alert type (<c>alerts/bugsnag.ts</c>): the
/// Error Reporting API, payload version 5, <c>POST https://notify.bugsnag.com/</c> with
/// <c>Bugsnag-Api-Key</c>.
/// </summary>
public sealed class BugsnagChannel : IChannel
{
    private readonly string _apiKey;
    private readonly string _releaseStage;
    private readonly string _endpoint;
    private readonly bool _recovered;
    private readonly TimeProvider _clock;
    private readonly Func<Alert, string?>? _link;
    private readonly ITransport? _transport;

    /// <summary>The channel.</summary>
    /// <exception cref="CronwatchException">Without an API key.</exception>
    public BugsnagChannel(BugsnagOptions options)
    {
        ArgumentNullException.ThrowIfNull(options);
        _apiKey = ChannelShared.Trimmed(options.ApiKey);
        if (_apiKey.Length == 0)
        {
            throw ChannelShared.Invalid("Bugsnag needs an ApiKey");
        }
        _releaseStage = options.ReleaseStage ?? "production";
        _endpoint = options.Endpoint ?? "https://notify.bugsnag.com/";
        _recovered = options.Recovered;
        _clock = options.Clock ?? TimeProvider.System;
        _link = options.Link;
        _transport = options.Transport;
    }

    /// <inheritdoc/>
    public string Name => "bugsnag";

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
        var meta = new JsObject().Set("job", alert.Job).Set("type", type);
        string triage = ChannelShared.Triage(alert);
        if (triage.Length > 0)
        {
            meta.Set("triage", triage);
        }
        if (link.Length > 0)
        {
            meta.Set("link", link);
        }
        meta.Set("details", alert.Details.ToValue()).Set("run", ChannelShared.RunSummary(alert));
        var e = new JsObject()
            .Set(
                "exceptions",
                new List<object?>
                {
                    new JsObject()
                        .Set("errorClass", "CronWatch " + type)
                        .Set("message", Post.Cut(alert.Title + "\n" + alert.Message, 8000))
                        .Set("stacktrace", new List<object?>())
                        .Set("type", "nodejs"),
                })
            .Set("severity", ChannelShared.Severity(alert.Type))
            .Set("unhandled", false)
            .Set("severityReason", new JsObject().Set("type", "handledException"))
            .Set("context", alert.Job)
            .Set("groupingHash", "cronwatch:" + alert.Job + ":" + type)
            .Set("metaData", new JsObject().Set("cronwatch", meta))
            .Set("app", new JsObject().Set("releaseStage", _releaseStage))
            .Set("device", new JsObject().Set("time", ChannelShared.IsoString(alert.At)));
        var payload = new JsObject()
            .Set("apiKey", _apiKey)
            .Set("payloadVersion", "5")
            // The notifier's own version, not the library's; Bugsnag asks for one.
            .Set("notifier", new JsObject().Set("name", "cronwatch").Set("version", "1.0.0").Set("url", "https://cronwatch.dev"))
            .Set("events", new List<object?> { e });
        return ChannelShared.SendAsync(
            ChannelShared.Transport(_transport, context),
            "Bugsnag",
            _endpoint,
            ChannelShared.Headers(
                "content-type", "application/json",
                "bugsnag-api-key", _apiKey,
                "bugsnag-payload-version", "5",
                "bugsnag-sent-at", ChannelShared.IsoString(_clock.GetUtcNow().ToUnixTimeMilliseconds())),
            payload.ToJson(),
            [_apiKey],
            cancellationToken);
    }

    /// <summary>Names the channel.</summary>
    public override string ToString() => "BugsnagChannel";
}
