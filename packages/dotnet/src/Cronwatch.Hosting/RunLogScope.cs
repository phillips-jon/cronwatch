using System;
using System.Collections;
using System.Collections.Generic;

namespace Cronwatch.Hosting;

/// <summary>
/// The log scope around a run's function: <c>cronwatch_job</c> and <c>cronwatch_run</c>, as a
/// structured logger reads a scope's pairs, written <c>cronwatch_job=nightly cronwatch_run=...</c>
/// by one that prints it.
/// </summary>
internal sealed class RunLogScope(string job, string run) : IReadOnlyList<KeyValuePair<string, object?>>
{
    public KeyValuePair<string, object?> this[int index] => index switch
    {
        0 => new("cronwatch_job", job),
        1 => new("cronwatch_run", run),
        _ => throw new ArgumentOutOfRangeException(nameof(index)),
    };

    public int Count => 2;

    public IEnumerator<KeyValuePair<string, object?>> GetEnumerator()
    {
        yield return this[0];
        yield return this[1];
    }

    IEnumerator IEnumerable.GetEnumerator() => GetEnumerator();

    public override string ToString() => "cronwatch_job=" + job + " cronwatch_run=" + run;
}
