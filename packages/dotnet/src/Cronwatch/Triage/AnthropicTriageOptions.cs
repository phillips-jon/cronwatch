using System.Diagnostics;
using System.Globalization;
using Cronwatch.Alerts;

namespace Cronwatch.Triage;

/// <summary>
/// Configures <see cref="AnthropicTriage"/>: the SDK's <c>AnthropicTriageOptions</c>, every option
/// with the SDK's default. Nothing here is printed by <see cref="ToString"/> but what is set.
/// </summary>
[DebuggerDisplay("{ToString(),nq}")]
public sealed class AnthropicTriageOptions
{
    /// <summary>
    /// The API key. Default <c>ANTHROPIC_API_KEY</c>, read each time triage runs; trimmed of the
    /// spaces and newlines a paste leaves. Never printed.
    /// </summary>
    public string? ApiKey { internal get; init; }

    /// <summary>The model. Default <c>claude-opus-5</c>.</summary>
    public string Model { get; init; } = AnthropicTriage.DefaultModel;

    /// <summary>How hard the model thinks: <c>low</c>, <c>medium</c> or <c>high</c>. Default <c>medium</c>; a stack trace rarely needs more.</summary>
    public string Effort { get; init; } = AnthropicTriage.DefaultEffort;

    /// <summary>The most tokens a diagnosis may use. Default 800; any other value (0 included) is sent as given.</summary>
    public long MaxTokens { get; init; } = AnthropicTriage.DefaultMaxTokens;

    /// <summary>
    /// Whether a policy refusal is routed to Anthropic's default fallback model inside the same
    /// request, so a diagnosis still comes back. Default true; false for an account or gateway
    /// that rejects the beta.
    /// </summary>
    public bool Fallbacks { get; init; } = true;

    /// <summary>
    /// Anything the model should know about this app: "An ASP.NET Core service on Kubernetes with
    /// a Postgres database." Not printed, since it may describe the app.
    /// </summary>
    public string? Context { internal get; init; }

    /// <summary>
    /// Where the API is. Default <c>ANTHROPIC_BASE_URL</c>, read each time triage runs, else
    /// <c>https://api.anthropic.com</c>. Not printed, since a gateway's URL may carry a credential.
    /// </summary>
    public string? BaseUrl { internal get; init; }

    /// <summary>Sends the request. Default: the client's transport.</summary>
    public ITransport? Transport { get; init; }

    /// <summary>Names what is set, never the API key, the context or the base URL.</summary>
    public override string ToString() =>
        "AnthropicTriageOptions(apiKey " + (string.IsNullOrEmpty(ApiKey) ? "from ANTHROPIC_API_KEY" : "set")
        + ", model " + Model
        + ", effort " + Effort
        + ", maxTokens " + MaxTokens.ToString(CultureInfo.InvariantCulture)
        + ", fallbacks " + (Fallbacks ? "on" : "off") + ")";
}
