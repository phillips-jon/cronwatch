using System.Collections.Generic;
using System.Threading;
using System.Threading.Tasks;

namespace Cronwatch;

/// <summary>
/// Where jobs, runs and state live: the SDK's <c>Store</c>. <see cref="MemoryStore"/> is one, and
/// <c>SqlStore</c> keeps them in the app's own database. A store of the app's own should
/// pass <c>Cronwatch.StoreTesting.StoreContract</c>.
/// </summary>
/// <remarks>
/// Every method may be called from any number of threads at once. Any exception is the store's
/// failure: the client reports it to its error handler and carries on, and never lets it stop a
/// job. A store holds text without U+0000: it drops every NUL from a run's trigger, output, error
/// and metric names, and from every key and string of a definition and a state, as it writes
/// them. The conditional writes are the optional <see cref="IConditionalRunStore"/>,
/// <see cref="IStateCasStore"/> and <see cref="IRunDeletingStore"/>; without them the client
/// falls back to a read and a write, as the SDK does. A store that holds something is
/// <see cref="System.IAsyncDisposable"/>, and the client disposes it with itself.
/// </remarks>
public interface IStore
{
    /// <summary>Called once before first use: create tables here.</summary>
    Task InitAsync(CancellationToken cancellationToken = default);

    /// <summary>Writes a job's definition, keeping its <c>createdAt</c> when it is already stored.</summary>
    Task UpsertJobAsync(Definition definition, long now, CancellationToken cancellationToken = default);

    /// <summary>The job, or null when the store does not know it.</summary>
    Task<StoredJob?> GetJobAsync(string name, CancellationToken cancellationToken = default);

    /// <summary>Every job, by name in UTF-16 code unit order.</summary>
    Task<IReadOnlyList<StoredJob>> ListJobsAsync(CancellationToken cancellationToken = default);

    /// <summary>Removes a job, its runs and its state.</summary>
    Task DeleteJobAsync(string name, CancellationToken cancellationToken = default);

    /// <summary>Inserts a run, refusing an id already stored.</summary>
    Task InsertRunAsync(Run run, CancellationToken cancellationToken = default);

    /// <summary>Writes a run's status, finish, duration, error, output and metrics. A run that is gone stays gone.</summary>
    Task UpdateRunAsync(Run run, CancellationToken cancellationToken = default);

    /// <summary>The run, or null when there is no such run.</summary>
    Task<Run?> GetRunAsync(string id, CancellationToken cancellationToken = default);

    /// <summary>A job's newest runs first (ties broken newest inserted first), at most <paramref name="limit"/>.</summary>
    Task<IReadOnlyList<Run>> ListRunsAsync(string job, int limit, CancellationToken cancellationToken = default);

    /// <summary>A job's newest run, or null.</summary>
    Task<Run?> LastRunAsync(string job, CancellationToken cancellationToken = default);

    /// <summary>Every run still running, oldest first.</summary>
    Task<IReadOnlyList<Run>> RunningRunsAsync(CancellationToken cancellationToken = default);

    /// <summary>A job's state, or null when it has none yet.</summary>
    Task<JobState?> GetStateAsync(string job, CancellationToken cancellationToken = default);

    /// <summary>Writes a job's state unconditionally; used only without <see cref="IStateCasStore"/>.</summary>
    Task SetStateAsync(JobState state, CancellationToken cancellationToken = default);

    /// <summary>
    /// Deletes finished runs that started before this time, keeping each job's newest run whatever
    /// its age, and answers how many.
    /// </summary>
    Task<long> PruneAsync(long before, CancellationToken cancellationToken = default);
}

/// <summary>A store that writes a run only over a stored status it names, in one step.</summary>
public interface IConditionalRunStore
{
    /// <summary>
    /// Writes the run as <see cref="IStore.UpdateRunAsync"/> does, only when its stored status is
    /// one of <paramref name="from"/> (SQL: <c>UPDATE ... WHERE id = ? AND status IN (...)</c>),
    /// and says whether it wrote. This lets exactly one of several processes finishing the same run
    /// evaluate it.
    /// </summary>
    Task<bool> UpdateRunIfAsync(Run run, IReadOnlyList<RunStatus> from, CancellationToken cancellationToken = default);
}

/// <summary>A store that writes a state only over the version it was read at.</summary>
public interface IStateCasStore
{
    /// <summary>
    /// Writes <paramref name="state"/> only when the stored state's version (absent, or no row,
    /// counts as 0; see <see cref="JobState.CountedVersion"/>) equals <paramref name="expected"/>,
    /// and says whether it wrote.
    /// </summary>
    Task<bool> CompareAndSetStateAsync(JobState state, long expected, CancellationToken cancellationToken = default);
}

/// <summary>A store that deletes a run given back, only while it is as it was.</summary>
public interface IRunDeletingStore
{
    /// <summary>
    /// Deletes the run <paramref name="id"/> only when its stored job is <paramref name="job"/>
    /// and its status <paramref name="status"/> (SQL: <c>DELETE ... WHERE id = ? AND job = ? AND
    /// status = ?</c>), and says whether it deleted.
    /// </summary>
    Task<bool> DeleteRunIfAsync(string id, string job, RunStatus status, CancellationToken cancellationToken = default);
}
