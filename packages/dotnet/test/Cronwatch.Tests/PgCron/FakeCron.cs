using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.Globalization;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;
using Cronwatch.PgCron;

namespace Cronwatch.Tests.PgCron;

/// <summary>
/// <c>cron.job</c> and <c>cron.job_run_details</c> in memory, answering the source's queries as the
/// SDK's <c>fakeCron()</c> does: ids as text, as some drivers hand a <c>bigint</c> back, and times
/// as <see cref="DateTime"/>s, as Npgsql hands a <c>timestamptz</c> back.
/// </summary>
internal sealed class FakeCron
{
    /// <summary>A row of <c>cron.job</c>, changed in place by the tests.</summary>
    public sealed class Job(long jobId, string? jobName, string schedule, bool active)
    {
        public long JobId { get; } = jobId;

        public string? JobName { get; set; } = jobName;

        public string Schedule { get; } = schedule;

        public bool Active { get; set; } = active;
    }

    /// <summary>A row of <c>cron.job_run_details</c>, changed in place by the tests.</summary>
    public sealed class Detail(long runId, long jobId, string status, long? start, long? end, string? message)
    {
        public long RunId { get; } = runId;

        public long JobId { get; } = jobId;

        public string Status { get; set; } = status;

        public string? Message { get; set; } = message;

        public long? Start { get; set; } = start;

        public long? End { get; set; } = end;
    }

    private long _runId;

    public List<Job> Jobs { get; } = [];

    public List<Detail> Details { get; } = [];

    public Dictionary<string, string?> Settings { get; } = new(StringComparer.Ordinal)
    {
        ["cron.timezone"] = "GMT",
        ["cron.log_run"] = "on",
    };

    public ConcurrentQueue<string> Queries { get; } = new();

    /// <summary>The open run ids each details query asked for, in order.</summary>
    public ConcurrentQueue<List<long>> Opened { get; } = new();

    public Job AddJob(long jobId, string? jobName, string schedule, bool active = true)
    {
        var j = new Job(jobId, jobName, schedule, active);
        lock (Jobs)
        {
            Jobs.Add(j);
        }
        return j;
    }

    public Detail Add(long jobId, string status, long? start, long? end, string? message = null)
    {
        lock (Details)
        {
            var d = new Detail(++_runId, jobId, status, start, end, message);
            Details.Add(d);
            return d;
        }
    }

    /// <summary>A source over this fake.</summary>
    public PgCronSource Source(PgCronOptions? options = null) => new(Query, options);

    private static DateTime? When(long? ms) => ms is { } m ? DateTime.UnixEpoch.AddMilliseconds(m) : null;

    private static Dictionary<string, object?> Row(Detail d) => new(StringComparer.Ordinal)
    {
        ["runid"] = d.RunId.ToString(CultureInfo.InvariantCulture),
        ["jobid"] = d.JobId.ToString(CultureInfo.InvariantCulture),
        ["status"] = d.Status,
        ["return_message"] = d.Message,
        ["start_time"] = When(d.Start),
        ["end_time"] = When(d.End),
    };

    /// <summary>An array literal, <c>{1,2,3}</c>, as the numbers it holds.</summary>
    private static List<long> Array(object literal)
    {
        string s = (string)literal;
        string inner = s[1..^1];
        return inner.Length == 0 ? [] : inner.Split(',').Select(p => long.Parse(p, CultureInfo.InvariantCulture)).ToList();
    }

    private Task<List<Dictionary<string, object?>>> Query(string sql, object[] parameters, CancellationToken cancellationToken)
    {
        Queries.Enqueue(sql);
        var output = new List<Dictionary<string, object?>>();
        List<Detail> details;
        lock (Details)
        {
            details = [.. Details];
        }
        if (sql.Contains("pg_settings", StringComparison.Ordinal))
        {
            if (Settings.TryGetValue((string)parameters[0], out string? value) && value != null)
            {
                output.Add(new(StringComparer.Ordinal) { ["setting"] = value });
            }
        }
        else if (sql.Contains("FROM cron.job ORDER BY", StringComparison.Ordinal))
        {
            List<Job> jobs;
            lock (Jobs)
            {
                jobs = [.. Jobs];
            }
            foreach (Job j in jobs)
            {
                output.Add(new(StringComparer.Ordinal)
                {
                    ["jobid"] = j.JobId.ToString(CultureInfo.InvariantCulture),
                    ["jobname"] = j.JobName,
                    ["schedule"] = j.Schedule,
                    ["database"] = "postgres",
                    ["username"] = "postgres",
                    ["active"] = j.Active,
                });
            }
        }
        else if (sql.Contains("ORDER BY d.runid DESC", StringComparison.Ordinal))
        {
            long jobId = (long)parameters[0];
            output.AddRange(details.Where(d => d.JobId == jobId).OrderByDescending(d => d.RunId).Take(20).Select(Row));
        }
        else if (sql.Contains("unnest", StringComparison.Ordinal))
        {
            List<long> ids = Array(parameters[0]);
            List<long> afters = Array(parameters[1]);
            Opened.Enqueue(Array(parameters[2]));
            var open = Array(parameters[2]).ToHashSet();
            var after = new Dictionary<long, long>();
            for (int i = 0; i < ids.Count; i++)
            {
                after[ids[i]] = afters[i];
            }
            output.AddRange(details
                .Where(d => (after.TryGetValue(d.JobId, out long a) && d.RunId > a) || open.Contains(d.RunId))
                .OrderBy(d => d.RunId)
                .Take(500)
                .Select(Row));
        }
        else
        {
            throw new InvalidOperationException("unexpected query " + sql);
        }
        return Task.FromResult(output);
    }
}
