using System;
using System.Collections.Generic;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;
using Cronwatch.Internal;

namespace Cronwatch;

/// <summary>
/// Keeps everything in process memory (the SDK's <c>stores/memory.ts</c>). The default when no
/// store is given, good for tests and for trying the library out. State is gone on restart, so a
/// missed run cannot be noticed across one. Its values are immutable records, so what goes in and
/// out needs no copying.
/// </summary>
public sealed class MemoryStore : IStore, IUpdateRunIfStore, ICompareAndSetStateStore, IDeleteRunIfStore,
#pragma warning disable CS0618 // the former names, kept through 1.x
    IConditionalRunStore, IStateCasStore, IRunDeletingStore
#pragma warning restore CS0618
{
    private readonly Lock _lock = new();
    private readonly Dictionary<string, StoredJob> _jobs = new(StringComparer.Ordinal);

    // Each run and the order it was inserted in, which breaks ties between runs that started in
    // the same millisecond.
    private readonly Dictionary<string, (Run Run, long Seq)> _runs = new(StringComparer.Ordinal);
    private readonly Dictionary<string, JobState> _states = new(StringComparer.Ordinal);
    private long _seq;

    // Text is held as the SQL store writes it, without U+0000, so every store reads back the
    // same: a run's trigger, output, error, and metric names, and every key and string of a
    // definition and a state. Identifiers are held as given.

    private static Definition Kept(Definition definition)
    {
        string json = definition.ToJson();
        string clean = NulText.StripJsonNul(json);
        return clean == json ? definition : Definition.FromJson(clean);
    }

    private static JobState Kept(JobState state)
    {
        string json = state.ToJson();
        string clean = NulText.StripJsonNul(json);
        return clean == json ? state : JobState.FromJson(clean);
    }

    private static Metrics Kept(Metrics metrics)
    {
        string json = metrics.ToJson();
        string clean = NulText.StripJsonNul(json);
        return clean == json ? metrics : Metrics.Lenient(Json.Parse(clean));
    }

    private static Run Kept(Run run) => run with
    {
        Error = NulText.StripNulOrNull(run.Error),
        Output = NulText.StripNulOrNull(run.Output),
        Metrics = Kept(run.Metrics),
        Trigger = NulText.StripNul(run.Trigger),
    };

    /// <inheritdoc/>
    public Task InitAsync(CancellationToken cancellationToken = default) => Task.CompletedTask;

    /// <inheritdoc/>
    public Task UpsertJobAsync(Definition definition, long now, CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(definition);
        lock (_lock)
        {
            string name = definition.Name;
            long createdAt = _jobs.TryGetValue(name, out var existing) ? existing.CreatedAt : now;
            _jobs[name] = new StoredJob(name, Kept(definition), createdAt, now);
        }
        return Task.CompletedTask;
    }

    /// <inheritdoc/>
    public Task<StoredJob?> GetJobAsync(string name, CancellationToken cancellationToken = default)
    {
        lock (_lock)
        {
            return Task.FromResult(_jobs.TryGetValue(name, out var j) ? j : null);
        }
    }

    /// <summary>Every job by name in UTF-16 code unit order, JavaScript's default sort.</summary>
    public Task<IReadOnlyList<StoredJob>> ListJobsAsync(CancellationToken cancellationToken = default)
    {
        List<StoredJob> output;
        lock (_lock)
        {
            output = [.. _jobs.Values];
        }
        output.Sort((a, b) => string.CompareOrdinal(a.Name, b.Name));
        return Task.FromResult<IReadOnlyList<StoredJob>>(output);
    }

    /// <inheritdoc/>
    public Task DeleteJobAsync(string name, CancellationToken cancellationToken = default)
    {
        lock (_lock)
        {
            _jobs.Remove(name);
            _states.Remove(name);
            foreach (var id in _runs.Where(e => e.Value.Run.Job == name).Select(e => e.Key).ToList())
            {
                _runs.Remove(id);
            }
        }
        return Task.CompletedTask;
    }

    /// <summary>Inserts a run, refusing an id already recorded, like SQL's primary key.</summary>
    public Task InsertRunAsync(Run run, CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(run);
        lock (_lock)
        {
            if (_runs.ContainsKey(run.Id))
            {
                throw new InvalidOperationException("run " + run.Id + " already exists");
            }
            _runs[run.Id] = (Kept(run), ++_seq);
        }
        return Task.CompletedTask;
    }

    /// <summary>Changes only the finish's fields; a run that is gone (its job was forgotten) stays gone.</summary>
    public Task UpdateRunAsync(Run run, CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(run);
        lock (_lock)
        {
            if (_runs.TryGetValue(run.Id, out var e))
            {
                _runs[run.Id] = (Finish(e.Run, run), e.Seq);
            }
        }
        return Task.CompletedTask;
    }

    /// <inheritdoc/>
    public Task<bool> UpdateRunIfAsync(Run run, IReadOnlyList<RunStatus> from, CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(run);
        ArgumentNullException.ThrowIfNull(from);
        lock (_lock)
        {
            if (!_runs.TryGetValue(run.Id, out var e) || !from.Contains(e.Run.Status))
            {
                return Task.FromResult(false);
            }
            _runs[run.Id] = (Finish(e.Run, run), e.Seq);
            return Task.FromResult(true);
        }
    }

    /// <inheritdoc/>
    public Task<bool> DeleteRunIfAsync(string id, string job, RunStatus status, CancellationToken cancellationToken = default)
    {
        lock (_lock)
        {
            if (!_runs.TryGetValue(id, out var e) || e.Run.Job != job || e.Run.Status != status)
            {
                return Task.FromResult(false);
            }
            _runs.Remove(id);
            return Task.FromResult(true);
        }
    }

    // The fields a finish changes, written onto a stored run.
    private static Run Finish(Run existing, Run run) => existing with
    {
        Status = run.Status,
        FinishedAt = run.FinishedAt,
        DurationMs = run.DurationMs,
        Error = NulText.StripNulOrNull(run.Error),
        Output = NulText.StripNulOrNull(run.Output),
        Metrics = Kept(run.Metrics),
    };

    /// <inheritdoc/>
    public Task<Run?> GetRunAsync(string id, CancellationToken cancellationToken = default)
    {
        lock (_lock)
        {
            return Task.FromResult(_runs.TryGetValue(id, out var e) ? e.Run : null);
        }
    }

    private List<Run> Sorted(Func<Run, bool> keep, bool newestFirst)
    {
        List<(Run Run, long Seq)> output;
        lock (_lock)
        {
            output = _runs.Values.Where(e => keep(e.Run)).ToList();
        }
        output.Sort((a, b) =>
        {
            int c = a.Run.StartedAt.CompareTo(b.Run.StartedAt);
            if (c == 0)
            {
                c = a.Seq.CompareTo(b.Seq);
            }
            return newestFirst ? -c : c;
        });
        return output.Select(e => e.Run).ToList();
    }

    /// <inheritdoc/>
    public Task<IReadOnlyList<Run>> ListRunsAsync(string job, int limit, CancellationToken cancellationToken = default)
    {
        var output = Sorted(r => r.Job == job, true);
        if (output.Count > limit)
        {
            output = output.GetRange(0, Math.Max(0, limit));
        }
        return Task.FromResult<IReadOnlyList<Run>>(output);
    }

    /// <inheritdoc/>
    public Task<Run?> LastRunAsync(string job, CancellationToken cancellationToken = default)
    {
        var output = Sorted(r => r.Job == job, true);
        return Task.FromResult(output.Count == 0 ? null : output[0]);
    }

    /// <inheritdoc/>
    public Task<IReadOnlyList<Run>> RunningRunsAsync(CancellationToken cancellationToken = default) =>
        Task.FromResult<IReadOnlyList<Run>>(Sorted(r => r.Status == RunStatus.Running, false));

    /// <inheritdoc/>
    public Task<JobState?> GetStateAsync(string job, CancellationToken cancellationToken = default)
    {
        lock (_lock)
        {
            return Task.FromResult(_states.TryGetValue(job, out var s) ? s : null);
        }
    }

    /// <inheritdoc/>
    public Task SetStateAsync(JobState state, CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(state);
        var kept = Kept(state);
        lock (_lock)
        {
            _states[state.Job] = kept;
        }
        return Task.CompletedTask;
    }

    /// <inheritdoc/>
    public Task<bool> CompareAndSetStateAsync(JobState state, long expected, CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(state);
        var kept = Kept(state);
        lock (_lock)
        {
            long version = _states.TryGetValue(state.Job, out var current) ? current.CountedVersion : 0;
            if (version != expected)
            {
                return Task.FromResult(false);
            }
            _states[state.Job] = kept;
            return Task.FromResult(true);
        }
    }

    /// <summary>
    /// Deletes finished runs that started before this time, keeping each job's newest run whatever
    /// its age: without it, a job that runs less often than the retention looks like it never ran.
    /// </summary>
    public Task<long> PruneAsync(long before, CancellationToken cancellationToken = default)
    {
        lock (_lock)
        {
            var newest = new Dictionary<string, long>(StringComparer.Ordinal);
            foreach (var (run, _) in _runs.Values)
            {
                newest[run.Job] = newest.TryGetValue(run.Job, out long n) ? Math.Max(n, run.StartedAt) : run.StartedAt;
            }
            var gone = _runs
                .Where(e => e.Value.Run.Status != RunStatus.Running && e.Value.Run.StartedAt < before && e.Value.Run.StartedAt < newest[e.Value.Run.Job])
                .Select(e => e.Key)
                .ToList();
            foreach (var id in gone)
            {
                _runs.Remove(id);
            }
            return Task.FromResult((long)gone.Count);
        }
    }
}
