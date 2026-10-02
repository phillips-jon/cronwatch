using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading.Tasks;
using Cronwatch.Internal;
using Cronwatch.Web;

namespace Cronwatch.WebTest;

/// <summary>A golden capture the answer does not match.</summary>
public sealed class GoldenMismatchException : Exception
{
    /// <summary>The mismatch.</summary>
    public GoldenMismatchException()
    {
    }

    /// <summary>The mismatch, described.</summary>
    public GoldenMismatchException(string message)
        : base(message)
    {
    }

    /// <summary>The mismatch, described, with its cause.</summary>
    public GoldenMismatchException(string message, Exception inner)
        : base(message, inner)
    {
    }
}

/// <summary>One capture: the request sent and the SDK's answer.</summary>
public sealed record Capture(
    string Method,
    string Path,
    IReadOnlyList<KeyValuePair<string, string>> Headers,
    string? Body,
    int Status,
    IReadOnlyList<KeyValuePair<string, string>> ResponseHeaders,
    string ResponseBody)
{
    /// <summary>The capture's name in a failure.</summary>
    public string Label => Method + " " + Path;

    /// <summary>The body as UTF-8, or null.</summary>
    public byte[]? BodyBytes => Body == null ? null : Encoding.UTF8.GetBytes(Body);
}

/// <summary>A seeded client, its clock and what it reported.</summary>
public sealed class Seeded(CronwatchClient client, Func<long> now, IReadOnlyList<string> errors) : IAsyncDisposable
{
    /// <summary>The client.</summary>
    public CronwatchClient Client { get; } = client;

    /// <summary>Now, on the seed's clock.</summary>
    public long Now => now();

    /// <summary>What the client reported to its error handler.</summary>
    public IReadOnlyList<string> Errors { get; } = errors;

    /// <inheritdoc/>
    public ValueTask DisposeAsync() => Client.DisposeAsync();
}

/// <summary>
/// The replay of <c>packages/ruby/test/web/golden.json</c>, the SDK routes' answers to a fixed
/// seed (written by <c>golden.mjs</c>), shared by every adapter's test: the seed step for step,
/// the captures, and the comparison of status, headers and body byte for byte. Run ids are random
/// on both sides, so each becomes <c>&lt;id:N&gt;</c> in order of first appearance. The other
/// ports replay the same file.
/// </summary>
public static partial class Golden
{
    /// <summary>2026-01-05 09:30:00 UTC, a Monday: golden.json's t0.</summary>
    public const long T0 = 1_767_605_400_000L;

    /// <summary>How many captures golden.json holds.</summary>
    public const int CaptureCount = 82;

    /// <summary>The captures whose request target is not a valid percent-encoding.</summary>
    public static readonly IReadOnlySet<string> MalformedTargets = new HashSet<string>(StringComparer.Ordinal) { "/cronwatch/jobs/%zz", "/cronwatch/api/jobs/%zz" };

    /// <summary>Headers a server adds of its own, left out of the comparison through one.</summary>
    public static readonly IReadOnlySet<string> ServerHeaders = new HashSet<string>(StringComparer.Ordinal) { "content-length", "date", "server", "transfer-encoding", "keep-alive", "connection" };

    private const long Min = 60_000;
    private const long Hour = 3_600_000;
    private const long Day = 24 * Hour;

    /// <summary>The repository's root, found by walking up from the test assembly.</summary>
    public static string Repo
    {
        get
        {
            string? dir = AppContext.BaseDirectory;
            while (dir != null)
            {
                if (Directory.Exists(System.IO.Path.Combine(dir, "conformance")) && Directory.Exists(System.IO.Path.Combine(dir, "packages")))
                {
                    return dir;
                }
                dir = System.IO.Path.GetDirectoryName(dir);
            }
            throw new InvalidOperationException("the repository's root was not found above " + AppContext.BaseDirectory);
        }
    }

    private static List<KeyValuePair<string, string>> Pairs(object? v)
    {
        var output = new List<KeyValuePair<string, string>>();
        if (v is JsObject o)
        {
            foreach (var e in o)
            {
                output.Add(new(e.Key, e.Value as string ?? ""));
            }
        }
        return output;
    }

    /// <summary>
    /// <c>GET /api</c>'s answer names the library, its language and its version, which differ from
    /// port to port: golden.json holds <c>&lt;library&gt;</c>, <c>&lt;language&gt;</c> and
    /// <c>&lt;version&gt;</c> in their place, and this port puts in its own.
    /// </summary>
    private static string About(string body)
    {
        const string Placeholders = """{"ok":true,"library":"<library>","language":"<language>","version":"<version>",""";
        return body.StartsWith(Placeholders, StringComparison.Ordinal)
            ? """{"ok":true,"library":"Cronwatch","language":"dotnet","version":""" + JsonText.Quote(CronwatchClient.Version) + "," + body[Placeholders.Length..]
            : body;
    }

    /// <summary>The captures, in order.</summary>
    public static IReadOnlyList<Capture> Captures()
    {
        string path = System.IO.Path.Combine(Repo, "packages", "ruby", "test", "web", "golden.json");
        JsObject golden = Json.ParseObject(File.ReadAllText(path, Encoding.UTF8));
        if (golden.Get("t0") is not double t0 || (long)t0 != T0)
        {
            throw new GoldenMismatchException("golden.json's t0 is not " + T0);
        }
        var output = new List<Capture>();
        foreach (object? c in (List<object?>)golden.Get("captures")!)
        {
            var o = (JsObject)c!;
            output.Add(new Capture(
                (string)o.Get("method")!,
                (string)o.Get("path")!,
                Pairs(o.Get("headers")),
                o.Get("body") as string,
                (int)(double)o.Get("status")!,
                Pairs(o.Get("responseHeaders")),
                About((string)o.Get("responseBody")!)));
        }
        if (output.Count != CaptureCount)
        {
            throw new GoldenMismatchException("golden.json holds " + output.Count + " captures, not " + CaptureCount);
        }
        return output;
    }

    /// <summary>The clock whose local zone is UTC, as golden.mjs runs, on every system.</summary>
    private sealed class UtcClock : TimeProvider
    {
        public override TimeZoneInfo LocalTimeZone => TimeZoneInfo.Utc;
    }

    private static async Task QuietlyAsync(Func<Task> step)
    {
        try
        {
            await step();
        }
        catch (Exception)
        {
            // A failed run is part of the seed.
        }
    }

    /// <summary>The seed in golden.mjs, step for step.</summary>
    public static async Task<Seeded> SeedAsync()
    {
        long now = T0;
        var errors = new List<string>();
        var cw = new CronwatchClient(new CronwatchOptions
        {
            Store = new MemoryStore(),
            Alerts = { CustomChannel.Create("capture", (alert, ctx, ct) => Task.CompletedTask) },
            CronSecret = CronSecret.None,
            ProcessExitHook = false,
            Clock = new UtcClock(),
            TimingsOverride = new Timings { Now = () => System.Threading.Interlocked.Read(ref now) },
            OnError = (error, where) =>
            {
                lock (errors)
                {
                    errors.Add(where + ": " + error.Message);
                }
            },
        });

        Job nightly = cw.Job("nightly-report", new JobOptions
        {
            Schedule = "0 2 * * *",
            Timezone = "UTC",
            Grace = "15m",
            MaxDuration = "10m",
            Budget = { ["cost"] = 2 },
            Floor = { ["rows"] = 40 },
            Expect = "Report written",
            FailuresBeforeAlert = 2,
            Description = "Builds the <b>PDF</b>",
            Tags = ["reports", "<t>"],
        });
        long[] durations = [2000, 2500, 90_000, 3100, 1800];
        for (int i = 0; i < durations.Length; i++)
        {
            int n = i;
            now = T0 - ((5 - i) * Day) - (7 * Hour) - (30 * Min);
            await QuietlyAsync(() => nightly.RunAsync((job, ct) =>
            {
                job.Log((n == 3 ? "Wrote nothing" : "Report written:") + " report-" + n + ".pdf");
                job.Metric("cost", n == 4 ? 2.5 : 1.2);
                job.Metric("rows", 40 + n);
                job.Metric("2", 0.123456);
                now += durations[n];
                return Task.CompletedTask;
            }));
        }

        // Five runs that wrote rows, then one that wrote none: under its floor.
        Job importer = cw.Job("import", new JobOptions { Schedule = "0 * * * *" });
        for (int i = 0; i < 6; i++)
        {
            int n = i;
            now = T0 - ((6 - i) * Hour) - (30 * Min);
            await importer.RunAsync((job, ct) =>
            {
                job.Metric("rows", n == 5 ? 0 : 120 + n);
                now += 800;
                return Task.CompletedTask;
            });
        }

        Job broken = cw.Job("broken", new JobOptions { Expect = "done" });
        now = T0 - (2 * Hour);
        await QuietlyAsync(() => broken.RunAsync((job, ct) =>
        {
            job.Log("half way <script>alert(1)</script>");
            now += 450;
            return Task.CompletedTask;
        }));

        Job sync = cw.Job("sync-users", new JobOptions { Schedule = "*/15 * * * *", Grace = 60_000, Timeout = "5m" });
        now = T0 - (3 * Hour);
        await QuietlyAsync(() => sync.RunAsync((job, ct) =>
        {
            now += 12_345;
            return Task.CompletedTask;
        }));

        cw.Job("never-ran", new JobOptions { Schedule = "0 * * * *" });

        // A run as a foreign or damaged row could hold it: started before the year 1, so the
        // pages write it in words rather than as a date.
        Job farBack = cw.Job("far-back", new JobOptions { Timeout = "5m", Expect = "far" });
        now = -62_135_596_800_001L;
        await QuietlyAsync(() => farBack.RunAsync((job, ct) =>
        {
            now += 1000;
            return Task.CompletedTask;
        }));

        // Cron jobs whose last run is as far off: counted from the first millisecond of the year
        // 1, the first is due then (and is missed at the check); after 9999 the other is never due
        // again.
        Job farCronBack = cw.Job("far-cron-back", new JobOptions { Schedule = "0 2 * * *", Timezone = "UTC", Grace = "10m" });
        now = -62_135_596_800_001L;
        await farCronBack.RunAsync((job, ct) =>
        {
            now += 1000;
            return Task.CompletedTask;
        });
        Job farCronAhead = cw.Job("far-cron-ahead", new JobOptions { Schedule = "0 2 * * *", Timezone = "UTC", Grace = "10m" });
        now = 253_402_300_800_000L;
        await farCronAhead.RunAsync((job, ct) =>
        {
            now += 1000;
            return Task.CompletedTask;
        });
        now = T0;
        return new Seeded(cw, () => System.Threading.Interlocked.Read(ref now), errors);
    }

    [GeneratedRegex(@"\{run:([^:}]+):(\d+)\}")]
    private static partial Regex RunPattern();

    [GeneratedRegex("[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}")]
    private static partial Regex UuidPattern();

    /// <summary>The path with the id of the Nth newest run of a job where it says <c>{run:JOB:N}</c>.</summary>
    public static async Task<string> ResolveAsync(CronwatchClient cw, string path)
    {
        Match m = RunPattern().Match(path);
        if (!m.Success)
        {
            return path;
        }
        var runs = await cw.RunsAsync(m.Groups[1].Value, 50);
        return path[..m.Index] + runs[int.Parse(m.Groups[2].Value, System.Globalization.CultureInfo.InvariantCulture)].Id + path[(m.Index + m.Length)..];
    }

    /// <summary>Numbers run ids in order of first appearance, as golden.mjs does.</summary>
    public sealed class Ids
    {
        private readonly Dictionary<string, string> _seen = new(StringComparer.Ordinal);

        /// <summary>The text with each id replaced.</summary>
        public string Replace(string text) => UuidPattern().Replace(text, m =>
        {
            if (!_seen.TryGetValue(m.Value, out string? n))
            {
                n = "<id:" + _seen.Count + ">";
                _seen[m.Value] = n;
            }
            return n;
        });
    }

    /// <summary>The capture as a <see cref="CronwatchRequest"/> for <paramref name="path"/>, from <c>app.test</c>.</summary>
    public static CronwatchRequest Request(Capture c, string path, string? mount = null)
    {
        var headers = new List<KeyValuePair<string, string>> { new("host", "app.test") };
        headers.AddRange(c.Headers);
        return c.BodyBytes is { } body
            ? new CronwatchRequest(c.Method, path) { Headers = headers, Body = body, Mount = mount }
            : new CronwatchRequest(c.Method, path) { Headers = headers, Mount = mount };
    }

    /// <summary>
    /// Checks one answer against its capture: the status, every header but those in
    /// <paramref name="ignored"/> (names compared without case, order aside, since fetch's
    /// <c>Headers</c> iterate sorted), and the body byte for byte.
    /// </summary>
    public static void Compare(Capture c, int status, IEnumerable<KeyValuePair<string, string>> headers, byte[] body, Ids ids, IReadOnlySet<string> ignored)
    {
        string label = c.Label;
        var got = new SortedDictionary<string, string>(StringComparer.Ordinal);
        foreach (var h in headers)
        {
            string name = h.Key.ToLowerInvariant();
            if (ignored.Contains(name))
            {
                continue;
            }
            got[name] = got.TryGetValue(name, out string? before) ? before + ", " + h.Value : h.Value;
        }
        var want = new SortedDictionary<string, string>(StringComparer.Ordinal);
        foreach (var h in c.ResponseHeaders)
        {
            want[h.Key] = h.Value;
        }
        if (status != c.Status)
        {
            throw new GoldenMismatchException(label + ": status " + status + ", want " + c.Status);
        }
        string g = string.Join("\n", got.Select(e => e.Key + ": " + e.Value));
        string w = string.Join("\n", want.Select(e => e.Key + ": " + e.Value));
        if (g != w)
        {
            throw new GoldenMismatchException(label + ": headers\n got:\n" + g + "\nwant:\n" + w);
        }
        string text = got.TryGetValue("content-type", out string? type) && type == "image/png"
            ? "base64:" + Convert.ToBase64String(body)
            : ids.Replace(Encoding.UTF8.GetString(body));
        if (text != c.ResponseBody)
        {
            string wb = c.ResponseBody;
            int at = 0;
            while (at < text.Length && at < wb.Length && text[at] == wb[at])
            {
                at++;
            }
            int from = Math.Max(0, at - 120);
            throw new GoldenMismatchException(label + ": the body differs at " + at + ":\n got " + text[from..Math.Min(text.Length, at + 200)] + "\nwant " + wb[from..Math.Min(wb.Length, at + 200)]);
        }
    }

    /// <summary>Replays every capture straight into the routes; answers how many matched.</summary>
    public static async Task<int> IntoRoutesAsync(Seeded seeded, Routes routes)
    {
        var ids = new Ids();
        int matched = 0;
        foreach (Capture c in Captures())
        {
            string path = await ResolveAsync(seeded.Client, c.Path);
            CronwatchResponse answer = await routes.HandleAsync(Request(c, path));
            // Straight into the routes nothing is added: no content-length, as the SDK's answers.
            Compare(c, answer.Status, answer.Headers, answer.Body.ToArray(), ids, new HashSet<string>());
            matched++;
        }
        NoErrors(seeded);
        return matched;
    }

    /// <summary>Fails when the seeded client reported an error.</summary>
    public static void NoErrors(Seeded seeded)
    {
        if (seeded.Errors.Count > 0)
        {
            throw new GoldenMismatchException("errors reported:\n  " + string.Join("\n  ", seeded.Errors));
        }
    }

    /// <summary>
    /// Replays every capture through a server on <paramref name="port"/> with the dashboard at
    /// <c>/cronwatch</c>, over a raw socket, ignoring what the server adds of its own. A capture
    /// whose path is in <paramref name="refused"/> must be refused by the server itself with a 400.
    /// Answers how many captures matched.
    /// </summary>
    public static async Task<int> ThroughServerAsync(Seeded seeded, int port, IReadOnlySet<string> ignored, IReadOnlySet<string> refused)
    {
        var ids = new Ids();
        int matched = 0;
        foreach (Capture c in Captures())
        {
            string path = await ResolveAsync(seeded.Client, c.Path);
            RawHttp.Answer a = await RawHttp.SendAsync(port, c.Method, path, c.Headers, c.BodyBytes);
            if (refused.Contains(c.Path))
            {
                if (a.Status != 400)
                {
                    throw new GoldenMismatchException(c.Label + ": not refused by the server (" + a.Status + ")");
                }
                continue;
            }
            Compare(c, a.Status, a.Headers, a.Body, ids, ignored);
            matched++;
        }
        NoErrors(seeded);
        return matched;
    }
}
