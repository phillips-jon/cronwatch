using System;
using System.Collections.Generic;
using System.Globalization;
using System.Net.Http;
using System.Threading;
using System.Threading.Tasks;
using MetricsValue = Cronwatch.Metrics;

namespace Cronwatch.Internal;

/// <summary>The current flow's run, .NET's <c>AsyncLocalStorage</c>.</summary>
internal static class CurrentRun
{
    private static readonly AsyncLocal<JobContext?> Value = new();

    public static JobContext? Get() => Value.Value;

    public static void Set(JobContext? context) => Value.Value = context;
}

/// <summary>
/// The environment, read in one place: the first of <c>CRONWATCH_ENV</c>, <c>APP_ENV</c>,
/// <c>DOTNET_ENVIRONMENT</c> and <c>ASPNETCORE_ENVIRONMENT</c> that is set, lowercased, with the
/// ports' aliases (<c>prod</c> is production; <c>dev</c>, <c>local</c>, <c>test</c> and
/// <c>testing</c> are development); else the fallback the app gave; else unset, which is not
/// development.
/// </summary>
internal static class Env
{
    private static readonly string[] Variables = ["CRONWATCH_ENV", "APP_ENV", "DOTNET_ENVIRONMENT", "ASPNETCORE_ENVIRONMENT"];

    public static string Environment(string? fallback = null)
    {
        foreach (string name in Variables)
        {
            string? value = System.Environment.GetEnvironmentVariable(name);
            if (value == null)
            {
                continue;
            }
            string v = Normalize(value);
            if (v.Length > 0)
            {
                return v;
            }
        }
        return fallback == null ? "" : Normalize(fallback);
    }

    private static string Normalize(string value)
    {
        string v = Js.Trim(value).ToLowerInvariant();
        return v switch
        {
            "prod" => "production",
            "dev" or "local" or "test" or "testing" => "development",
            _ => v,
        };
    }

    public static string? Read(string name) => System.Environment.GetEnvironmentVariable(name);
}

/// <summary>What a run records as it goes: its lines (see <see cref="OutputLines"/>) and its metrics, set in place.</summary>
internal sealed class Recorder
{
    private readonly OutputLines _lines = new();
    private readonly Lock _lock = new();
    private readonly JsObject _metrics = new();
    private MetricsValue? _read = MetricsValue.Empty;

    public void Log(string line) => _lines.Log(line ?? "");

    public string? Output() => _lines.Output();

    public string? ExpectText() => _lines.ExpectText();

    /// <exception cref="ArgumentException">When the value is not finite.</exception>
    public void Metric(string name, double value)
    {
        ArgumentNullException.ThrowIfNull(name);
        if (!double.IsFinite(value))
        {
            throw new ArgumentException("metric \"" + name + "\" must be a finite number");
        }
        lock (_lock)
        {
            _metrics.Set(name, value);
            _read = null;
        }
    }

    public MetricsValue Metrics()
    {
        lock (_lock)
        {
            return _read ??= MetricsValue.Own(_metrics.Copy());
        }
    }
}

/// <summary>
/// One FIFO turn per key, awaited: the SDK's <c>serial()</c>. A key's entry is dropped once no one
/// holds or waits for it, so a name used once is not kept for good.
/// </summary>
internal sealed class JobQueues
{
    private readonly Dictionary<string, Entry> _entries = new(StringComparer.Ordinal);

    private sealed class Entry
    {
        public Task Tail = Task.CompletedTask;
        public int Users;
    }

    public async Task<Turn> EnterAsync(string key)
    {
        var mine = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        Task previous;
        lock (_entries)
        {
            if (!_entries.TryGetValue(key, out var e))
            {
                e = new Entry();
                _entries[key] = e;
            }
            e.Users++;
            previous = e.Tail;
            e.Tail = mine.Task;
        }
        await previous.ConfigureAwait(false);
        return new Turn(this, key, mine);
    }

    private void Leave(string key, TaskCompletionSource mine)
    {
        mine.TrySetResult();
        lock (_entries)
        {
            if (_entries.TryGetValue(key, out var e) && --e.Users == 0)
            {
                _entries.Remove(key);
            }
        }
    }

    /// <summary>How many keys are held or waited for, for the tests.</summary>
    public int Count
    {
        get
        {
            lock (_entries)
            {
                return _entries.Count;
            }
        }
    }

    public readonly struct Turn(JobQueues owner, string key, TaskCompletionSource mine) : IDisposable
    {
        public void Dispose() => owner.Leave(key, mine);
    }
}

/// <summary>A run failed by an HTTP answer: <c>HTTP 503 Service Unavailable</c>.</summary>
internal static class HttpFailure
{
    private static readonly Dictionary<int, string> Reasons = new()
    {
        [400] = "Bad Request",
        [401] = "Unauthorized",
        [402] = "Payment Required",
        [403] = "Forbidden",
        [404] = "Not Found",
        [405] = "Method Not Allowed",
        [406] = "Not Acceptable",
        [407] = "Proxy Authentication Required",
        [408] = "Request Timeout",
        [409] = "Conflict",
        [410] = "Gone",
        [411] = "Length Required",
        [412] = "Precondition Failed",
        [413] = "Content Too Large",
        [414] = "URI Too Long",
        [415] = "Unsupported Media Type",
        [416] = "Range Not Satisfiable",
        [417] = "Expectation Failed",
        [421] = "Misdirected Request",
        [422] = "Unprocessable Content",
        [426] = "Upgrade Required",
        [500] = "Internal Server Error",
        [501] = "Not Implemented",
        [502] = "Bad Gateway",
        [503] = "Service Unavailable",
        [504] = "Gateway Timeout",
        [505] = "HTTP Version Not Supported",
    };

    /// <summary>The failure for a status, null below 400: the reason given, else RFC 9110's.</summary>
    public static string? Text(int status, string? reason = null)
    {
        if (status < 400)
        {
            return null;
        }
        string head = "HTTP " + status.ToString(CultureInfo.InvariantCulture);
        if (!string.IsNullOrEmpty(reason))
        {
            return head + " " + reason;
        }
        return Reasons.TryGetValue(status, out string? r) ? head + " " + r : head;
    }

    /// <summary>The failure a function's value stands for, or null.</summary>
    public static string? Of(object? value) => value switch
    {
        HttpResponseMessage m => Text((int)m.StatusCode, m.ReasonPhrase),
        Web.WebResponse w => Text(w.Status),
        _ => null,
    };
}
