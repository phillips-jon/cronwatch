using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Threading;
using System.Threading.Tasks;
using Cronwatch.Internal;

namespace Cronwatch.Alerts;

/// <summary>Configures <see cref="NewRelicChannel"/>. Its <see cref="ToString"/> never shows the API key.</summary>
[DebuggerDisplay("{ToString(),nq}")]
public sealed class NewRelicOptions
{
    /// <summary>A license or insert key. Trimmed of the spaces and newlines a paste leaves.</summary>
    public string? ApiKey { internal get; init; }

    /// <summary>The account's numeric id, <c>"12345"</c>.</summary>
    public string? AccountId { get; init; }

    /// <summary><c>"eu"</c> for an EU account (<c>insights-collector.eu01.nr-data.net</c>). Default <c>"us"</c>.</summary>
    public string Region { get; init; } = "us";

    /// <summary>The events' type, which NRQL selects from. Default <c>"CronWatchAlert"</c>.</summary>
    public string EventType { get; init; } = "CronWatchAlert";

    /// <summary>A link back to the job in your dashboard. Null or <c>""</c> is no link.</summary>
    public Func<Alert, string?>? Link { get; init; }

    /// <summary>Sends this channel's requests; by default the client's transport.</summary>
    public ITransport? Transport { get; init; }

    /// <summary>Names what is set, never the API key.</summary>
    public override string ToString() => "NewRelicOptions(apiKey " + ChannelShared.Set(ApiKey) + ", eventType " + EventType + ")";
}

/// <summary>
/// Records alerts as New Relic custom events (<c>alerts/newrelic.ts</c>): the Event API, <c>POST
/// https://insights-collector.newrelic.com/v1/accounts/&lt;id&gt;/events</c>
/// (<c>insights-collector.eu01.nr-data.net</c> for EU accounts) with <c>Api-Key</c>. Each alert is
/// one event of type <c>CronWatchAlert</c>, queryable with NRQL: <c>SELECT * FROM CronWatchAlert
/// WHERE job = 'nightly'</c>.
/// </summary>
public sealed class NewRelicChannel : IChannel
{
    private readonly string _apiKey;
    private readonly string _url;
    private readonly string _eventType;
    private readonly Func<Alert, string?>? _link;
    private readonly ITransport? _transport;

    /// <summary>The channel.</summary>
    /// <exception cref="CronwatchException">Without an API key or a numeric account id.</exception>
    public NewRelicChannel(NewRelicOptions options)
    {
        ArgumentNullException.ThrowIfNull(options);
        _apiKey = ChannelShared.Trimmed(options.ApiKey);
        if (_apiKey.Length == 0)
        {
            throw ChannelShared.Invalid("New Relic needs an ApiKey");
        }
        string account = options.AccountId ?? "";
        bool digits = account.Length > 0;
        foreach (char c in account)
        {
            digits &= c >= '0' && c <= '9';
        }
        if (!digits)
        {
            throw ChannelShared.Invalid("New Relic needs a numeric AccountId");
        }
        string host = options.Region == "eu" ? "https://insights-collector.eu01.nr-data.net" : "https://insights-collector.newrelic.com";
        _url = host + "/v1/accounts/" + account + "/events";
        _eventType = options.EventType ?? "CronWatchAlert";
        _link = options.Link;
        _transport = options.Transport;
    }

    /// <inheritdoc/>
    public string Name => "newrelic";

    /// <inheritdoc/>
    public Task SendAsync(Alert alert, ChannelContext context, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(alert);
        ArgumentNullException.ThrowIfNull(context);
        string link = ChannelShared.Link(_link, alert);
        Run? run = alert.Run;
        // Flat attributes only, strings under 4096 characters.
        var e = new JsObject()
            .Set("eventType", _eventType)
            .Set("timestamp", alert.At)
            .Set("job", Post.Cut(alert.Job, 4095))
            .Set("alertType", alert.Type.Value)
            .Set("severity", ChannelShared.Severity(alert.Type))
            .Set("title", Post.Cut(alert.Title, 4095))
            .Set("message", Post.Cut(alert.Message, 4095));
        string triage = ChannelShared.Triage(alert);
        if (triage.Length > 0)
        {
            e.Set("triage", Post.Cut(triage, 4095));
        }
        if (link.Length > 0)
        {
            e.Set("link", Post.Cut(link, 4095));
        }
        if (run != null)
        {
            e.Set("runId", run.Id).Set("runStatus", run.Status.Value);
            if (run.DurationMs != null)
            {
                e.Set("durationMs", run.DurationMs);
            }
        }
        return ChannelShared.SendAsync(
            ChannelShared.Transport(_transport, context),
            "New Relic",
            _url,
            ChannelShared.Headers("content-type", "application/json", "api-key", _apiKey),
            Json.Stringify(new List<object?> { e }),
            [_apiKey],
            cancellationToken);
    }

    /// <summary>Names the channel.</summary>
    public override string ToString() => "NewRelicChannel";
}
