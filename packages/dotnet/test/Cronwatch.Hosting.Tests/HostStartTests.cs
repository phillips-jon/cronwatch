using System;
using System.Collections.Generic;
using System.Threading.Tasks;
using Cronwatch.Web;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Hosting;
using Microsoft.Extensions.Logging;
using Xunit;

namespace Cronwatch.Hosting.Tests;

/// <summary>What <c>AddCronwatch</c> refuses when the host starts, and how it reads its configuration.</summary>
public class HostStartTests
{
    private static IHost Build(Dictionary<string, string?> settings, Action<CronwatchHostOptions>? configure = null)
    {
        var builder = Host.CreateApplicationBuilder();
        builder.Logging.ClearProviders();
        builder.Configuration.AddInMemoryCollection(settings);
        builder.Services.AddCronwatch(o =>
        {
            o.ProcessExitHook = false;
            o.Store = new MemoryStore();
            configure?.Invoke(o);
        });
        return builder.Build();
    }

    [Fact]
    public async Task A_bad_CheckEvery_in_configuration_stops_the_host_from_starting()
    {
        using IHost host = Build(new() { ["Cronwatch:CheckEvery"] = "1 minute" });
        var e = await Assert.ThrowsAsync<CronwatchException>(() => host.StartAsync(TestContext.Current.CancellationToken));
        Assert.Contains("check interval \"1 minute\"", e.Message, StringComparison.Ordinal);
    }

    [Fact]
    public async Task A_bad_CheckEvery_in_code_stops_the_host_from_starting()
    {
        using IHost host = Build([], o => o.CheckEvery = "5 mins");
        var e = await Assert.ThrowsAsync<CronwatchException>(() => host.StartAsync(TestContext.Current.CancellationToken));
        Assert.Contains("check interval \"5 mins\"", e.Message, StringComparison.Ordinal);
    }

    [Fact]
    public async Task A_good_CheckEvery_starts_the_host()
    {
        using IHost host = Build(new() { ["Cronwatch:CheckEvery"] = "30s" });
        await host.StartAsync(TestContext.Current.CancellationToken);
        await host.StopAsync(TestContext.Current.CancellationToken);
    }

    [Theory]
    [InlineData(" ")]
    [InlineData("\t\n")]
    [InlineData(" \u00a0\u2003\ufeff ")]
    public void A_blank_Cronwatch_Token_counts_as_unset(string blank)
    {
        using IHost host = Build(new() { ["Cronwatch:Token"] = blank });
        RoutesOptions options = host.Services.GetRequiredService<RoutesOptions>();
        Assert.Equal("RoutesOptions(token CRONWATCH_TOKEN)", options.ToString());
        using IHost given = Build(new() { ["Cronwatch:Token"] = " padded " });
        Assert.Equal("RoutesOptions(token set)", given.Services.GetRequiredService<RoutesOptions>().ToString());
    }

    [Fact]
    public void Blank_is_javascripts_trim_not_dotnets()
    {
        Assert.True(CronwatchHostingServiceCollectionExtensions.IsBlank(""));
        Assert.True(CronwatchHostingServiceCollectionExtensions.IsBlank("\u2028\u3000\ufeff"));
        Assert.False(CronwatchHostingServiceCollectionExtensions.IsBlank("\u0085"));
        Assert.False(CronwatchHostingServiceCollectionExtensions.IsBlank("\u180e"));
        Assert.False(CronwatchHostingServiceCollectionExtensions.IsBlank(" x "));
    }
}
