using Cronwatch.Hosting;
using Microsoft.Extensions.DependencyInjection;
using Xunit;

#pragma warning disable CS0618 // the former class, kept through 1.x, is what this file tests

namespace AppWithBothNamespaces;

/// <summary>
/// A host file that imports <c>Cronwatch.Hosting</c> (for <c>ICronwatchJob</c>) and, as the Web
/// and Worker SDKs' implicit usings do, <c>Microsoft.Extensions.DependencyInjection</c>: the former
/// class's simple name is not ambiguous there, since the new class has a name of its own.
/// </summary>
public class BothNamespacesTests
{
    [Fact]
    public void The_former_class_is_named_unqualified_beside_the_new_one()
    {
        Assert.Equal("Cronwatch", CronwatchServiceCollectionExtensions.ConfigurationSection);
        Assert.Equal("Cronwatch", CronwatchHostingServiceCollectionExtensions.ConfigurationSection);
        var services = new ServiceCollection();
        Assert.Same(services, CronwatchServiceCollectionExtensions.AddCronwatch(services, o => o.NoCheck = true));
        Assert.Equal("Cronwatch.Hosting", typeof(ICronwatchJob).Namespace);
    }
}
