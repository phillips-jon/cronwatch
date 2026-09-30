using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;
using System.Threading.Tasks;
using Xunit;

namespace Cronwatch.Tests.Web;

/// <summary>
/// What depends on the environment: the dashboard locked without a token outside development,
/// the development token and its sign-in line, and a job's handler with no secret. Each case runs
/// in a child process (<c>test/WebEnvChild</c>) with only the variables it names, since the
/// process's environment is shared by every test running at once, and the parent reads what it
/// printed.
/// </summary>
public class RoutesEnvTests
{
    private const string Intro = "[cronwatch] CRONWATCH_TOKEN is not set, so this development server made a token for the dashboard. Sign in: ";
    private const string Hostless = " on this server (the first request's host is not local, so the link leaves it out)";

    private static readonly string[] Cleared =
        ["CRONWATCH_ENV", "APP_ENV", "DOTNET_ENVIRONMENT", "ASPNETCORE_ENVIRONMENT", "CRONWATCH_TOKEN", "CRON_SECRET"];

    /// <summary>Runs <paramref name="name"/> in a child with only these of the variables CronWatch reads, and answers its output.</summary>
    private static async Task<string> Child(string name, params (string Name, string Value)[] vars)
    {
        string dir = AppContext.BaseDirectory.TrimEnd(Path.DirectorySeparatorChar);
        string child = Path.Combine(
            Path.GetDirectoryName(dir)!.Replace("Cronwatch.Tests", "WebEnvChild", StringComparison.Ordinal),
            Path.GetFileName(dir),
            "WebEnvChild.dll");
        Assert.True(File.Exists(child), "the child is built beside the tests: " + child);
        var start = new ProcessStartInfo(DotnetHost(), [child, name])
        {
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            UseShellExecute = false,
        };
        foreach (string v in Cleared)
        {
            start.Environment.Remove(v);
        }
        foreach (var (n, v) in vars)
        {
            start.Environment[n] = v;
        }
        using var process = Process.Start(start)!;
        var stdout = process.StandardOutput.ReadToEndAsync();
        var stderr = process.StandardError.ReadToEndAsync();
        await process.WaitForExitAsync().WaitAsync(TimeSpan.FromSeconds(120));
        // Windows may end the child's lines with \r\n; read them as the others.
        string output = (await stdout).Replace("\r\n", "\n", StringComparison.Ordinal);
        string errors = await stderr;
        Assert.True(process.ExitCode == 0, name + " failed:\n" + output + errors);
        Assert.Contains("CHILD OK", output, StringComparison.Ordinal);
        return output;
    }

    private static string DotnetHost()
    {
        string exe = OperatingSystem.IsWindows() ? "dotnet.exe" : "dotnet";
        var runtime = new DirectoryInfo(RuntimeEnvironment.GetRuntimeDirectory().TrimEnd(Path.DirectorySeparatorChar));
        string? root = runtime.Parent?.Parent?.Parent?.FullName;
        return root != null && File.Exists(Path.Combine(root, exe)) ? Path.Combine(root, exe) : exe;
    }

    private static List<string> Announced(string output) =>
        output.Split('\n')
            .Select(l => l.IndexOf("[cronwatch]", StringComparison.Ordinal) is int i and >= 0 ? l[i..].Trim() : null)
            .OfType<string>()
            .ToList();

    [Theory]
    [InlineData("")]
    [InlineData("production")]
    [InlineData("staging")]
    [InlineData("prod")]
    public async Task Routes_are_locked_without_a_token_outside_development(string environment)
    {
        await Child("locked", ("CRONWATCH_ENV", environment));
    }

    [Theory]
    [InlineData("CRONWATCH_ENV", "test")]
    [InlineData("APP_ENV", "test")]
    [InlineData("ASPNETCORE_ENVIRONMENT", "Development")]
    public async Task A_development_token_is_printed_once_and_required(string variable, string value)
    {
        string output = await Child("developmentToken", (variable, value));
        List<string> lines = Announced(output);
        Assert.True(lines.Count == 2, variable + ": " + output);
        Assert.StartsWith(Intro, lines[0], StringComparison.Ordinal);
        string first = lines[0][Intro.Length..];
        const string prefix = "http://localhost:3000/cronwatch/?token=";
        Assert.StartsWith(prefix, first, StringComparison.Ordinal);
        string token = first[prefix.Length..];
        Assert.Equal(43, token.Length);
        Assert.Matches("^[A-Za-z0-9_-]+$", token);
        Assert.Contains("\nTOKEN " + token + "\n", output, StringComparison.Ordinal);
        string second = lines[1][Intro.Length..];
        Assert.StartsWith("/?token=", second, StringComparison.Ordinal);
        Assert.EndsWith(Hostless, second, StringComparison.Ordinal);
        Assert.DoesNotContain(token, second, StringComparison.Ordinal);
    }

    [Fact]
    public async Task An_empty_token_is_unset_and_no_token_opens()
    {
        await Child("emptyToken", ("CRONWATCH_ENV", "production"));
        string output = await Child("openInDevelopment", ("CRONWATCH_ENV", "development"));
        Assert.Empty(Announced(output));
        output = await Child("configuredInDevelopment", ("CRONWATCH_ENV", "development"), ("CRONWATCH_TOKEN", "envtok"));
        Assert.Empty(Announced(output));
    }

    [Fact]
    public async Task The_sign_in_line_shows_the_host_only_when_configured_or_loopback()
    {
        string output = await Child("signInLines", ("CRONWATCH_ENV", "development"));
        (string Shown, string Tail)[] expected =
        [
            ("https://app.example.com/cronwatch", ""),
            ("https://app.example.com/cronwatch", ""),
            ("http://localhost:3000/cronwatch", ""),
            ("http://app.localhost:3000/cronwatch", ""),
            ("http://127.0.0.1:3000/cronwatch", ""),
            ("http://127.8.9.10/cronwatch", ""),
            ("http://[::1]:3000/cronwatch", ""),
            ("http://localhost:5173/cronwatch", ""),
            ("/cronwatch", Hostless),
            ("/cronwatch", Hostless),
            ("/cronwatch", Hostless),
            ("/cronwatch", Hostless),
            ("/cronwatch", Hostless),
            ("", Hostless),
            ("/cronwatch", Hostless),
            ("/cronwatch", Hostless),
        ];
        List<string> lines = Announced(output);
        Assert.True(lines.Count == expected.Length, output);
        for (int i = 0; i < expected.Length; i++)
        {
            string line = lines[i];
            string rest = line[(line.IndexOf("token=", StringComparison.Ordinal) + 6)..];
            int space = rest.IndexOf(' ', StringComparison.Ordinal);
            string token = space < 0 ? rest : rest[..space];
            Assert.Equal(43, token.Length);
            Assert.Equal(Intro + expected[i].Shown + "/?token=" + token + expected[i].Tail, line);
        }
    }

    [Fact]
    public async Task A_handler_without_a_secret_fails_closed_outside_development()
    {
        await Child("handlerClosed");
        await Child("handlerDevelopment", ("APP_ENV", "local"));
    }

    [Fact]
    public async Task The_environment_option_is_read_when_no_variable_names_one()
    {
        await Child("environmentFallback");
    }

    [Fact]
    public async Task The_environment_given_outranks_dotnets_variables_and_those_follow_aspnet_cores_order()
    {
        await Child("givenOverDotNet", ("ASPNETCORE_ENVIRONMENT", "Development"), ("DOTNET_ENVIRONMENT", "Development"));
        await Child("dotNetOrder", ("ASPNETCORE_ENVIRONMENT", "Production"), ("DOTNET_ENVIRONMENT", "Development"));
    }
}
