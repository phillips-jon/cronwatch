using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Text;
using System.Threading.Tasks;
using Cronwatch.Internal;
using Xunit;

namespace Cronwatch.Tests;

/// <summary>
/// The croner port against croner itself: 3,000 generated cron expressions (see
/// <see cref="CronFuzzer"/>), in zones with and without daylight saving, from times around the
/// clock changes, answered by the SDK in Node (reading packages/sdk/dist) and by this port, which
/// must agree on every error message and every fire time. Skipped, with the reason, when node or
/// the built SDK is missing.
/// </summary>
public class CronerParityTests(ITestOutputHelper output)
{
    private sealed record Case(string Schedule, string Timezone, long From, long Count);

    private static List<Case> Cases(ulong seed, int count)
    {
        var f = new CronFuzzer(seed);
        // Around the nights clocks change in the zones, and ordinary days.
        long[] starts =
        [
            Js.DateUtc(2026, 2, 8, 6, 30, 0, 0),
            Js.DateUtc(2026, 10, 1, 5, 10, 0, 0),
            Js.DateUtc(2026, 2, 29, 0, 45, 0, 0),
            Js.DateUtc(2026, 9, 25, 0, 50, 0, 0),
            Js.DateUtc(2026, 9, 3, 15, 20, 0, 0),
            Js.DateUtc(2026, 3, 4, 14, 55, 0, 0),
            Js.DateUtc(2026, 0, 5, 9, 30, 0, 0),
            Js.DateUtc(2027, 1, 27, 23, 59, 59, 0),
            Js.DateUtc(2028, 1, 28, 12, 0, 0, 0),
        ];
        var cases = new List<Case>();
        for (int i = 0; i < count; i++)
        {
            long from = f.Pick(starts);
            from += f.Between(-3, 3) * 3_600_000L;
            from += f.Between(0, 3_599) * 1000L;
            from += f.Pick(new long[] { 0, 0, 500, 999 });
            string schedule = f.Expression();
            long n = f.Between(1, 6);
            string timezone = f.Pick(CronFuzzer.Zones);
            cases.Add(new Case(schedule, timezone, from, n));
        }
        return cases;
    }

    /// <summary>This port's answer, as the helper writes the SDK's: <c>{error}</c> or <c>{fires}</c>.</summary>
    private static JsObject Answer(Case c)
    {
        ParsedSchedule p;
        try
        {
            // Node runs with TZ=UTC; the zone "" is read in UTC here too, whatever the system's.
            p = Schedules.Parse(c.Schedule, c.Timezone, TimeZoneInfo.Utc);
        }
        catch (ArgumentException e)
        {
            return new JsObject().Set("error", e.Message);
        }
        var fires = new List<object?>();
        long at = c.From;
        for (long i = 0; i < c.Count; i++)
        {
            long? next = Schedules.NextFire(p, at, null);
            fires.Add(next);
            if (next is not long n)
            {
                break;
            }
            at = n;
        }
        return new JsObject().Set("fires", fires);
    }

    private static string Show(JsObject a)
    {
        if (a.Has("error"))
        {
            return "error " + a.Get("error");
        }
        var parts = Fixtures.List(a, "fires").Select(t => t switch
        {
            double d => Js.IsoString((long)d),
            long l => Js.IsoString(l),
            _ => "null",
        });
        return "[" + string.Join(" ", parts) + "]";
    }

    /// <summary>Runs a command, answering its exit code and standard output, or null when it cannot start.</summary>
    internal static async Task<(int Code, string Out, string Err)?> RunAsync(string file, params string[] args)
    {
        var info = new ProcessStartInfo(file)
        {
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            UseShellExecute = false,
            StandardOutputEncoding = Encoding.UTF8,
            StandardErrorEncoding = Encoding.UTF8,
        };
        foreach (string a in args)
        {
            info.ArgumentList.Add(a);
        }
        info.Environment["TZ"] = "UTC";
        Process process;
        try
        {
            process = Process.Start(info)!;
        }
        catch (System.ComponentModel.Win32Exception)
        {
            return null;
        }
        using (process)
        {
            Task<string> stdout = process.StandardOutput.ReadToEndAsync();
            Task<string> stderr = process.StandardError.ReadToEndAsync();
            await process.WaitForExitAsync().WaitAsync(TimeSpan.FromMinutes(5));
            return (process.ExitCode, await stdout, await stderr);
        }
    }

    [Fact]
    public async Task The_port_agrees_with_croner()
    {
        string dist = Path.Combine(Fixtures.Repo, "packages", "sdk", "dist");
        if (!File.Exists(Path.Combine(dist, "index.js")))
        {
            Assert.Skip("croner parity: skipped, packages/sdk/dist is not built (npm run build --workspace packages/sdk)");
        }
        var version = await RunAsync("node", "--version");
        if (version is not { Code: 0 })
        {
            Assert.Skip("croner parity: skipped, node is not installed");
        }
        string helper = Path.Combine(Fixtures.Repo, "packages", "dotnet", "test", "Cronwatch.Tests", "schedule_parity.mjs");
        foreach (ulong seed in new ulong[] { 1, 2, 3 })
        {
            List<Case> generated = Cases(seed, 1000);
            var input = generated.Select(c => (object?)new JsObject()
                .Set("schedule", c.Schedule)
                .Set("timezone", c.Timezone.Length == 0 ? null : c.Timezone)
                .Set("from", c.From)
                .Set("count", c.Count)).ToList();
            string file = Path.Combine(Path.GetTempPath(), "cronwatch-schedule-parity-" + Guid.NewGuid().ToString("N") + ".json");
            string expectedText;
            try
            {
                await File.WriteAllTextAsync(file, Json.Stringify(input), new UTF8Encoding(false), TestContext.Current.CancellationToken);
                var run = await RunAsync("node", helper, dist, file);
                Assert.True(run is { Code: 0 }, "node: " + run?.Err);
                expectedText = run!.Value.Out;
            }
            finally
            {
                File.Delete(file);
            }
            var expected = (List<object?>)Json.Parse(expectedText)!;

            var differences = new List<string>();
            int valid = 0;
            int threw = 0;
            for (int i = 0; i < generated.Count; i++)
            {
                Case c = generated[i];
                var want = (JsObject)expected[i]!;
                JsObject got = Answer(c);
                if (!want.Has("error"))
                {
                    valid++;
                }
                if (want.Has("throws"))
                {
                    threw++;
                    // croner walks by recursion, a year at a time, so a date no month has
                    // (February 30) runs out of stack before the year 3000. The port walks in a
                    // loop and finds nothing: the schedule never fires.
                    var prefix = new List<object?>(Fixtures.List(want, "fires")) { null };
                    var fires = Fixtures.List(got, "fires");
                    if (fires.Count < prefix.Count || Json.Stringify(fires.Take(prefix.Count).ToList()) != Json.Stringify(prefix))
                    {
                        differences.Add(c.Schedule + " in \"" + c.Timezone + "\" from " + c.From + "\n    croner threw "
                            + want.Get("throws") + " after " + Show(want) + "\n    .NET " + Show(got));
                    }
                    continue;
                }
                if (want.ToJson() != got.ToJson())
                {
                    differences.Add(c.Schedule + " in \"" + c.Timezone + "\" from " + c.From + "\n    croner " + Show(want) + "\n    .NET   " + Show(got));
                }
            }
            differences.Sort(StringComparer.Ordinal);
            Assert.True(differences.Count == 0, "seed " + seed + ": " + differences.Count + " of " + generated.Count + " differ:\n" + string.Join("\n", differences.Take(10)));
            Assert.True(valid >= 300, "seed " + seed + ": only " + valid + " generated expressions were valid");
            output.WriteLine("croner parity, seed " + seed + ": " + generated.Count + " cases, " + valid + " valid (" + threw
                + " where croner ran out of stack), " + (generated.Count - valid) + " refused with croner's message");
        }
    }
}
