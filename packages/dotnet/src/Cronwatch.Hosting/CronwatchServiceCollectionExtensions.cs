using System;
using System.Collections.Generic;
using Cronwatch.Web;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.DependencyInjection.Extensions;
using Microsoft.Extensions.Hosting;
using Microsoft.Extensions.Logging;

namespace Cronwatch.Hosting;

/// <summary>CronWatch in a Generic Host or ASP.NET Core app's container.</summary>
public static class CronwatchServiceCollectionExtensions
{
    /// <summary>The configuration section read: <c>Cronwatch:Retention</c>, <c>Cronwatch:Token</c>, <c>Cronwatch:CheckEvery</c>, <c>Cronwatch:Environment</c>.</summary>
    public const string ConfigurationSection = "Cronwatch";

    /// <summary>
    /// Registers <see cref="CronwatchClient"/> as a singleton, disposed when the host stops, with
    /// the options <paramref name="configure"/> sets over the app's configuration, errors and
    /// warnings through the app's <c>ILogger</c>, the host's environment, and a check every
    /// minute as a hosted service once the host has started.
    /// </summary>
    public static IServiceCollection AddCronwatch(this IServiceCollection services, Action<CronwatchHostOptions>? configure = null) =>
        services.AddCronwatch((_, o) => configure?.Invoke(o));

    /// <summary>
    /// As <see cref="AddCronwatch(IServiceCollection, Action{CronwatchHostOptions}?)"/>, for options
    /// that need other services (the app's data source, its channels).
    /// </summary>
    public static IServiceCollection AddCronwatch(this IServiceCollection services, Action<IServiceProvider, CronwatchHostOptions> configure)
    {
        ArgumentNullException.ThrowIfNull(services);
        ArgumentNullException.ThrowIfNull(configure);
        services.TryAddSingleton(sp => Resolve(sp, configure));
        services.TryAddSingleton(sp => sp.GetRequiredService<CronwatchHostOptions>().Client(sp));
        services.TryAddSingleton(sp => new RoutesOptions { Token = sp.GetRequiredService<CronwatchHostOptions>().Token });
        services.AddHostedService<CronwatchCheckService>();
        return services;
    }

    private static CronwatchHostOptions Resolve(IServiceProvider sp, Action<IServiceProvider, CronwatchHostOptions> configure)
    {
        var o = new CronwatchHostOptions();
        IConfigurationSection? section = sp.GetService<IConfiguration>()?.GetSection(ConfigurationSection);
        if (section != null)
        {
            if (section["Retention"] is { Length: > 0 } retention)
            {
                o.Retention = retention;
            }
            if (section["Token"] is { Length: > 0 } token)
            {
                o.Token = token;
            }
            if (section["CheckEvery"] is { Length: > 0 } every)
            {
                o.CheckEvery = every;
            }
            if (section["Environment"] is { Length: > 0 } environment)
            {
                o.Environment = environment;
            }
        }
        configure(sp, o);
        return o;
    }

    private static CronwatchClient Client(this CronwatchHostOptions o, IServiceProvider sp)
    {
        ILogger logger = (ILogger?)sp.GetService<ILoggerFactory>()?.CreateLogger<CronwatchClient>() ?? Microsoft.Extensions.Logging.Abstractions.NullLogger.Instance;
        IList<IChannel> alerts = o.AlertsGiven ? o.Alerts : [.. sp.GetServices<IChannel>()];
        Action<Exception, string> onError = o.OnError ?? ((error, where) => Log.Error(logger, where, error));
        Action<string> onWarning = o.OnWarning ?? (message => Log.Warning(logger, message));
        TimeProvider? clock = o.Clock ?? sp.GetService<TimeProvider>();
        // CronWatch's own variables come first; this is read only when none of them is set.
        string? environment = o.Environment ?? sp.GetService<IHostEnvironment>()?.EnvironmentName;
        Duration retention = o.Retention ?? "30d";
        // Alerts left untouched send to the console; set, even empty, they are the channels.
        CronwatchOptions options = alerts.Count > 0
            ? new CronwatchOptions
            {
                Store = o.Store,
                Alerts = alerts,
                Triage = o.Triage,
                Sources = o.Sources,
                CronSecret = o.CronSecret,
                Retention = retention,
                Defaults = o.Defaults,
                Redact = o.Redact,
                Deliver = o.Deliver,
                OnError = onError,
                OnWarning = onWarning,
                Clock = clock,
                ProcessExitHook = o.ProcessExitHook,
                Environment = environment,
            }
            : new CronwatchOptions
            {
                Store = o.Store,
                Triage = o.Triage,
                Sources = o.Sources,
                CronSecret = o.CronSecret,
                Retention = retention,
                Defaults = o.Defaults,
                Redact = o.Redact,
                Deliver = o.Deliver,
                OnError = onError,
                OnWarning = onWarning,
                Clock = clock,
                ProcessExitHook = o.ProcessExitHook,
                Environment = environment,
            };
        return new CronwatchClient(options);
    }
}

/// <summary>The client's lines through <c>ILogger</c>.</summary>
internal static partial class Log
{
    [LoggerMessage(EventId = 1, Level = LogLevel.Error, Message = "[cronwatch] {Where}")]
    public static partial void Error(ILogger logger, string where, Exception error);

    [LoggerMessage(EventId = 2, Level = LogLevel.Warning, Message = "{Message}")]
    public static partial void Warning(ILogger logger, string message);
}
