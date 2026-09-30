using Microsoft.Extensions.DependencyInjection;
using Quartz;
using Xunit;

namespace Cronwatch.Quartz.Tests;

/// <summary>
/// The README's Quartz example, compiled here (the core's tests check that every C# block of the
/// README appears in a <c>ReadmeTests.cs</c>) and its registrations checked.
/// </summary>
public class ReadmeTests
{
    [Fact]
    public void The_example_registers_the_integration()
    {
        var builder = new { Services = new ServiceCollection() };
        builder.Services.AddQuartz(q =>
        {
            q.UseCronwatch(o => o.ScheduleCheck = true); // a check job every minute, once per cluster
        });
        Assert.Contains(builder.Services, d => d.ServiceType.Namespace?.StartsWith("Quartz", System.StringComparison.Ordinal) == true);
    }
}
