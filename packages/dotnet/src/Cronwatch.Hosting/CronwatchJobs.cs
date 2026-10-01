using System;
using System.Diagnostics.CodeAnalysis;
using Cronwatch;
using Cronwatch.Hosting;
using Microsoft.Extensions.DependencyInjection.Extensions;
using Microsoft.Extensions.Hosting;

namespace Microsoft.Extensions.DependencyInjection;

/// <summary><c>AddCronwatchJob</c>: jobs on a schedule inside the host, watched on that same schedule.</summary>
public static class CronwatchJobServiceCollectionExtensions
{
    /// <summary>
    /// Runs <typeparamref name="TJob"/> at the fire times of <paramref name="options"/>'s schedule
    /// (a cron, or <c>every 5m</c>), each fire a recorded run of the job <paramref name="name"/>
    /// with the trigger <c>hosting</c>, so the schedule it runs on and the one CronWatch watches
    /// are one definition. A fire that comes while the job's previous run is still going is
    /// skipped, and written to the log once per run it waited on. It is a scheduler for one
    /// process: every replica of a service runs its hosted jobs, so a job that must run once
    /// across a cluster belongs in Hangfire or Quartz with a shared store. The client is the
    /// container's <see cref="CronwatchClient"/> (<c>AddCronwatch</c>); a bad name or schedule
    /// stops the host from starting, with the SDK's message.
    /// </summary>
    public static IServiceCollection AddCronwatchJob<[DynamicallyAccessedMembers(DynamicallyAccessedMemberTypes.PublicConstructors)] TJob>(this IServiceCollection services, string name, JobOptions options)
        where TJob : class, ICronwatchJob
    {
        ArgumentNullException.ThrowIfNull(services);
        ArgumentNullException.ThrowIfNull(name);
        ArgumentNullException.ThrowIfNull(options);
        if (string.IsNullOrEmpty(options.Schedule))
        {
            throw new ArgumentException("AddCronwatchJob needs a schedule for " + name, nameof(options));
        }
        services.TryAddScoped<TJob>();
        services.AddSingleton(new HostedJob(name, options, typeof(TJob), static sp => sp.GetRequiredService<TJob>()));
        services.TryAddEnumerable(ServiceDescriptor.Singleton<IHostedService, HostedJobs>());
        return services;
    }
}
