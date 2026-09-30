using System.Diagnostics;
using System.Diagnostics.Metrics;

namespace Cronwatch;

/// <summary>
/// CronWatch's telemetry, from the shared framework: an <see cref="ActivitySource"/> and a
/// <see cref="Meter"/> both named <c>Cronwatch</c>. An OpenTelemetry app adds
/// <c>.AddSource("Cronwatch")</c> and <c>.AddMeter("Cronwatch")</c>.
/// </summary>
public static class CronwatchTelemetry
{
    /// <summary>The name of the activity source and the meter.</summary>
    public const string Name = "Cronwatch";

    internal static readonly ActivitySource Source = new(Name, CronwatchClient.Version);

    internal static readonly Meter Meter = new(Name, CronwatchClient.Version);

    /// <summary>Runs recorded, by job and status.</summary>
    internal static readonly Counter<long> Runs = Meter.CreateCounter<long>("cronwatch.runs", description: "Runs recorded, by job and status");

    /// <summary>Alerts, by channel, type and outcome.</summary>
    internal static readonly Counter<long> Alerts = Meter.CreateCounter<long>("cronwatch.alerts", description: "Alerts, by channel, type and outcome");

    /// <summary>Checks run.</summary>
    internal static readonly Counter<long> Checks = Meter.CreateCounter<long>("cronwatch.checks", description: "Checks run");

    /// <summary>How long runs took.</summary>
    internal static readonly Histogram<double> RunDuration = Meter.CreateHistogram<double>("cronwatch.run.duration", unit: "ms", description: "How long runs took");
}
