using System;

namespace Cronwatch.Internal;

/// <summary>
/// A job's <c>matches /source/flags</c> expect rule on the engine: compiled when an app gives
/// one, read back from a stored definition, and checked against a run's output within the
/// engine's budget.
/// </summary>
internal static class ExpectPatterns
{
    /// <summary>
    /// The pattern an app gave, compiled.
    /// </summary>
    /// <exception cref="ArgumentException">When the engine cannot read it, with the text the
    /// client refuses it with (<c>expect: /source/flags is not a pattern CronWatch can read:
    /// ...</c>).</exception>
    public static JsRegex Compile(string source, string flags)
    {
        try
        {
            return JsRegex.Compile(source, flags);
        }
        catch (ArgumentException e)
        {
            throw new ArgumentException(
                "expect: /" + source + "/" + flags + " is not a pattern CronWatch can read: " + e.Message, e);
        }
    }

    /// <summary>
    /// A stored description <c>matches /source/flags</c> read back: the pattern when the engine
    /// reads it and writes it back as it was stored, else null, and the rule is then kept as
    /// stored, passing every output.
    /// </summary>
    public static JsRegex? FromStored(string description)
    {
        const string Prefix = "matches ";
        if (!description.StartsWith(Prefix, StringComparison.Ordinal))
        {
            return null;
        }
        string pattern = description[Prefix.Length..];
        int end = pattern.LastIndexOf('/');
        if (!pattern.StartsWith('/') || end <= 0)
        {
            return null;
        }
        try
        {
            var r = JsRegex.Compile(pattern[1..end], pattern[(end + 1)..]);
            return string.Equals(Prefix + r, description, StringComparison.Ordinal) ? r : null;
        }
        catch (ArgumentException)
        {
            return null;
        }
    }

    /// <summary>
    /// Null when the pattern matches somewhere in the output, else why not. A match that gives up
    /// (past its step budget or its frames) does not match: a pattern is slow because it is
    /// searching an output it does not match.
    /// </summary>
    public static string? Check(JsRegex pattern, string output) =>
        pattern.TryTest(output) == true ? null : "Output did not match " + pattern;

    /// <summary>The stored description of the rule: <c>matches /source/flags</c>.</summary>
    public static string Describe(JsRegex pattern) => "matches " + pattern;
}
