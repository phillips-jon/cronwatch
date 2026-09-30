using System;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Reflection;
using Cronwatch.Internal;
using Xunit;

namespace Cronwatch.Tests;

/// <summary>What holds the suite itself: every fixture accounted for, the culture it runs in, the core's dependencies.</summary>
public class SuiteTests
{
    /// <summary>The fixtures this phase replays.</summary>
    private static readonly string[] Replayed = ["duration", "schedule", "output", "evaluate", "format", "health", "store"];

    /// <summary>The fixtures the channels, triage and pg_cron replay in phase 2.</summary>
    private static readonly string[] Later = ["channels", "triage", "pgcron"];

    [Fact]
    public void Every_fixture_the_sdk_writes_is_known()
    {
        var files = Directory.GetFiles(Fixtures.ConformanceDir, "*.json").Select(Path.GetFileNameWithoutExtension).OrderBy(n => n, StringComparer.Ordinal).ToList();
        var known = Replayed.Concat(Later).ToHashSet(StringComparer.Ordinal);
        var unknown = files.Where(f => !known.Contains(f!)).ToList();
        Assert.True(unknown.Count == 0, "conformance/ has fixtures this port does not replay: " + string.Join(", ", unknown));
        foreach (string name in Replayed)
        {
            Assert.Contains(name, files);
        }
    }

    [Fact]
    public void The_fixtures_are_read_in_utc()
    {
        // The replays that read the local zone name UTC themselves; on Linux and macOS the test host
        // is in UTC as well.
        if (!OperatingSystem.IsWindows())
        {
            Assert.Equal(TimeSpan.Zero, TimeZoneInfo.Local.BaseUtcOffset);
        }
        Assert.Equal(TimeZoneInfo.Utc, Support.Clock().LocalTimeZone);
    }

    [Fact]
    public void The_culture_the_suite_runs_in_changes_no_byte()
    {
        string? asked = Environment.GetEnvironmentVariable("CRONWATCH_CULTURE");
        if (!string.IsNullOrEmpty(asked))
        {
            Assert.Equal(asked, CultureInfo.CurrentCulture.Name);
        }
        Assert.Equal("1.5", Js.FormatNumber(1.5));
        Assert.Equal("{\"i\":1.5}", new JsObject().Set("i", 1.5).ToJson());
    }

    [Fact]
    public void The_core_has_no_package_dependencies()
    {
        // The core's restore records every package it depends on; there must be none, as the
        // .nuspec CI checks after packing has no dependency.
        string assets = Path.Combine(Fixtures.Repo, "packages", "dotnet", "src", "Cronwatch", "obj", "project.assets.json");
        Assert.True(File.Exists(assets), "the core has not been restored: " + assets);
        var root = Json.ParseObject(File.ReadAllText(assets));
        // The trimming analyzers' build tasks, which IsAotCompatible brings, are the build's own and
        // never reach a package.
        var libraries = (root.Get("libraries") as JsObject)?.Keys ?? [];
        Assert.DoesNotContain(libraries, l => !l.StartsWith("Microsoft.NET.ILLink.Tasks/", StringComparison.Ordinal));
        string project = File.ReadAllText(Path.Combine(Fixtures.Repo, "packages", "dotnet", "src", "Cronwatch", "Cronwatch.csproj"));
        Assert.DoesNotContain("PackageReference", project, StringComparison.Ordinal);
        Assert.DoesNotContain("FrameworkReference", project, StringComparison.Ordinal);
    }

    [Fact]
    public void The_version_is_the_releases()
    {
        string props = File.ReadAllText(Path.Combine(Fixtures.Repo, "packages", "dotnet", "Directory.Build.props"));
        int at = props.IndexOf("<Version>", StringComparison.Ordinal) + "<Version>".Length;
        string version = props[at..props.IndexOf("</Version>", at, StringComparison.Ordinal)];
        Assert.Equal(version, CronwatchClient.Version);
    }

    [Fact]
    public void Nothing_public_hands_out_a_secret()
    {
        // A logger that walks public getters, a debugger's view and a record's ToString must find
        // no secret: the options that hold one read it through an internal getter.
        var secretish = new[] { "secret", "token", "apikey", "password", "webhook" };
        foreach (Type t in typeof(CronwatchClient).Assembly.GetExportedTypes())
        {
            foreach (PropertyInfo p in t.GetProperties(BindingFlags.Public | BindingFlags.Instance))
            {
                if (p.GetMethod is not { IsPublic: true })
                {
                    continue;
                }
                string name = p.Name.ToLowerInvariant();
                bool holdsOne = p.PropertyType == typeof(CronSecret) || secretish.Any(s => name.Contains(s, StringComparison.Ordinal));
                Assert.False(holdsOne && p.PropertyType != typeof(bool) && p.PropertyType != typeof(System.Threading.CancellationToken), t.Name + "." + p.Name + " hands out a secret through a public getter");
            }
        }
        Assert.Equal("CronSecret(set)", ((CronSecret)"not-a-real-secret").ToString());
        string options = new CronwatchOptions { CronSecret = "not-a-real-secret" }.ToString();
        Assert.DoesNotContain("not-a-real-secret", options, StringComparison.Ordinal);
    }
}
