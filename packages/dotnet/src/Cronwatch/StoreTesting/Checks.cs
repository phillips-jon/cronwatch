using System;
using System.Collections.Generic;
using System.Linq;
using System.Threading.Tasks;
using Cronwatch.Internal;

namespace Cronwatch.StoreTesting;

/// <summary>
/// What a store got wrong under <see cref="StoreContract"/> (or the deprecated <c>StoreReplay</c>
/// and <c>FinishOnce</c>). Every test framework reports it as a failure.
/// </summary>
public sealed class StoreContractException : Exception
{
    /// <summary>A failure with no message.</summary>
    public StoreContractException()
    {
    }

    /// <summary>A failure with this message.</summary>
    public StoreContractException(string message)
        : base(message)
    {
    }

    /// <summary>A failure with this message and the store's exception.</summary>
    public StoreContractException(string message, Exception innerException)
        : base(message, innerException)
    {
    }
}

/// <summary>What the contract and the replay share: store calls that fail as assertions, and comparisons.</summary>
internal static class Checks
{
    /// <summary>The call's answer, or a failure naming what failed, with the store's exception inside.</summary>
    public static async Task<T> Get<T>(string what, Func<Task<T>> call)
    {
        try
        {
            return await call().ConfigureAwait(false);
        }
        catch (Exception e) when (e is not StoreContractException)
        {
            throw new StoreContractException(what + ": the store threw " + e.GetType().Name + ": " + e.Message, e);
        }
    }

    /// <summary>The call, or a failure naming what failed.</summary>
    public static async Task Must(string what, Func<Task> call)
    {
        try
        {
            await call().ConfigureAwait(false);
        }
        catch (Exception e) when (e is not StoreContractException)
        {
            throw new StoreContractException(what + ": the store threw " + e.GetType().Name + ": " + e.Message, e);
        }
    }

    /// <summary>Fails unless the two are equal.</summary>
    public static void Eq<T>(string what, T got, T want)
    {
        if (!EqualityComparer<T>.Default.Equals(got, want))
        {
            throw new StoreContractException(what + ":\n  got  " + got + "\n  want " + want);
        }
    }

    /// <summary>Fails unless the two lists hold the same items in order.</summary>
    public static void EqList(string what, IEnumerable<string> got, params string[] want)
    {
        var g = got.ToList();
        if (!g.SequenceEqual(want, StringComparer.Ordinal))
        {
            throw new StoreContractException(what + ":\n  got  [" + string.Join(", ", g) + "]\n  want [" + string.Join(", ", want) + "]");
        }
    }

    public static IEnumerable<string> Ids(IReadOnlyList<Run> runs) => runs.Select(r => r.Id);

    public static string JsonOf(Run? run) => run == null ? "null" : run.ToJson();

    public static string JsonOf(JobState? state) => state == null ? "null" : state.ToJson();

    /// <summary>
    /// JSON with every object's keys sorted, so two values compare whatever order a JSON column
    /// (Postgres's JSONB) gave an object's keys back in. Text that is not JSON is itself.
    /// </summary>
    public static string Canonical(string text)
    {
        try
        {
            return Write(Json.Parse(text));
        }
        catch (JsonParseException)
        {
            return text;
        }
    }

    private static string Write(object? v)
    {
        if (v is JsObject o)
        {
            var pairs = o.ToList();
            pairs.Sort((a, b) => string.CompareOrdinal(a.Key, b.Key));
            return "{" + string.Join(",", pairs.Select(e => JsonText.Quote(e.Key) + ":" + Write(e.Value))) + "}";
        }
        if (v is List<object?> list)
        {
            return "[" + string.Join(",", list.Select(Write)) + "]";
        }
        return Json.Stringify(v);
    }

    /// <summary>Fails unless two JSON texts are the same value, keys in any order.</summary>
    public static void SameJson(string what, string got, string want)
    {
        if (Canonical(got) != Canonical(want))
        {
            throw new StoreContractException(what + ":\n  got  " + got + "\n  want " + want);
        }
    }
}
