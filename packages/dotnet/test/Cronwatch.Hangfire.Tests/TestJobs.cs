using System;
using System.Collections.Concurrent;
using System.Threading;
using System.Threading.Tasks;
using Hangfire;

namespace Cronwatch.Hangfire.Tests;

/// <summary>The jobs the tests give Hangfire, and what they saw.</summary>
public static class TestJobs
{
    public static readonly ConcurrentDictionary<string, int> Attempts = new(StringComparer.Ordinal);

    /// <summary>What <see cref="CronwatchClient.Current"/> was inside a job, by the key it was given.</summary>
    public static readonly ConcurrentDictionary<string, string> Seen = new(StringComparer.Ordinal);

    public static TaskCompletionSource Started { get; set; } = new(TaskCreationOptions.RunContinuationsAsynchronously);

    /// <summary>Fails its first two attempts, logging each through the current run.</summary>
    [AutomaticRetry(Attempts = 3, DelaysInSeconds = [1])]
    public static void Flaky(string key)
    {
        int attempt = Attempts.AddOrUpdate(key, 1, (_, n) => n + 1);
        CronwatchClient.Current?.Log("attempt " + attempt);
        if (attempt <= 2)
        {
            throw new InvalidOperationException("attempt " + attempt + " failed");
        }
    }

    /// <summary>Awaits, then logs through the current run, from the continuation.</summary>
    public static async Task AsyncWork(string key)
    {
        await Task.Delay(20).ConfigureAwait(false);
        Seen[key] = CronwatchClient.Current?.RunId ?? "none";
        CronwatchClient.Current?.Log("written after an await");
    }

    /// <summary>Notes the current run, whatever it is.</summary>
    public static void Look(string key) => Seen[key] = CronwatchClient.Current?.RunId ?? "none";

    /// <summary>Waits for the server's shutdown.</summary>
    public static async Task Sleepy(CancellationToken token)
    {
        Started.TrySetResult();
        await Task.Delay(Timeout.Infinite, token).ConfigureAwait(false);
    }

    /// <summary>A job the tests name with the attribute.</summary>
    [CronwatchJob("import")]
    public static void Import() => CronwatchClient.Current?.Log("imported");

    /// <summary>A job that does nothing, for recurring jobs whose runs the tests do not need.</summary>
    public static void Nothing()
    {
    }
}

/// <summary>A job whose type the tests make fail to load, as a deploy that removed it would.</summary>
public static class BrokenJob
{
    public static void Run()
    {
    }
}
