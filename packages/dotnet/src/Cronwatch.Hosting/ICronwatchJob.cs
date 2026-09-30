using System.Threading;
using System.Threading.Tasks;

namespace Cronwatch;

/// <summary>
/// A job run on its schedule inside the host by <c>AddCronwatchJob</c>: its class is resolved
/// from a new DI scope for each run and disposed after it.
/// </summary>
public interface ICronwatchJob
{
    /// <summary>
    /// Runs the job once. <paramref name="cancellationToken"/> is cancelled at the job's timeout
    /// and when the host stops. Any exception is a failed run.
    /// </summary>
    Task RunAsync(JobContext job, CancellationToken cancellationToken);
}
