using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Threading;
using System.Threading.Tasks;
using Cronwatch.Internal;

namespace Cronwatch.Alerts;

/// <summary>Configures <see cref="HoneybadgerChannel"/>. Its <see cref="ToString"/> never shows the API key.</summary>
[DebuggerDisplay("{ToString(),nq}")]
public sealed class HoneybadgerOptions
{
    /// <summary>The project's API key. Trimmed of the spaces and newlines a paste leaves.</summary>
    public string? ApiKey { internal get; init; }

    /// <summary>The notice's environment. Default <c>"production"</c>.</summary>
    public string Environment { get; init; } = "production";

    /// <summary>The API's origin, <c>https://eu-api.honeybadger.io</c> for EU projects. Default <c>https://api.honeybadger.io</c>.</summary>
    public string Endpoint { get; init; } = "https://api.honeybadger.io";

    /// <summary>Also send recoveries. Default false.</summary>
    public bool Recovered { get; init; }

    /// <summary>A link back to the job in your dashboard. Null or <c>""</c> is no link.</summary>
    public Func<Alert, string?>? Link { get; init; }

    /// <summary>Sends this channel's requests; by default the client's transport.</summary>
    public ITransport? Transport { get; init; }

    /// <summary>Names what is set, never the API key.</summary>
    public override string ToString() =>
        "HoneybadgerOptions(apiKey " + ChannelShared.Set(ApiKey) + ", environment " + Environment + ", recovered " + (Recovered ? "true" : "false") + ")";
}

/// <summary>
/// Reports alerts to Honeybadger as error notices (<c>alerts/honeybadger.ts</c>), one error per
/// job and alert type: <c>POST https://api.honeybadger.io/v1/notices</c> with <c>X-API-Key</c>.
/// </summary>
public sealed class HoneybadgerChannel : IChannel
{
    private static readonly Dictionary<string, string> Class = new(StringComparer.Ordinal)
    {
        ["missed"] = "CronWatch::Missed",
        ["failed"] = "CronWatch::Failed",
        ["stuck"] = "CronWatch::Stuck",
        ["slow"] = "CronWatch::Slow",
        ["over_budget"] = "CronWatch::OverBudget",
        ["under_floor"] = "CronWatch::UnderFloor",
        ["recovered"] = "CronWatch::Recovered",
    };

    private readonly string _apiKey;
    private readonly string _environment;
    private readonly string _url;
    private readonly bool _recovered;
    private readonly Func<Alert, string?>? _link;
    private readonly ITransport? _transport;

    /// <summary>The channel.</summary>
    /// <exception cref="CronwatchException">Without an API key.</exception>
    public HoneybadgerChannel(HoneybadgerOptions options)
    {
        ArgumentNullException.ThrowIfNull(options);
        _apiKey = ChannelShared.Trimmed(options.ApiKey);
        if (_apiKey.Length == 0)
        {
            throw ChannelShared.Invalid("Honeybadger needs an ApiKey");
        }
        _environment = options.Environment ?? "production";
        _url = (options.Endpoint ?? "https://api.honeybadger.io").TrimEnd('/') + "/v1/notices";
        _recovered = options.Recovered;
        _link = options.Link;
        _transport = options.Transport;
    }

    /// <inheritdoc/>
    public string Name => "honeybadger";

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
        var error = new JsObject();
        // An unknown type has no class, which JSON.stringify leaves out.
        if (Class.TryGetValue(type, out string? errorClass))
        {
            error.Set("class", errorClass);
        }
        error
            .Set("message", Post.Cut(alert.Title + "\n" + alert.Message, 8000))
            // No code ran here; one frame naming the job keeps the notice well formed.
            .Set("backtrace", new List<object?> { new JsObject().Set("number", "0").Set("file", "cronwatch/" + alert.Job).Set("method", type) })
            .Set("fingerprint", "cronwatch:" + alert.Job + ":" + type)
            .Set("tags", new List<object?> { "cronwatch", type });
        var request = new JsObject().Set("component", "cronwatch").Set("action", alert.Job);
        if (link.Length > 0)
        {
            request.Set("url", link);
        }
        var ctx = new JsObject().Set("job", alert.Job).Set("type", type);
        string triage = ChannelShared.Triage(alert);
        if (triage.Length > 0)
        {
            ctx.Set("triage", triage);
        }
        ctx.Set("details", alert.Details.ToValue()).Set("run", ChannelShared.RunSummary(alert));
        request.Set("context", ctx);
        var notice = new JsObject()
            .Set("notifier", new JsObject().Set("name", "cronwatch").Set("url", "https://cronwatch.dev"))
            .Set("error", error)
            .Set("request", request)
            .Set("server", new JsObject().Set("environment_name", _environment));
        return ChannelShared.SendAsync(
            ChannelShared.Transport(_transport, context),
            "Honeybadger",
            _url,
            ChannelShared.Headers(
                "content-type", "application/json",
                "accept", "application/json",
                "x-api-key", _apiKey),
            notice.ToJson(),
            [_apiKey],
            cancellationToken);
    }

    /// <summary>Names the channel.</summary>
    public override string ToString() => "HoneybadgerChannel";
}
