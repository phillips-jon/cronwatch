using System;
using Microsoft.Extensions.DependencyInjection;

namespace Cronwatch.Hosting;

/// <summary>
/// <c>AddCronwatch</c>'s former class. The method is in
/// <c>Microsoft.Extensions.DependencyInjection</c> now, as Microsoft's own registration methods
/// are, so <c>services.AddCronwatch(...)</c> needs no <c>using</c>; these are plain static
/// methods, not extensions, so they never make a call ambiguous.
/// </summary>
[Obsolete("AddCronwatch is in Microsoft.Extensions.DependencyInjection now; call it as services.AddCronwatch(...). This class still works through 1.x and goes in 2.0.")]
public static class CronwatchServiceCollectionExtensions
{
    /// <summary>The configuration section read.</summary>
    public const string ConfigurationSection = Microsoft.Extensions.DependencyInjection.CronwatchHostingServiceCollectionExtensions.ConfigurationSection;

    /// <summary><c>services.AddCronwatch(configure)</c>.</summary>
    public static IServiceCollection AddCronwatch(IServiceCollection services, Action<CronwatchHostOptions>? configure = null) =>
        Microsoft.Extensions.DependencyInjection.CronwatchHostingServiceCollectionExtensions.AddCronwatch(services, configure);

    /// <summary><c>services.AddCronwatch(configure)</c>.</summary>
    public static IServiceCollection AddCronwatch(IServiceCollection services, Action<IServiceProvider, CronwatchHostOptions> configure) =>
        Microsoft.Extensions.DependencyInjection.CronwatchHostingServiceCollectionExtensions.AddCronwatch(services, configure);
}
