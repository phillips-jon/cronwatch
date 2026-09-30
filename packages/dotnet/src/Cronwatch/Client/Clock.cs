using System;

namespace Cronwatch;

/// <summary>The client's clock, for what runs beside it on the same time.</summary>
public sealed partial class CronwatchClient
{
    /// <summary>
    /// The clock the client reads and arms every timer on (<see cref="CronwatchOptions.Clock"/>),
    /// for an integration that must fire on the same time, such as <c>AddCronwatchJob</c>.
    /// </summary>
    public TimeProvider Clock => _time;
}
