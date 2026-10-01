using System;
using System.Diagnostics;

namespace Cronwatch.Web;

/// <summary>
/// The token the dashboard asks for: a string converts implicitly, <see cref="None"/> serves the
/// dashboard open behind the app's own sign-in, and leaving the option unset reads
/// <c>CRONWATCH_TOKEN</c>. Never printed.
/// </summary>
[DebuggerDisplay("DashboardToken")]
public sealed class DashboardToken
{
    private DashboardToken(string? value)
    {
        Value = value;
    }

    /// <summary>No token: the dashboard is open to anyone who reaches it (the SDK's <c>token: null</c>).</summary>
    public static DashboardToken None { get; } = new(null);

    internal string? Value { get; }

    /// <summary>A token. <c>""</c>, or one of only whitespace, counts as unset.</summary>
    public static implicit operator DashboardToken(string token) => new(token ?? throw new ArgumentNullException(nameof(token)));

    /// <summary>Says whether a token is set, never its value.</summary>
    public override string ToString() => Value == null ? "DashboardToken(none)" : "DashboardToken(set)";
}

/// <summary>
/// How <see cref="Routes"/> serve the dashboard: the SDK's <c>RoutesOptions</c>, with the token in
/// three ways (<see cref="Token"/> given, <see cref="DashboardToken.None"/>, or neither for
/// <c>CRONWATCH_TOKEN</c>). <see cref="ToString"/> says whether a token is set, never the token.
/// </summary>
[DebuggerDisplay("{ToString(),nq}")]
public sealed class RoutesOptions
{
    /// <summary>
    /// The token the dashboard asks for. Send it as <c>Authorization: Bearer &lt;token&gt;</c>, or
    /// open the dashboard once with <c>?token=&lt;token&gt;</c> and a cookie is set. Unset, it is
    /// <c>CRONWATCH_TOKEN</c>; <c>""</c>, or one of only whitespace, given here or in the variable, counts as unset. With no token in development the routes
    /// make a random one and print a sign-in link to standard output on their first request; with
    /// no token otherwise they answer 503. <c>/api/check</c> also takes the client's cron secret as
    /// a bearer, so a platform cron can run checks without the token.
    /// </summary>
    public DashboardToken? Token { internal get; init; }

    /// <summary>
    /// Where the dashboard is mounted (<c>""</c> for the root), so its links resolve. Unset, it is
    /// where an adapter finds the dashboard mounted, else <c>/cronwatch</c>.
    /// </summary>
    public string? BasePath { get; init; }

    /// <summary>
    /// The public origin the dashboard is served from, such as <c>https://app.example.com</c>, for
    /// an app behind a proxy whose requests carry an internal host or scheme. It stands in for the
    /// request's own origin in the cross-site check on writes, the sign-in cookie's <c>Secure</c>
    /// flag, the Referer the redirect back after a form follows, and the development sign-in line.
    /// Anything that is not an http or https URL is refused when the routes are made. It takes
    /// precedence over <see cref="TrustProxy"/>.
    /// </summary>
    public string? Origin { get; init; }

    /// <summary>
    /// Takes the public origin from <c>X-Forwarded-Proto</c> and <c>X-Forwarded-Host</c> (the first
    /// value of each, the request's own scheme or host for whichever is missing) when a request
    /// carries either. Only for an app whose proxy sets or overwrites both headers: a client can
    /// send them too.
    /// </summary>
    public bool TrustProxy { get; init; }

    /// <summary>Says whether a token is set, never the token, and the origin without any credentials in it.</summary>
    public override string ToString() =>
        "RoutesOptions(token " + (Token == null ? "CRONWATCH_TOKEN" : Token.Value == null ? "none" : "set")
        + (BasePath == null ? "" : ", basePath " + BasePath)
        + (Origin == null ? "" : ", origin " + (Internal.Origins.Bare(Origin) ?? "set"))
        + (TrustProxy ? ", trustProxy" : "") + ")";
}

/// <summary>
/// The secret a job's handler requires (<c>Authorization: Bearer &lt;secret&gt;</c>) in place of
/// the client's cron secret: a string converts implicitly, and <see cref="None"/> lets anyone run
/// the job. Never printed.
/// </summary>
[DebuggerDisplay("HandlerSecret")]
public sealed class HandlerSecret
{
    private HandlerSecret(string? value)
    {
        Value = value;
    }

    /// <summary>No secret: anyone may run the job through the handler (the SDK's <c>secret: null</c>).</summary>
    public static HandlerSecret None { get; } = new(null);

    internal string? Value { get; }

    /// <summary>A secret. <c>""</c>, or one of only whitespace, counts as unset.</summary>
    public static implicit operator HandlerSecret(string secret) => new(secret ?? throw new ArgumentNullException(nameof(secret)));

    /// <summary>Says whether a secret is set, never its value.</summary>
    public override string ToString() => Value == null ? "HandlerSecret(none)" : "HandlerSecret(set)";
}

/// <summary>
/// How a <see cref="Handler"/> checks its requests: the SDK's <c>HandlerOptions</c>, with the
/// secret in three ways (<see cref="Secret"/> given, <see cref="HandlerSecret.None"/>, or neither
/// for the client's cron secret). <see cref="ToString"/> never shows the secret.
/// </summary>
[DebuggerDisplay("{ToString(),nq}")]
public sealed class HandlerOptions
{
    /// <summary>
    /// The secret the handler's requests must carry, in place of the client's cron secret
    /// (<c>CRON_SECRET</c> by default). <c>""</c>, or one of only whitespace, counts as unset.
    /// </summary>
    public HandlerSecret? Secret { internal get; init; }

    /// <summary>Says whether a secret is set, never the secret.</summary>
    public override string ToString() =>
        "HandlerOptions(secret " + (Secret == null ? "the client's" : Secret.Value == null ? "none" : "set") + ")";
}
