using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Threading;
using System.Threading.Tasks;
using Cronwatch.Internal;
using Xunit;

namespace Cronwatch.Tests;

/// <summary>
/// JavaScript's semantics the redaction and expect patterns rely on, each checked against what
/// V8 answers for the same pattern and input (written beside each case as the JavaScript
/// expression it mirrors), and the engine's bounds.
/// </summary>
public class JsRegexTests
{
    private const string Grin = "\ud83d\ude00";

    private static string Replace(string source, string flags, string input, string template) =>
        JsRegex.Compile(source, flags).Replace(input, template);

    public static TheoryData<string, string, string, string, string> Semantics => new()
    {
        // "abcd".replace(/ab|abc/g, "X"): the first alternative that matches wins, not the longest.
        { "ab|abc", "g", "abcd", "X", "Xcd" },
        // "aaab".replace(/a{1,3}ab/, "X"): greedy, then walked back.
        { "a{1,3}ab", "", "aaab", "X", "X" },
        { "a{2}", "g", "xaaa", "[$&]", "x[aa]a" },
        { "\\d", "g", "a1b2", "#", "a#b#" },
        { "\\d", "", "a1b2", "#", "a#b2" },
        // \b is between ASCII word characters and anything else.
        { "\\bab", "g", "ab xab -ab \u00e9ab", "X", "X xab -X \u00e9X" },
        { "\\Bab", "g", "ab xab", "X", "ab xX" },
        // "maxtokens=1 mytoken=2".replace(/\w+(?<!tokens)=\d/g, "X")
        { "\\w+(?<!tokens)=\\d", "g", "maxtokens=1 mytoken=2", "X", "maxtokens=1 X" },
        { "a(?!b)", "g", "ab ac a", "X", "ab Xc X" },
        { "a(?=b)", "g", "ab ac", "X", "Xb ac" },
        // Groups that did not take part are "" in a template.
        { "(a)|(b)", "g", "ab", "[$1|$2]", "[a|][|b]" },
        { "passw(?:or)?d", "g", "passwd password passwod", "X", "X X passwod" },
        { "(?:ab ){0,3}c", "g", "ab ab ab ab c", "X", "ab X" },
        // /i folds as Canonicalize: the long s (U+017F) and the Kelvin sign stay themselves.
        { "secret|key", "gi", "SECRET Key \u017fecret \u212aey", "X", "X X \u017fecret \u212aey" },
        { "[a-z]+", "gi", "AbC\u00c9", "X", "X\u00c9" },
        // ...but letters outside ASCII fold too: "\u00c9t\u00e9".replace(/\u00e9/gi, "e").
        { "\u00e9", "gi", "\u00c9t\u00e9", "e", "ete" },
        { "[\u00e0-\u00ff]+", "gi", "\u00c0\u00c9x", "X", "Xx" },
        { "[^\u00e9]", "gi", "\u00c9a", "X", "\u00c9X" },
        // \s is JavaScript's set: no-break space, ideographic space, line separator, BOM; not NEL.
        { "a\\sb", "g", "a\u00a0b a\u3000b a\u2028b a\ufeffb a\u0085b", "X", "X X X X a\u0085b" },
        // A negated class counts an emoji as two code units.
        { "x[^\\s]{3}", "g", "x" + Grin + Grin, "X", "X\ude00" },
        { "x[^\\s]{1,4}", "g", "xab" + Grin + Grin, "X", "X" + Grin },
        // Escaped punctuation, and "-" at the edge of a class.
        { "a\\/b\\.c[+/=-]", "g", "a/b.c- a/b.c=", "X", "X X" },
        // An empty match moves on one unit.
        { "x*", "g", "ab", "-", "-a-b-" },
        // "{" that is not a quantifier is a literal (Annex B).
        { "a{b", "g", "a{b", "X", "X" },
        { "a", "g", "a", "$$", "$" },
        // $` and $' are what come before and after the match; $0 is literal.
        { "b", "", "abc", "[$`|$'|$0]", "a[a|c|$0]c" },
        // Hex and four-digit escapes; an x escape without hex digits is the letter.
        { "\\x41\\u0042\\xz", "g", "ABxz", "X", "X" },
        // Anchors: $ matches only at the very end, never before a final newline.
        { "^a|a$", "g", "aba", "X", "XbX" },
        { "a$", "g", "a\n", "X", "a\n" },
        // [^] is any code unit at all.
        { "x[^]", "g", "x\nx\u2028", "X", "XX" },
    };

    [Theory]
    [MemberData(nameof(Semantics))]
    public void Semantics_are_javascripts(string source, string flags, string input, string template, string expected)
    {
        Assert.Equal(expected, Replace(source, flags, input, template));
    }

    [Fact]
    public void Replace_with_a_function()
    {
        var re = JsRegex.Compile("(k)=(?:(\")[^\"]*\"|(')[^']*'|\\w+)", "g");
        string got = re.Replace("k=\"a b\" k='c' k=d", m =>
        {
            string q = m.Group(2) != null ? m.Text(2) : m.Text(3);
            return m.Text(1) + "=" + q + "_" + q;
        });
        Assert.Equal("k=\"_\" k='_' k=_", got);
    }

    [Fact]
    public void Long_bounded_runs()
    {
        // A {0,16384} run is an ordinary bound, and a run of it does not grow the stack a frame
        // per character.
        var re = JsRegex.Compile("<(?:[a-z]|-(?!--)){0,16384}>?", "g");
        Assert.Equal("X", re.Replace("<" + Repeat("ab-", 5000) + ">", "X"));
        Assert.Equal("X---", re.Replace("<ab---", "X"));
        // 4096, then the rest, then the empty match at the end.
        Assert.Equal("XXX", JsRegex.Compile("a{0,4096}", "g").Replace(new string('a', 5000), "X"));
    }

    [Theory]
    [InlineData("(a")]
    [InlineData("a)")]
    [InlineData("*a")]
    [InlineData("[a")]
    [InlineData("a{3,1}")]
    [InlineData("a+?")]
    [InlineData("(?<!a+)b")]
    [InlineData("(?<=a)*b")]
    [InlineData("[z-a]")]
    [InlineData("(?<name>a)")]
    // JavaScript reads these as something other than the letter.
    [InlineData("(a)\\1")]
    [InlineData("\\cJ")]
    [InlineData("\\k<x>")]
    [InlineData("\\p{L}")]
    [InlineData("\\u{41}")]
    [InlineData("[\\2]")]
    [InlineData("\\01")]
    public void What_it_cannot_read_is_refused(string source)
    {
        Assert.Throws<ArgumentException>(() => JsRegex.Compile(source, "g"));
    }

    [Fact]
    public void Unknown_flags_are_refused()
    {
        Assert.Throws<ArgumentException>(() => JsRegex.Compile("a", "y"));
    }

    [Fact]
    public void Matches_and_writes_itself()
    {
        var re = JsRegex.Compile("b+", "gi");
        Assert.True(re.TryTest("aBc"));
        Assert.False(re.TryTest("ac"));
        Assert.True(re.Test("abc"));
        Assert.False(re.Test("ac"));
        Assert.Equal("/b+/gi", re.ToString());
    }

    [Fact]
    public void A_character_outside_the_bmp_is_its_two_units_in_turn()
    {
        // /a\ud83d\ude00b/.test("a\ud83d\ude00b"), and "x\ud83d\ude00\ud83d\ude00y".replace(/\ud83d\ude00{2}/g, "-"): the quantifier takes the
        // second unit alone, as V8 reads a pattern without u.
        Assert.True(JsRegex.Compile("a" + Grin + "b", "").TryTest("a" + Grin + "b"));
        Assert.False(JsRegex.Compile("a" + Grin + "b", "").TryTest("ab"));
        Assert.Equal("x--y", Replace(Grin + "+", "g", "x" + Grin + Grin + "y", "-"));
        Assert.Equal("x" + Grin + Grin + "y", Replace(Grin + "{2}", "g", "x" + Grin + Grin + "y", "-"));
        // /[\ud83d\ude00-\ud83d\ude01]/ is a SyntaxError in V8: the range runs from \ude00 to \ud83d, out of order.
        Assert.Throws<ArgumentException>(() => JsRegex.Compile("[" + Grin + "-\ud83d\ude01]", ""));
        // /[\ud83d\ude00]/ holds its two units, each on its own: "\ud83d\ude00".replace(/[\ud83d\ude00]/g, "-") is "--".
        Assert.Equal("--", Replace("[" + Grin + "]", "g", Grin, "-"));
    }

    [Fact]
    public void Patterns_too_deep_or_long_are_refused()
    {
        string nested = new string('(', 2000) + "a" + new string(')', 2000);
        Assert.Contains("nested too deeply", Assert.Throws<ArgumentException>(() => JsRegex.Compile(nested, "")).Message);
        JsRegex.Compile(new string('(', 100) + "a" + new string(')', 100), "");
        Assert.Contains(
            "more than 4096 characters",
            Assert.Throws<ArgumentException>(() => JsRegex.Compile(new string('a', 5000), "")).Message);
        JsRegex.Compile(new string('a', 4096), "");
    }

    /// <summary>The answers a deep match gives: it gives up rather than overflow the thread's stack.</summary>
    private static List<bool?> DeepAnswers()
    {
        var re = JsRegex.Compile("(?:ab)*c", "");
        var counted = JsRegex.Compile("(?:xy){100000}", "");
        return
        [
            re.TryTest(Repeat("ab", 16_384) + "c"),
            re.TryTest(Repeat("ab", 100) + "c"),
            counted.TryTest(Repeat("xy", 100_000)),
        ];
    }

    private static void AssertDeepAnswers(List<bool?> answers)
    {
        Assert.Null(answers[0]);
        Assert.True(answers[1]);
        Assert.Null(answers[2]);
    }

    [Fact]
    public async Task Deep_matches_give_up_on_a_thread_pool_thread()
    {
        // A StackOverflowException cannot be caught and would end the process, so the 512 frames
        // must fit in a pool thread's stack, run unoptimized as it is the first time.
        var answers = await Task.Run(DeepAnswers);
        AssertDeepAnswers(answers);
    }

    [Fact]
    public void Deep_matches_give_up_on_a_thread_with_half_the_default_stack()
    {
        List<bool?>? answers = null;
        var t = new Thread(() => answers = DeepAnswers(), 512 * 1024);
        t.Start();
        t.Join();
        AssertDeepAnswers(answers!);
    }

    [Fact]
    public void A_match_that_backtracks_without_end_gives_up_within_its_steps()
    {
        // `\n*\n*\n*\n*\n*x` over newlines is some n^5 / 120 attempts; V8 takes seconds over 100.
        // Past the budget the match gives up, while a pattern with work to do answers in full.
        string newlines = new('\n', 32_000);
        var watch = Stopwatch.StartNew();
        Assert.Null(JsRegex.Compile("\\n*\\n*\\n*\\n*\\n*x", "").TryTest(newlines));
        Assert.Null(JsRegex.Compile(".*x", "").TryTest(new string('a', 32_000)));
        // The budget is counted in steps, not time; the bound only catches a match that never stops.
        Assert.True(watch.Elapsed < TimeSpan.FromSeconds(60), "gave up within a minute");
        Assert.False(JsRegex.Compile("\\n*\\n*\\n*\\n*\\n*x", "").TryTest(new string('\n', 20)));
        Assert.True(JsRegex.Compile("\\n*\\n*\\n*\\n*\\n*x", "").TryTest(newlines + "x"));
        Assert.True(JsRegex.Compile(".*done", "").TryTest(new string('a', 32_000) + "done"));
        // Redaction has no budget: its patterns are the SDK's own, bounded.
        string a = new('a', 4_000);
        Assert.Equal(a, JsRegex.Compile(".*x", "g").Replace(a, ""));
        Assert.Null(JsRegex.Compile(".*x", "g").TryReplace(new string('a', 32_000), ""));
    }

    [Fact]
    public void Stored_patterns_read_back_as_they_were_stored()
    {
        var r = ExpectPatterns.FromStored("matches /done\\s\\d+/i");
        Assert.NotNull(r);
        Assert.Equal("matches /done\\s\\d+/i", ExpectPatterns.Describe(r));
        Assert.Null(ExpectPatterns.Check(r, "DONE 42"));
        Assert.Equal("Output did not match /done\\s\\d+/i", ExpectPatterns.Check(r, "not yet"));
        // What the engine does not read is kept as stored, passing every output.
        Assert.Null(ExpectPatterns.FromStored("matches /(?<n>a)/"));
        Assert.Null(ExpectPatterns.FromStored("matches /a/y"));
        Assert.Null(ExpectPatterns.FromStored("contains \"a\""));
        // A pattern that runs out of its budget does not match.
        var slow = ExpectPatterns.FromStored("matches /\\n*\\n*\\n*\\n*\\n*x/")!;
        Assert.Equal("Output did not match /\\n*\\n*\\n*\\n*\\n*x/", ExpectPatterns.Check(slow, new string('\n', 32_000)));
        var e = Assert.Throws<ArgumentException>(() => ExpectPatterns.Compile("a+?", ""));
        Assert.StartsWith("expect: /a+?/ is not a pattern CronWatch can read: jsre: lazy quantifiers", e.Message);
    }

    [Fact]
    public void Canonicalize_is_nodes()
    {
        // The table is Node's own toUpperCase; .NET's simple case mapping differs from it.
        char[] canon = JsreCanonical.CanonicalForms();
        Assert.Equal('S', canon['s']);
        Assert.Equal('\u017f', canon['\u017f']);
        Assert.Equal('\u212a', canon['\u212a']);
        Assert.Equal('\u1f80', canon['\u1f80']);
        Assert.Equal('\u00c9', canon['\u00e9']);
        Assert.Equal('\u00df', canon['\u00df']);

        string script = Path.Combine(Fixtures.Repo, "packages", "dotnet", "scripts", "canonical.mjs");
        string? printed = Node.Run(script, "--print");
        if (printed == null)
        {
            Assert.Skip("node is not on the PATH");
        }
        string file = Path.Combine(Fixtures.Repo, "packages", "dotnet", "src", "Cronwatch", "Internal", "Jsre", "JsreCanonicalTable.cs");
        Assert.Equal(File.ReadAllText(file).ReplaceLineEndings("\n"), printed.ReplaceLineEndings("\n"));
    }

    private static string Repeat(string s, int n) => string.Concat(System.Linq.Enumerable.Repeat(s, n));
}

/// <summary>Runs a Node script and reads what it prints, or null when there is no <c>node</c>.</summary>
internal static class Node
{
    public static string? Run(params string[] args)
    {
        var info = new ProcessStartInfo("node")
        {
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            UseShellExecute = false,
        };
        foreach (string a in args)
        {
            info.ArgumentList.Add(a);
        }
        Process? p;
        try
        {
            p = Process.Start(info);
        }
        catch (System.ComponentModel.Win32Exception)
        {
            return null;
        }
        if (p == null)
        {
            return null;
        }
        using (p)
        {
            var stderr = p.StandardError.ReadToEndAsync();
            string output = p.StandardOutput.ReadToEnd();
            p.WaitForExit();
            if (p.ExitCode != 0)
            {
                throw new InvalidOperationException("node " + string.Join(' ', args) + " failed: " + stderr.Result);
            }
            return output;
        }
    }
}
