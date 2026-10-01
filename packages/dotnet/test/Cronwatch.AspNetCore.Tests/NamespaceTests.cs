using System.Threading.Tasks;
using Microsoft.AspNetCore.Builder;
using Microsoft.AspNetCore.TestHost;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Hosting;
using Xunit;

#pragma warning disable CS0618 // the former classes, kept through 1.x, are part of what this file tests

namespace AppWithoutCronwatchUsings;

/// <summary>
/// The extension methods in Microsoft's namespaces (the 1.0 plan, D14), called from a namespace
/// outside <c>Cronwatch</c> with no <c>using</c> of the library's, and the former classes, kept as
/// plain static methods, still doing the same.
/// </summary>
public class NamespaceTests
{
    [Fact]
    public void Each_extension_class_is_in_microsofts_namespace()
    {
        Assert.Equal("Microsoft.Extensions.DependencyInjection", typeof(CronwatchServiceCollectionExtensions).Namespace);
        Assert.Equal("Microsoft.Extensions.DependencyInjection", typeof(CronwatchJobServiceCollectionExtensions).Namespace);
        Assert.Equal("Microsoft.Extensions.Hosting", typeof(CronwatchHostExtensions).Namespace);
        Assert.Equal("Microsoft.AspNetCore.Builder", typeof(CronwatchAspNetCoreExtensions).Namespace);
        Assert.Equal("Cronwatch.Hosting", typeof(Cronwatch.Hosting.ICronwatchJob).Namespace);
    }

    [Fact]
    public async Task The_methods_need_no_using_and_the_former_classes_still_work()
    {
        WebApplicationBuilder builder = WebApplication.CreateBuilder();
        builder.WebHost.UseTestServer();
        builder.Services.AddCronwatch(o =>
        {
            o.Token = "t0ken";
            o.NoCheck = true;
            o.ProcessExitHook = false;
        });
        await using WebApplication app = builder.Build();
        app.MapCronwatch("/cronwatch");
        Cronwatch.AspNetCore.CronwatchAspNetCore.MapCronwatch(app, "/former");
        Cronwatch.AspNetCore.CronwatchAspNetCore.UseCronwatch(app, "/middleware");
        await app.StartAsync(TestContext.Current.CancellationToken);
        var http = app.GetTestClient();
        http.DefaultRequestHeaders.Add("authorization", "Bearer t0ken");
        foreach (string path in new[] { "/cronwatch/api", "/former/api", "/middleware/api" })
        {
            var answer = await http.GetAsync(new System.Uri(path, System.UriKind.Relative), TestContext.Current.CancellationToken);
            Assert.Equal(200, (int)answer.StatusCode);
        }
        await app.StopAsync(TestContext.Current.CancellationToken);

        var services = new ServiceCollection();
        Assert.Same(services, Cronwatch.Hosting.CronwatchServiceCollectionExtensions.AddCronwatch(services, o => o.NoCheck = true));
        Assert.Contains(services, d => d.ServiceType == typeof(Cronwatch.CronwatchClient));
        Assert.Equal("Cronwatch", Cronwatch.Hosting.CronwatchServiceCollectionExtensions.ConfigurationSection);
    }
}
