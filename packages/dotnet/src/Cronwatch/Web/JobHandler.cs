using System;
using System.Threading;
using System.Threading.Tasks;
using Cronwatch.Web;

namespace Cronwatch;

/// <summary>A job as an HTTP handler.</summary>
public sealed partial class Job
{
    /// <summary>
    /// The job as an HTTP handler, the SDK's <c>job.handler()</c>: each request with the secret
    /// runs <paramref name="fn"/> as a recorded run with the trigger <c>handler</c> (see
    /// <see cref="Web.Handler"/>).
    /// </summary>
    public Handler Handler(Func<JobContext, WebRequest, CancellationToken, Task> fn, HandlerOptions? options = null)
    {
        ArgumentNullException.ThrowIfNull(fn);
        return new Handler(
            this,
            async (job, request, ct) =>
            {
                await fn(job, request, ct).ConfigureAwait(false);
                return null;
            },
            options ?? new HandlerOptions());
    }

    /// <summary>
    /// The job as an HTTP handler whose function answers a value: a string is the run's output
    /// when nothing was logged, and a <see cref="WebResponse"/> is the handler's answer, which
    /// fails the run at 400 or more.
    /// </summary>
    public Handler Handler<T>(Func<JobContext, WebRequest, CancellationToken, Task<T>> fn, HandlerOptions? options = null)
    {
        ArgumentNullException.ThrowIfNull(fn);
        return new Handler(this, async (job, request, ct) => await fn(job, request, ct).ConfigureAwait(false), options ?? new HandlerOptions());
    }
}
