using System;
using System.Collections.Generic;
using System.Net.Http;
using System.Threading;
using System.Threading.Tasks;
using Cronwatch.Hosting;
using Microsoft.AspNetCore.Builder;
using Microsoft.AspNetCore.TestHost;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Time.Testing;
using Xunit;

namespace Cronwatch.AspNetCore.Tests;

/// <summary><c>AddCronwatch</c>: the client from the container, configuration, the hosted check, and the app's logger.</summary>
public class HostingTests
{
    /// <summary>Counts the checks: every check syncs its sources first.</summary>
    private sealed class Counting : ISource
    {
        private readonly TaskCompletionSource _first = new(TaskCreationOptions.RunContinuationsAsynchronously);

        public string Name => "counting";

        public Task First => _first.Task;

        public Task<IReadOnlyList<Alert>?> SyncAsync(CronwatchClient client, CancellationToken cancellationToken)
        {
            _first.TrySetResult();
            return Task.FromResult<IReadOnlyList<Alert>?>(null);
        }
    }

    /// <summary>Keeps what is logged.</summary>
    private sealed class Lines : ILoggerProvider, ILogger
    {
        public List<string> Logged { get; } = [];

        public ILogger CreateLogger(string categoryName) => this;

        public IDisposable? BeginScope<TState>(TState state)
            where TState : notnull => null;

        public bool IsEnabled(LogLevel logLevel) => true;

        public void Log<TState>(LogLevel logLevel, EventId eventId, TState state, Exception? exception, Func<TState, Exception?, string> formatter)
        {
            lock (Logged)
            {
                Logged.Add(logLevel + " " + formatter(state, exception) + (exception == null ? "" : " " + exception.Message));
            }
        }

        public void Dispose()
        {
        }
    }

    [Fact]
    public async Task The_token_comes_from_configuration_and_the_check_runs_once_the_host_has_started()
    {
        var clock = new FakeTimeProvider(DateTimeOffset.FromUnixTimeMilliseconds(1_767_605_400_000L));
        var counting = new Counting();
        var lines = new Lines();
        WebApplicationBuilder builder = WebApplication.CreateSlimBuilder();
        builder.Logging.ClearProviders();
        builder.Logging.AddProvider(lines);
        builder.WebHost.UseTestServer();
        builder.Configuration.AddInMemoryCollection([new("Cronwatch:Token", "from-config"), new("Cronwatch:CheckEvery", "5m")]);
        builder.Services.AddCronwatch(o =>
        {
            o.Clock = clock;
            o.ProcessExitHook = false;
            o.Alerts.Add(CustomChannel.Create("quiet", (alert, ctx, ct) => Task.CompletedTask));
            o.Sources.Add(counting);
        });
        await using WebApplication app = builder.Build();
        app.MapCronwatch();
        await app.StartAsync();

        HttpClient http = app.GetTestClient();
        var request = new HttpRequestMessage(HttpMethod.Get, "/cronwatch/api/jobs");
        request.Headers.Add("authorization", "Bearer from-config");
        Assert.Equal(200, (int)(await http.SendAsync(request)).StatusCode);

        // The first check is a second after the start, on the client's clock.
        clock.Advance(TimeSpan.FromSeconds(1));
        await counting.First.WaitAsync(TimeSpan.FromSeconds(30));

        // The error handler is the app's logger.
        CronwatchClient cw = app.Services.GetRequiredService<CronwatchClient>();
        cw.ReportError(new InvalidOperationException("the store is down"), "recording nightly");
        lock (lines.Logged)
        {
            Assert.Contains("Error [cronwatch] recording nightly the store is down", lines.Logged);
        }
        await app.StopAsync();
    }

    [Fact]
    public void Nothing_public_in_the_hosting_packages_hands_out_a_secret()
    {
        var secretish = new[] { "secret", "token", "apikey", "password", "webhook", "url", "dsn" };
        foreach (var assembly in new[] { typeof(CronwatchHostOptions).Assembly, typeof(CronwatchAspNetCoreExtensions).Assembly })
        {
            foreach (Type t in assembly.GetExportedTypes())
            {
                foreach (var p in t.GetProperties(System.Reflection.BindingFlags.Public | System.Reflection.BindingFlags.Instance))
                {
                    bool holdsOne = Array.Exists(secretish, s => p.Name.Contains(s, StringComparison.OrdinalIgnoreCase));
                    Assert.False(holdsOne && p.GetMethod is { IsPublic: true } && p.PropertyType != typeof(bool), t.Name + "." + p.Name + " hands out a secret through a public getter");
                }
            }
        }
        string text = new CronwatchHostOptions { CronSecret = "letmein-test", Token = "tok-not-shown" }.ToString();
        Assert.DoesNotContain("letmein-test", text, StringComparison.Ordinal);
        Assert.DoesNotContain("tok-not-shown", text, StringComparison.Ordinal);
    }

    /// <summary>
    /// The channels: the options' once touched, even none (the core's <c>Alerts = []</c>), else
    /// the container's, else the console.
    /// </summary>
    [Fact]
    public async Task Alerts_set_empty_send_nowhere_and_left_untouched_send_to_the_console()
    {
        static async Task<string> Made(Action<CronwatchHostOptions> set, bool containerChannel = false)
        {
            var services = new ServiceCollection();
            services.AddLogging();
            if (containerChannel)
            {
                services.AddSingleton(CustomChannel.Create("registered", (alert, ctx, ct) => Task.CompletedTask));
            }
            services.AddCronwatch(o =>
            {
                o.ProcessExitHook = false;
                o.NoCheck = true;
                set(o);
            });
            await using ServiceProvider sp = services.BuildServiceProvider();
            return sp.GetRequiredService<CronwatchClient>().ToString();
        }
        Assert.EndsWith(", 1 channels)", await Made(o => { }), StringComparison.Ordinal);
        Assert.EndsWith(", 0 channels)", await Made(o => o.Alerts = []), StringComparison.Ordinal);
        Assert.EndsWith(", 0 channels)", await Made(o => o.Alerts.Clear()), StringComparison.Ordinal);
        Assert.EndsWith(", 0 channels)", await Made(o => o.Alerts = [], containerChannel: true), StringComparison.Ordinal);
        Assert.EndsWith(", 1 channels)", await Made(o => { }, containerChannel: true), StringComparison.Ordinal);
    }

    [Fact]
    public async Task No_check_runs_when_told_not_to_and_the_client_is_one_singleton()
    {
        var clock = new FakeTimeProvider(DateTimeOffset.FromUnixTimeMilliseconds(1_767_605_400_000L));
        var counting = new Counting();
        var services = new ServiceCollection();
        services.AddLogging();
        services.AddCronwatch((sp, o) =>
        {
            o.Clock = clock;
            o.ProcessExitHook = false;
            o.NoCheck = true;
            o.Sources.Add(counting);
        });
        await using ServiceProvider sp = services.BuildServiceProvider();
        Assert.Same(sp.GetRequiredService<CronwatchClient>(), sp.GetRequiredService<CronwatchClient>());
        foreach (var hosted in sp.GetServices<Microsoft.Extensions.Hosting.IHostedService>())
        {
            await hosted.StartAsync(CancellationToken.None);
        }
        clock.Advance(TimeSpan.FromMinutes(5));
        // A check would have synced the source by now; none was started.
        Assert.False(counting.First.IsCompleted);
        Assert.Contains("no check", sp.GetRequiredService<CronwatchHostOptions>().ToString(), StringComparison.Ordinal);
    }
}
