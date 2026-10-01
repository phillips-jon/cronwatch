using System;
using System.Collections.Generic;
using System.IO;
using System.Runtime.CompilerServices;
using System.Threading;
using System.Threading.Tasks;
using Cronwatch.Web;
using Microsoft.AspNetCore.Builder;
using Microsoft.AspNetCore.Http;
using Microsoft.AspNetCore.Http.Features;
using Microsoft.AspNetCore.Routing;
using Microsoft.Extensions.DependencyInjection;

namespace Cronwatch.AspNetCore;

/// <summary>
/// The dashboard and a job's handler on ASP.NET Core: <see cref="MapCronwatch(IEndpointRouteBuilder, string, RoutesOptions?)"/>
/// on endpoint routing, <see cref="UseCronwatch(IApplicationBuilder, string, RoutesOptions?)"/> as
/// middleware, and <see cref="MapCronwatchHandler(IEndpointRouteBuilder, string, Job, Func{JobContext, HttpContext, CancellationToken, Task}, HandlerOptions?)"/>
/// for a platform cron. The client is the app's <see cref="CronwatchClient"/> singleton
/// (<c>AddCronwatch</c>).
/// </summary>
public static class CronwatchAspNetCore
{
    private const string Rest = "cronwatchRest";

    /// <summary>
    /// Maps the dashboard at <paramref name="pattern"/> and everything beneath it, for every
    /// method. The endpoints skip antiforgery (the dashboard has its own cross-site check) and are
    /// left out of OpenAPI documents. While the dashboard has a token they allow anonymous
    /// requests, so an app whose fallback policy requires a signed-in user still reaches the
    /// dashboard's own sign-in; an open dashboard (<see cref="DashboardToken.None"/>) takes the
    /// app's authorization policy. Inside a route group the base path is the group's.
    /// </summary>
    /// <param name="endpoints">The app.</param>
    /// <param name="pattern">Where the dashboard is. Default <c>/cronwatch</c>.</param>
    /// <param name="options">The routes' options. Default: the container's <see cref="RoutesOptions"/>, else the defaults.</param>
    public static IEndpointConventionBuilder MapCronwatch(this IEndpointRouteBuilder endpoints, string pattern = Routes.DefaultBasePath, RoutesOptions? options = null)
    {
        ArgumentNullException.ThrowIfNull(endpoints);
        return endpoints.MapCronwatch(pattern, MakeRoutes(endpoints.ServiceProvider, options));
    }

    /// <summary>Maps these routes at <paramref name="pattern"/>, as <see cref="MapCronwatch(IEndpointRouteBuilder, string, RoutesOptions?)"/> does.</summary>
    public static IEndpointConventionBuilder MapCronwatch(this IEndpointRouteBuilder endpoints, string pattern, Routes routes)
    {
        ArgumentNullException.ThrowIfNull(endpoints);
        ArgumentNullException.ThrowIfNull(pattern);
        ArgumentNullException.ThrowIfNull(routes);
        RouteGroupBuilder group = endpoints.MapGroup(pattern);
        RequestDelegate serve = context => ServeAsync(context, routes.HandleAsync, MountOf(context));
        group.Map("", serve);
        group.Map("{**" + Rest + "}", serve);
        group.DisableAntiforgery();
        group.ExcludeFromDescription();
        if (!routes.IsOpen)
        {
            group.AllowAnonymous();
        }
        return group;
    }

    /// <summary>
    /// The dashboard as middleware at <paramref name="path"/>, ahead of whatever follows it: a
    /// branch answering everything under the path (its base path the branch's) and passing every
    /// other request on. For an app that wants the dashboard ahead of its other middleware, or
    /// has no endpoint routing. A branch is no endpoint, so the app's authorization reaches an open
    /// dashboard (<see cref="DashboardToken.None"/>) only when it runs ahead of the branch: call
    /// <c>UseAuthentication</c> and <c>UseAuthorization</c>, with a fallback policy, before this, or
    /// use <see cref="MapCronwatch(IEndpointRouteBuilder, string, RoutesOptions?)"/>.
    /// </summary>
    public static IApplicationBuilder UseCronwatch(this IApplicationBuilder app, string path = Routes.DefaultBasePath, RoutesOptions? options = null)
    {
        ArgumentNullException.ThrowIfNull(app);
        return app.UseCronwatch(path, MakeRoutes(app.ApplicationServices, options));
    }

    /// <summary>These routes as middleware at <paramref name="path"/>.</summary>
    public static IApplicationBuilder UseCronwatch(this IApplicationBuilder app, string path, Routes routes)
    {
        ArgumentNullException.ThrowIfNull(app);
        ArgumentNullException.ThrowIfNull(path);
        ArgumentNullException.ThrowIfNull(routes);
        return app.Map(path, branch => branch.Run(context => ServeAsync(context, routes.HandleAsync, context.Request.PathBase.Value ?? "")));
    }

    /// <summary>
    /// Maps a job's handler at <paramref name="pattern"/> for every method: each request with the
    /// secret runs <paramref name="fn"/> as a recorded run with the trigger <c>handler</c> (see
    /// <see cref="Handler"/>), with the request's <c>RequestAborted</c> linked into the run's token.
    /// The endpoint skips antiforgery and is left out of OpenAPI documents. While the handler has a
    /// secret it allows anonymous requests, the bearer being its guard; a handler open to anyone
    /// (<see cref="Handler.IsOpen"/>) takes the app's authorization policy.
    /// </summary>
    public static IEndpointConventionBuilder MapCronwatchHandler(
        this IEndpointRouteBuilder endpoints,
        string pattern,
        Job job,
        Func<JobContext, HttpContext, CancellationToken, Task> fn,
        HandlerOptions? options = null)
    {
        ArgumentNullException.ThrowIfNull(job);
        ArgumentNullException.ThrowIfNull(fn);
        return endpoints.MapHandler(pattern, job.Handler((ctx, request, ct) => fn(ctx, ContextOf(request), ct), options));
    }

    /// <summary>
    /// As <see cref="MapCronwatchHandler(IEndpointRouteBuilder, string, Job, Func{JobContext, HttpContext, CancellationToken, Task}, HandlerOptions?)"/>,
    /// for a function that answers a value: a string is the run's output when nothing was logged,
    /// and an <see cref="IResult"/> is the answer, which fails the run when its status is 400 or more.
    /// </summary>
    public static IEndpointConventionBuilder MapCronwatchHandler<T>(
        this IEndpointRouteBuilder endpoints,
        string pattern,
        Job job,
        Func<JobContext, HttpContext, CancellationToken, Task<T>> fn,
        HandlerOptions? options = null)
    {
        ArgumentNullException.ThrowIfNull(job);
        ArgumentNullException.ThrowIfNull(fn);
        return endpoints.MapHandler(pattern, job.Handler<object?>(async (ctx, request, ct) => Answer(await fn(ctx, ContextOf(request), ct).ConfigureAwait(false)), options));
    }

    /// <summary>
    /// As <see cref="MapCronwatchHandler(IEndpointRouteBuilder, string, Job, Func{JobContext, HttpContext, CancellationToken, Task}, HandlerOptions?)"/>,
    /// for a job declared on the app's client by name.
    /// </summary>
    /// <exception cref="InvalidOperationException">When no job of that name is declared.</exception>
    public static IEndpointConventionBuilder MapCronwatchHandler(
        this IEndpointRouteBuilder endpoints,
        string pattern,
        string jobName,
        Func<JobContext, HttpContext, CancellationToken, Task> fn,
        HandlerOptions? options = null)
    {
        ArgumentNullException.ThrowIfNull(endpoints);
        return endpoints.MapCronwatchHandler(pattern, Declared(endpoints.ServiceProvider, jobName), fn, options);
    }

    /// <summary>As the overload by name, for a function that answers a value.</summary>
    /// <exception cref="InvalidOperationException">When no job of that name is declared.</exception>
    public static IEndpointConventionBuilder MapCronwatchHandler<T>(
        this IEndpointRouteBuilder endpoints,
        string pattern,
        string jobName,
        Func<JobContext, HttpContext, CancellationToken, Task<T>> fn,
        HandlerOptions? options = null)
    {
        ArgumentNullException.ThrowIfNull(endpoints);
        return endpoints.MapCronwatchHandler(pattern, Declared(endpoints.ServiceProvider, jobName), fn, options);
    }

    private static Job Declared(IServiceProvider services, string jobName)
    {
        ArgumentNullException.ThrowIfNull(jobName);
        return services.GetRequiredService<CronwatchClient>().DeclaredJob(jobName)
            ?? throw new InvalidOperationException("MapCronwatchHandler: job \"" + jobName + "\" is not declared; call Job() on the client first");
    }

    private static IEndpointConventionBuilder MapHandler(this IEndpointRouteBuilder endpoints, string pattern, Handler handler)
    {
        ArgumentNullException.ThrowIfNull(endpoints);
        ArgumentNullException.ThrowIfNull(pattern);
        IEndpointConventionBuilder built = endpoints.Map(pattern, context => ServeAsync(context, handler.HandleAsync, null));
        built.DisableAntiforgery();
        built.ExcludeFromDescription();
        // Anonymous to the app's authorization only while the bearer is the guard: a handler open
        // to anyone takes the app's policy, so it never opens a job the app's sign-in would refuse.
        if (!handler.IsOpen)
        {
            built.AllowAnonymous();
        }
        return built;
    }

    /// <summary>An <see cref="IResult"/> carried through the handler; anything else as it is.</summary>
    private static object? Answer(object? value) =>
        value is IResult result ? CronwatchResponse.Carrying(result, (result as IStatusCodeHttpResult)?.StatusCode ?? StatusCodes.Status200OK) : value;

    private static HttpContext ContextOf(CronwatchRequest request) =>
        Contexts.TryGetValue(request, out HttpContext? context) ? context : throw new InvalidOperationException("the request did not come through Cronwatch.AspNetCore");

    // The HttpContext each request came with, for a handler's function; held weakly, so a
    // request's context goes with it.
    private static readonly ConditionalWeakTable<CronwatchRequest, HttpContext> Contexts = [];

    private static Routes MakeRoutes(IServiceProvider services, RoutesOptions? options) =>
        services.GetRequiredService<CronwatchClient>().Routes(options ?? services.GetService<RoutesOptions>() ?? new RoutesOptions());

    /// <summary>
    /// Where the dashboard is mounted for this request: the path base and the part of the path
    /// the catch-all did not take.
    /// </summary>
    private static string MountOf(HttpContext context)
    {
        string path = context.Request.Path.Value ?? "";
        string rest = context.Request.RouteValues[Rest] as string ?? "";
        string prefix = rest.Length > 0 && path.EndsWith(rest, StringComparison.Ordinal) ? path[..^rest.Length] : path;
        return (context.Request.PathBase.Value ?? "") + prefix.TrimEnd('/');
    }

    /// <summary>The request as a <see cref="CronwatchRequest"/>, its body read only when a route wants it.</summary>
    internal static CronwatchRequest RequestOf(HttpContext context, string? mount)
    {
        HttpRequest http = context.Request;
        string raw = context.Features.Get<IHttpRequestFeature>()?.RawTarget is { Length: > 0 } t
            ? t
            : (http.PathBase + http.Path + http.QueryString).ToString();
        var headers = new List<KeyValuePair<string, string>>();
        foreach (var h in http.Headers)
        {
            string name = h.Key.ToLowerInvariant();
            foreach (string? v in h.Value)
            {
                headers.Add(new(name, v ?? ""));
            }
        }
        var request = new CronwatchRequest(http.Method, Adapters.Target(raw))
        {
            Headers = headers,
            IsTls = http.IsHttps,
            Mount = mount,
            DeclaredLength = http.ContentLength,
            BodyReader = (limit, ct) => ReadBodyAsync(context, limit, ct),
        };
        Contexts.AddOrUpdate(request, context);
        return request;
    }

    /// <summary>
    /// Reads at most <paramref name="limit"/> bytes and one more. A form something ahead of the
    /// dashboard already read (<c>ReadFormAsync</c>, <c>Request.Form</c>) leaves nothing to read,
    /// and is then taken from the parsed form.
    /// </summary>
    private static async Task<byte[]> ReadBodyAsync(HttpContext context, int limit, CancellationToken ct)
    {
        var buffer = new System.Buffers.ArrayBufferWriter<byte>();
        Stream body = context.Request.Body;
        while (buffer.WrittenCount <= limit)
        {
            Memory<byte> chunk = buffer.GetMemory(Math.Min(16 * 1024, limit + 1 - buffer.WrittenCount));
            int n = await body.ReadAsync(chunk[..Math.Min(chunk.Length, limit + 1 - buffer.WrittenCount)], ct).ConfigureAwait(false);
            if (n == 0)
            {
                break;
            }
            buffer.Advance(n);
        }
        if (buffer.WrittenCount == 0 && context.Features.Get<IFormFeature>()?.Form is { } form)
        {
            var fields = new List<KeyValuePair<string, string>>();
            foreach (var f in form)
            {
                foreach (string? v in f.Value)
                {
                    fields.Add(new(f.Key, v ?? ""));
                }
            }
            return Adapters.FormBody(fields);
        }
        return buffer.WrittenSpan.ToArray();
    }

    /// <summary>Answers a request through <paramref name="handle"/>; a client that went away reports nothing.</summary>
    private static async Task ServeAsync(HttpContext context, Func<CronwatchRequest, CancellationToken, Task<CronwatchResponse>> handle, string? mount)
    {
        CancellationToken aborted = context.RequestAborted;
        CronwatchResponse answer;
        try
        {
            answer = await handle(RequestOf(context, mount), aborted).ConfigureAwait(false);
        }
        catch (OperationCanceledException) when (aborted.IsCancellationRequested)
        {
            return;
        }
        try
        {
            if (answer.Result is IResult result)
            {
                await result.ExecuteAsync(context).ConfigureAwait(false);
                return;
            }
            await WriteAsync(context, answer, aborted).ConfigureAwait(false);
        }
        catch (Exception e) when (aborted.IsCancellationRequested && e is OperationCanceledException or IOException)
        {
            // The client went away before its answer was written: nothing to report.
        }
    }

    /// <summary>Writes an answer with its <c>content-length</c>, so it is never framed as chunked.</summary>
    internal static async Task WriteAsync(HttpContext context, CronwatchResponse answer, CancellationToken ct)
    {
        HttpResponse response = context.Response;
        response.StatusCode = answer.Status;
        foreach (var h in answer.Headers)
        {
            response.Headers.Append(h.Key, h.Value);
        }
        response.ContentLength = answer.Body.Length;
        if (answer.Body.Length > 0 && !HttpMethods.IsHead(context.Request.Method))
        {
            await response.Body.WriteAsync(answer.Body, ct).ConfigureAwait(false);
        }
    }
}
