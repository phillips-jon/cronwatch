using System;
using System.Collections.Generic;
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

    // An app's activity or meter listener runs inside these calls and may throw. What it throws
    // is its own: it must not stop a run's function, leave a run running or replace what the
    // function answered, so each call below drops it, as a failing log line is dropped.

    /// <summary>Starts an activity, or answers null when none is listened to or a listener throws.</summary>
    internal static Activity? StartActivity(string name)
    {
        try
        {
            return Source.StartActivity(name);
        }
        catch (Exception)
        {
            return null;
        }
    }

    /// <summary>Stops an activity, dropping what a listener throws.</summary>
    internal static void StopActivity(Activity? activity)
    {
        if (activity == null)
        {
            return;
        }
        try
        {
            activity.Dispose();
        }
        catch (Exception)
        {
            // The listener's own failure.
        }
    }

    /// <summary>Adds to a counter, dropping what a listener throws.</summary>
    internal static void Add(Counter<long> counter, KeyValuePair<string, object?> tag1 = default, KeyValuePair<string, object?> tag2 = default, KeyValuePair<string, object?> tag3 = default)
    {
        try
        {
            if (tag1.Key == null)
            {
                counter.Add(1);
            }
            else if (tag2.Key == null)
            {
                counter.Add(1, tag1);
            }
            else if (tag3.Key == null)
            {
                counter.Add(1, tag1, tag2);
            }
            else
            {
                counter.Add(1, tag1, tag2, tag3);
            }
        }
        catch (Exception)
        {
            // As above.
        }
    }

    /// <summary>Records a run's duration, dropping what a listener throws.</summary>
    internal static void RecordDuration(double ms, KeyValuePair<string, object?> tag)
    {
        try
        {
            RunDuration.Record(ms, tag);
        }
        catch (Exception)
        {
            // As above.
        }
    }
}
