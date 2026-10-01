using System;
using System.Linq;
using System.Reflection;
using System.Threading;
using System.Threading.Tasks;
using Cronwatch.Alerts;
using Microsoft.Extensions.DependencyInjection;
using Xunit;

namespace Cronwatch.Hosting.Tests;

/// <summary>
/// <see cref="CronwatchHostOptions"/> repeats <see cref="CronwatchOptions"/>' settings, set in a
/// callback rather than an initializer (the 1.0 plan, D15): this holds the two in step, so a new
/// client option cannot be left out of <c>AddCronwatch</c>, and checks each reaches the client.
/// </summary>
public class HostOptionsTests
{
    /// <summary>The client's settings the host fills itself.</summary>
    private static readonly string[] HostFills = ["RunScope"];

    /// <summary>The host's own settings, which the client does not have.</summary>
    private static readonly string[] HostOnly = ["CheckEvery", "NoCheck", "Token"];

    private static string[] Names(Type t) =>
        [.. t.GetProperties(BindingFlags.Public | BindingFlags.Instance).Select(p => p.Name).OrderBy(n => n, StringComparer.Ordinal)];

    [Fact]
    public void Every_client_option_is_a_host_option_of_the_same_type()
    {
        string[] client = Names(typeof(CronwatchOptions));
        string[] host = Names(typeof(CronwatchHostOptions));
        Assert.Equal(client.Except(HostFills), host.Except(HostOnly));
        foreach (string name in client.Except(HostFills))
        {
            Type want = typeof(CronwatchOptions).GetProperty(name)!.PropertyType;
            Type got = typeof(CronwatchHostOptions).GetProperty(name)!.PropertyType;
            // The host's are nullable where the client's have a default the host reads from configuration.
            Assert.True(got == want || Nullable.GetUnderlyingType(got) == want, name + ": " + got + ", the client's " + want);
        }
    }

    private sealed class Recording : ITransport
    {
        public int Posts;

        public Task<TransportResponse> PostAsync(TransportRequest request, CancellationToken cancellationToken)
        {
            Interlocked.Increment(ref Posts);
            return Task.FromResult(new TransportResponse(200, ""));
        }
    }

    [Fact]
    public async Task The_transport_given_reaches_the_client()
    {
        var transport = new Recording();
        var services = new ServiceCollection();
        services.AddCronwatch(o =>
        {
            o.Transport = transport;
            o.Alerts.Add(new WebhookChannel(new WebhookOptions { Url = "https://hooks.example/cw" }));
            o.NoCheck = true;
            o.ProcessExitHook = false;
        });
        await using ServiceProvider sp = services.BuildServiceProvider();
        CronwatchClient cw = sp.GetRequiredService<CronwatchClient>();
        await Assert.ThrowsAnyAsync<Exception>(() => cw.Job("j").RunAsync((job, ct) => throw new InvalidOperationException("boom")));
        Assert.Equal(1, transport.Posts);
    }
}
