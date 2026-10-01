using System;
using System.Diagnostics;
using System.Threading;
using System.Threading.Tasks;
using Cronwatch.Internal;

namespace Cronwatch.Web;

/// <summary>
/// A job as an HTTP handler, the SDK's <c>job.handler()</c>, for a platform cron that calls a URL
/// (a Kubernetes CronJob with <c>curl</c>, Render, Fly.io, a scheduler in front of Azure Container
/// Apps). Framework-free like the dashboard: <see cref="HandleAsync"/> takes a
/// <see cref="CronwatchRequest"/> and answers a <see cref="CronwatchResponse"/>, and
/// <c>Cronwatch.AspNetCore</c>'s <c>MapCronwatchHandler</c> serves it. Made by
/// <see cref="Job.Handler(Func{JobContext, CronwatchRequest, CancellationToken, Task}, HandlerOptions?)"/>.
/// Safe to share between threads.
/// </summary>
/// <remarks>
/// A request must send <c>Authorization: Bearer &lt;secret&gt;</c> (compared in constant time):
/// the options' secret, else the client's cron secret. With no secret at all it answers 503 and
/// reports it once to the error handler as <c>handler</c>, unless the environment is development
/// or <see cref="HandlerSecret.None"/> (or the client's <see cref="CronSecret.None"/>) lets anyone
/// in; a wrong or missing bearer is 401. Each request it lets in runs the function in the request
/// as a run with the trigger <c>handler</c>, answered with
/// <c>{"ok","job","run","status","durationMs"}</c>, 200 when the run was ok and 500 when it
/// failed, with the error's first line as <c>error</c> for a caller who sent the secret.
/// </remarks>
[DebuggerDisplay("{ToString(),nq}")]
public sealed class Handler
{
    private readonly Job _job;
    private readonly Func<JobContext, CronwatchRequest, CancellationToken, Task<object?>> _fn;
    private readonly string _secret;
    private readonly bool _optedOut;

    internal Handler(Job job, Func<JobContext, CronwatchRequest, CancellationToken, Task<object?>> fn, HandlerOptions options)
    {
        _job = job;
        _fn = fn;
        CronwatchClient cw = job.Client;
        HandlerSecret? own = options.Secret;
        if (own != null && own.Value == null)
        {
            _secret = "";
            _optedOut = true;
        }
        else if (Js.Secret(own?.Value) is { } given)
        {
            // A blank secret falls back to the client's.
            _secret = given;
        }
        else
        {
            _secret = cw.CronSecretValue ?? "";
            _optedOut = cw.SecretOptedOut;
        }
    }

    /// <summary>The job this handler runs.</summary>
    public Job Job => _job;

    /// <summary>
    /// Whether the handler runs the job for a request without a secret: it has none, and was
    /// opted out (<see cref="HandlerSecret.None"/> or the client's <see cref="CronSecret.None"/>) or
    /// the environment is development. An adapter then leaves the request to the app's own
    /// authorization, as an open dashboard is left (<see cref="Routes.IsOpen"/>).
    /// </summary>
    public bool IsOpen => _secret.Length == 0 && (_optedOut || _job.Client.EnvironmentName == "development");

    /// <summary>Names the job, never the secret.</summary>
    public override string ToString() => "Handler(" + _job.Name + ")";

    /// <summary>The SDK's <c>json()</c>: the body, with its type and <c>no-store</c>.</summary>
    private static CronwatchResponse Json(JsObject body, int status) =>
        new CronwatchResponse(status)
            .WithHeader("content-type", "application/json; charset=utf-8")
            .WithHeader("cache-control", "no-store")
            .WithOwnedBody(Js.Utf8(body.ToJson()));

    /// <summary>
    /// Answers one request. The function runs with the request's <paramref name="cancellationToken"/>
    /// linked into the run's, so a request whose client goes away cancels the job as a platform's
    /// timeout would.
    /// </summary>
    public async Task<CronwatchResponse> HandleAsync(CronwatchRequest request, CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(request);
        CronwatchClient cw = _job.Client;
        if (_secret.Length == 0 && !_optedOut && cw.EnvironmentName != "development")
        {
            if (cw.FirstNoSecretRefusal())
            {
                cw.ReportError(
                    new CronwatchException("handler refused a request because no CRON_SECRET is set; pass Secret = HandlerSecret.None to allow unauthenticated requests"),
                    "handler");
            }
            return Json(
                new JsObject().Set("ok", false).Set(
                    "error",
                    "CRON_SECRET is not set, so this job will not run for an unauthenticated request. Set it, or pass Secret = HandlerSecret.None to Handler() to allow anyone."),
                503);
        }
        if (_secret.Length > 0 && !WebText.ConstantTimeEquals(request.Header("authorization") ?? "", "Bearer " + _secret))
        {
            return Json(new JsObject().Set("ok", false).Set("error", "Unauthorized"), 401);
        }
        var (run, value, thrown) = await cw.ExecuteCaughtAsync(
            _job.Def,
            new RunOptions { Trigger = "handler" },
            (ctx, ct) => _fn(ctx, request, ct),
            cancellationToken).ConfigureAwait(false);
#pragma warning disable CS0618 // the former name, kept through 1.x
        if (value is WebResponse former)
        {
            value = (CronwatchResponse)former;
        }
#pragma warning restore CS0618
        if (thrown == null && value is CronwatchResponse answer)
        {
            return answer;
        }
        bool ok = run.Status == RunStatus.Ok;
        JsObject body = new JsObject()
            .Set("ok", ok)
            .Set("job", _job.Name)
            .Set("run", run.Id)
            .Set("status", run.Status.Value)
            .Set("durationMs", run.DurationMs);
        // Error text only goes to a caller who proved they hold the secret.
        if (_secret.Length > 0 && !string.IsNullOrEmpty(run.Error))
        {
            int nl = run.Error.IndexOf('\n', StringComparison.Ordinal);
            body.Set("error", nl < 0 ? run.Error : run.Error[..nl]);
        }
        return Json(body, ok ? 200 : 500);
    }
}
