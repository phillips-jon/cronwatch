using System;
using Hangfire;
using Xunit;

namespace Cronwatch.Hangfire.Tests;

/// <summary>
/// The README's Hangfire example, compiled here (the core's tests check that every C# block of
/// the README appears in a <c>ReadmeTests.cs</c>). It is not run: Hangfire's configuration is
/// global, and the integration's own tests run it for real one at a time.
/// </summary>
public class ReadmeTests
{
    internal static void Configure(CronwatchClient cw)
    {
        GlobalConfiguration.Configuration.UseInMemoryStorage().UseCronwatch(cw);
        CronwatchHangfire.ScheduleCheck(); // `cronwatch-check`, every minute, once per cluster
    }

    [Fact]
    public void The_example_compiles()
    {
        Action<CronwatchClient> configure = Configure;
        Assert.NotNull(configure);
    }
}
