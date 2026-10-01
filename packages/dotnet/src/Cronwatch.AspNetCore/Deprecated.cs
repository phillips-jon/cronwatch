using System;
using System.Threading;
using System.Threading.Tasks;
using Cronwatch.Web;
using Microsoft.AspNetCore.Builder;
using Microsoft.AspNetCore.Http;
using Microsoft.AspNetCore.Routing;

namespace Cronwatch.AspNetCore;

/// <summary>
/// The former class of <c>MapCronwatch</c>, <c>UseCronwatch</c> and <c>MapCronwatchHandler</c>,
/// which are in <c>Microsoft.AspNetCore.Builder</c> now (<see cref="CronwatchAspNetCoreExtensions"/>),
/// as <c>MapHealthChecks</c> is, so they need no <c>using</c>. These are plain static methods, not
/// extensions, so they never make a call ambiguous.
/// </summary>
[Obsolete("MapCronwatch, UseCronwatch and MapCronwatchHandler are in Microsoft.AspNetCore.Builder now; call them as app.MapCronwatch(...). This class still works through 1.x and goes in 2.0.")]
public static class CronwatchAspNetCore
{
    /// <summary><c>endpoints.MapCronwatch(pattern, options)</c>.</summary>
    public static IEndpointConventionBuilder MapCronwatch(IEndpointRouteBuilder endpoints, string pattern = Routes.DefaultBasePath, RoutesOptions? options = null) =>
        CronwatchAspNetCoreExtensions.MapCronwatch(endpoints, pattern, options);

    /// <summary><c>endpoints.MapCronwatch(pattern, routes)</c>.</summary>
    public static IEndpointConventionBuilder MapCronwatch(IEndpointRouteBuilder endpoints, string pattern, Routes routes) =>
        CronwatchAspNetCoreExtensions.MapCronwatch(endpoints, pattern, routes);

    /// <summary><c>app.UseCronwatch(path, options)</c>.</summary>
    public static IApplicationBuilder UseCronwatch(IApplicationBuilder app, string path = Routes.DefaultBasePath, RoutesOptions? options = null) =>
        CronwatchAspNetCoreExtensions.UseCronwatch(app, path, options);

    /// <summary><c>app.UseCronwatch(path, routes)</c>.</summary>
    public static IApplicationBuilder UseCronwatch(IApplicationBuilder app, string path, Routes routes) =>
        CronwatchAspNetCoreExtensions.UseCronwatch(app, path, routes);

    /// <summary><c>endpoints.MapCronwatchHandler(pattern, job, fn, options)</c>.</summary>
    public static IEndpointConventionBuilder MapCronwatchHandler(IEndpointRouteBuilder endpoints, string pattern, Job job, Func<JobContext, HttpContext, CancellationToken, Task> fn, HandlerOptions? options = null) =>
        CronwatchAspNetCoreExtensions.MapCronwatchHandler(endpoints, pattern, job, fn, options);

    /// <summary><c>endpoints.MapCronwatchHandler(pattern, job, fn, options)</c>.</summary>
    public static IEndpointConventionBuilder MapCronwatchHandler<T>(IEndpointRouteBuilder endpoints, string pattern, Job job, Func<JobContext, HttpContext, CancellationToken, Task<T>> fn, HandlerOptions? options = null) =>
        CronwatchAspNetCoreExtensions.MapCronwatchHandler(endpoints, pattern, job, fn, options);

    /// <summary><c>endpoints.MapCronwatchHandler(pattern, jobName, fn, options)</c>.</summary>
    public static IEndpointConventionBuilder MapCronwatchHandler(IEndpointRouteBuilder endpoints, string pattern, string jobName, Func<JobContext, HttpContext, CancellationToken, Task> fn, HandlerOptions? options = null) =>
        CronwatchAspNetCoreExtensions.MapCronwatchHandler(endpoints, pattern, jobName, fn, options);

    /// <summary><c>endpoints.MapCronwatchHandler(pattern, jobName, fn, options)</c>.</summary>
    public static IEndpointConventionBuilder MapCronwatchHandler<T>(IEndpointRouteBuilder endpoints, string pattern, string jobName, Func<JobContext, HttpContext, CancellationToken, Task<T>> fn, HandlerOptions? options = null) =>
        CronwatchAspNetCoreExtensions.MapCronwatchHandler(endpoints, pattern, jobName, fn, options);
}
