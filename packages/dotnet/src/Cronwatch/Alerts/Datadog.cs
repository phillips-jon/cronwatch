using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.Threading;
using System.Threading.Tasks;
using Cronwatch.Internal;

namespace Cronwatch.Alerts;

/// <summary>Configures <see cref="DatadogChannel"/>. Its <see cref="ToString"/> never shows the API key.</summary>
[DebuggerDisplay("{ToString(),nq}")]
public sealed class DatadogOptions
{
    /// <summary>A Datadog API key. Trimmed of the spaces and newlines a paste leaves.</summary>
    public string? ApiKey { internal get; init; }

    /// <summary>The Datadog site, <c>datadoghq.eu</c> say. Default <c>datadoghq.com</c>.</summary>
    public string Site { get; init; } = "datadoghq.com";

    /// <summary>Tags added to every event, after CronWatch's own.</summary>
    public IList<string> Tags { get; init; } = new List<string>();

    /// <summary>The event's host, or none.</summary>
    public string? Host { get; init; }

    /// <summary>A link back to the job in your dashboard. Null or <c>""</c> is no link.</summary>
    public Func<Alert, string?>? Link { get; init; }

    /// <summary>Sends this channel's requests; by default the client's transport.</summary>
    public ITransport? Transport { get; init; }

    /// <summary>Names what is set, never the API key.</summary>
    public override string ToString() => "DatadogOptions(apiKey " + ChannelShared.Set(ApiKey) + ", tags " + Tags.Count.ToString(CultureInfo.InvariantCulture) + ")";
}

/// <summary>
/// Posts alerts to the Datadog event stream, aggregated per job and alert type
/// (<c>alerts/datadog.ts</c>): the Events API v1, <c>POST https://api.&lt;site&gt;/api/v1/events</c>
/// with <c>DD-API-KEY</c>.
/// </summary>
public sealed class DatadogChannel : IChannel
{
    private static readonly Dictionary<string, string> AlertTypes = new(StringComparer.Ordinal)
    {
        ["missed"] = "error",
        ["failed"] = "error",
        ["stuck"] = "error",
        ["slow"] = "warning",
        ["over_budget"] = "warning",
        ["recovered"] = "success",
    };

    private readonly string _apiKey;
    private readonly string _url;
    private readonly List<string> _tags;
    private readonly string _host;
    private readonly Func<Alert, string?>? _link;
    private readonly ITransport? _transport;

    /// <summary>The channel.</summary>
    /// <exception cref="CronwatchException">Without an API key, or with a site that is not a host name.</exception>
    public DatadogChannel(DatadogOptions options)
    {
        ArgumentNullException.ThrowIfNull(options);
        _apiKey = ChannelShared.Trimmed(options.ApiKey);
        if (_apiKey.Length == 0)
        {
            throw ChannelShared.Invalid("Datadog needs an ApiKey");
        }
        _url = "https://api." + ReadSite(options.Site ?? "datadoghq.com") + "/api/v1/events";
        _tags = [.. options.Tags ?? []];
        _host = options.Host ?? "";
        _link = options.Link;
        _transport = options.Transport;
    }

    /// <summary>The site without a scheme, an <c>api.</c> or <c>app.</c> in front, or slashes after.</summary>
    private static string ReadSite(string given)
    {
        string site = given;
        if (site.StartsWith("http://", StringComparison.Ordinal))
        {
            site = site[7..];
        }
        else if (site.StartsWith("https://", StringComparison.Ordinal))
        {
            site = site[8..];
        }
        if (site.StartsWith("api.", StringComparison.Ordinal) || site.StartsWith("app.", StringComparison.Ordinal))
        {
            site = site[4..];
        }
        site = site.TrimEnd('/');
        bool ok = site.Length > 0;
        foreach (char c in site)
        {
            ok &= (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '.' || c == '-';
        }
        if (!ok)
        {
            throw ChannelShared.Invalid("Datadog needs a Site like datadoghq.com");
        }
        return site;
    }

    /// <inheritdoc/>
    public string Name => "datadog";

    /// <inheritdoc/>
    public Task SendAsync(Alert alert, ChannelContext context, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(alert);
        ArgumentNullException.ThrowIfNull(context);
        string link = ChannelShared.Link(_link, alert);
        string type = alert.Type.Value;
        var tags = new List<object?> { "cronwatch", "job:" + alert.Job, "alert:" + type };
        foreach (string t in _tags)
        {
            tags.Add(t);
        }
        var e = new JsObject()
            .Set("title", Post.Cut(alert.Title, 500))
            .Set("text", Post.Cut(ChannelShared.PlainText(alert, link), 4000));
        // An unknown type has none, which JSON.stringify leaves out.
        if (AlertTypes.TryGetValue(type, out string? alertType))
        {
            e.Set("alert_type", alertType);
        }
        e
            .Set("aggregation_key", AggregationKey(alert))
            .Set("date_happened", Js.FloorDiv(alert.At, 1000))
            .Set("priority", "normal")
            .Set("tags", tags);
        if (_host.Length > 0)
        {
            e.Set("host", _host);
        }
        return ChannelShared.SendAsync(
            ChannelShared.Transport(_transport, context),
            "Datadog",
            _url,
            ChannelShared.Headers(
                "content-type", "application/json",
                "accept", "application/json",
                "dd-api-key", _apiKey),
            e.ToJson(),
            [_apiKey],
            cancellationToken);
    }

    /// <summary><c>cronwatch:&lt;job&gt;:&lt;type&gt;</c>, or a hash of it when that passes Datadog's 100 characters.</summary>
    internal static string AggregationKey(Alert alert)
    {
        string key = "cronwatch:" + alert.Job + ":" + alert.Type.Value;
        return key.Length <= 100 ? key : "cronwatch:" + ChannelShared.Sha256Hex(key)[..40];
    }

    /// <summary>Names the channel.</summary>
    public override string ToString() => "DatadogChannel";
}
