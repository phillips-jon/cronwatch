using System;
using Cronwatch.Internal;

namespace Cronwatch;

/// <summary>
/// What a successful run's output must show, or the run counts as failed: text it must contain
/// (a <see cref="string"/> converts implicitly), a JavaScript pattern it must match
/// (<see cref="Matches"/>), or a check of the app's own (<see cref="That"/>). Catches the job that
/// exits cleanly and did nothing.
/// </summary>
public abstract class Expect
{
    private protected Expect()
    {
    }

    /// <summary>The output must contain <paramref name="text"/>.</summary>
    public static implicit operator Expect(string text) => Contains(text);

    /// <summary>The output must contain <paramref name="text"/> (stored as <c>contains "text"</c>).</summary>
    public static Expect Contains(string text) => new ContainsRule(text ?? throw new ArgumentNullException(nameof(text)));

    /// <summary>
    /// The output must match the JavaScript pattern <c>/source/flags</c> (stored as
    /// <c>matches /source/flags</c>), read by CronWatch's own engine with JavaScript's semantics,
    /// so a stored pattern reads the same in every port. A match that searches too long counts as
    /// no match.
    /// </summary>
    /// <exception cref="CronwatchException">Of kind <see cref="CronwatchErrorKind.Invalid"/> for a pattern the engine cannot read.</exception>
    public static Expect Matches(string source, string flags = "")
    {
        try
        {
            return new MatchRule(ExpectPatterns.Compile(source, flags));
        }
        catch (ArgumentException e)
        {
            throw CronwatchException.Invalid(e.Message);
        }
    }

    /// <summary>
    /// The output must pass <paramref name="check"/> (stored as <c>custom function</c>); a throw in
    /// it fails the run with <c>Output check threw: ...</c>.
    /// </summary>
    public static Expect That(Func<string, bool> check) => new ThatRule(check ?? throw new ArgumentNullException(nameof(check)));

    /// <summary>Why the output fails the rule, or null when it passes.</summary>
    internal abstract string? Check(string output);

    /// <summary>The rule as stored in a definition.</summary>
    internal abstract string Describe();

    /// <summary>The rule as stored.</summary>
    public override string ToString() => Describe();

    /// <summary>The SDK's <c>checkExpectation</c>: null output is checked as empty.</summary>
    internal static string? CheckExpectation(Expect? rule, string? output) => rule?.Check(output ?? "");

    /// <summary>
    /// A definition's fields with <c>expect</c> taken out and written last as the rule describes
    /// itself: the SDK's <c>toStored</c>.
    /// </summary>
    internal static Definition ToStored(JsObject fields, Expect? rule)
    {
        var output = new JsObject();
        foreach (var e in fields)
        {
            if (e.Key != "expect")
            {
                output.Set(e.Key, Json.Copy(e.Value));
            }
        }
        if (rule != null)
        {
            output.Set("expect", rule.Describe());
        }
        return Definition.Own(output);
    }

    /// <summary>
    /// A rule read back from a stored definition, for a process whose job another process declared:
    /// <c>contains "text"</c> as the same rule, a pattern the engine reads as the same pattern, and
    /// anything else (a custom function, which is the other process's, or a pattern this engine
    /// does not read) kept as stored and passing every output.
    /// </summary>
    internal static Expect FromStored(string description)
    {
        const string Prefix = "contains ";
        if (description.StartsWith(Prefix, StringComparison.Ordinal))
        {
            try
            {
                if (Json.Parse(description[Prefix.Length..]) is string text && string.Equals(Prefix + Json.Quote(text), description, StringComparison.Ordinal))
                {
                    return new ContainsRule(text);
                }
            }
            catch (JsonParseException)
            {
                // Kept as stored, below.
            }
        }
        JsRegex? pattern = ExpectPatterns.FromStored(description);
        return pattern != null ? new MatchRule(pattern) : new StoredRule(description);
    }

    private sealed class StoredRule(string description) : Expect
    {
        internal override string? Check(string output) => null;

        internal override string Describe() => description;
    }

    private sealed class ContainsRule(string text) : Expect
    {
        internal override string? Check(string output) =>
            output.Contains(text, StringComparison.Ordinal) ? null : "Output did not contain " + Json.Quote(text);

        internal override string Describe() => "contains " + Json.Quote(text);
    }

    private sealed class MatchRule(JsRegex pattern) : Expect
    {
        internal override string? Check(string output) => ExpectPatterns.Check(pattern, output);

        internal override string Describe() => ExpectPatterns.Describe(pattern);
    }

    private sealed class ThatRule(Func<string, bool> check) : Expect
    {
        internal override string? Check(string output)
        {
            try
            {
                return check(output) ? null : "Output did not pass the expect() check";
            }
            catch (Exception e)
            {
                // Like the SDK's (error as Error).message: a throw with no message has an empty one.
                return "Output check threw: " + OutputText.MessageOf(e);
            }
        }

        internal override string Describe() => "custom function";
    }
}
