using System;
using System.Diagnostics;
using System.Globalization;
using System.Text;
using Cronwatch.Internal;
using Xunit;

namespace Cronwatch.Tests;

/// <summary>
/// A stored expect pattern is a door untrusted input comes through: any process sharing the store
/// writes one, and every other reads it back. Whatever the pattern and the output, compiling
/// refuses with an <see cref="ArgumentException"/> or succeeds, and a test or a replacement within
/// the budget answers or gives up, never throws, and never runs on. Redaction takes any text.
/// </summary>
public class JsreProperties
{
    private static readonly string[] Pieces =
    [
        "a", "b", "x", ".", "\\d", "\\s", "\\w", "\\b", "\\B", "^", "$", "[a-c]", "[^b]", "(",
        ")", "(?:", "(?=", "(?!", "(?<=", "(?<!", "|", "*", "+", "?", "{2}", "{1,3}", "{2,}",
        "\\", "]", "[", "-", "\u00e9", "\ud83d", "\ude00", "\\u0041", "\\x4",
    ];

    /// <summary>How many times longer than their default the properties run: <c>CRONWATCH_TRIES</c>.</summary>
    private static int Scale =>
        int.TryParse(Environment.GetEnvironmentVariable("CRONWATCH_TRIES"), NumberStyles.None, CultureInfo.InvariantCulture, out int n) && n > 0 ? n : 1;

    /// <summary>
    /// Runs <paramref name="property"/> <paramref name="tries"/> times, each on a generator of its
    /// own seed, naming the seed of the first case that fails.
    /// </summary>
    private static void Check(int seed, int tries, Action<JsreGen> property)
    {
        for (int t = 0; t < tries * Scale; t++)
        {
            int caseSeed = HashCode.Combine(seed, t);
            try
            {
                property(new JsreGen(caseSeed));
            }
            catch (Exception e)
            {
                throw new InvalidOperationException("the property failed for seed " + caseSeed.ToString(CultureInfo.InvariantCulture) + ": " + e.Message, e);
            }
        }
    }

    [Fact]
    public void A_stored_pattern_answers_or_gives_up()
    {
        Check(11, 300, g =>
        {
            string source = g.Joined(Pieces, 24);
            string output = g.StringOf("abx\n \u00c9\u00e9\ud83d\ude00-", 400);
            JsRegex re;
            try
            {
                re = JsRegex.Compile(source, g.Bool() ? "gi" : "g");
            }
            catch (ArgumentException)
            {
                return;
            }
            var watch = Stopwatch.StartNew();
            re.TryTest(output);
            re.TryReplace(output, "[$1$&$$]");
            Assert.True(watch.Elapsed < TimeSpan.FromSeconds(30), "within 30 seconds");
        });
    }

    [Fact]
    public void Any_pattern_text_compiles_or_is_refused()
    {
        Check(12, 300, g =>
        {
            try
            {
                var re = JsRegex.Compile(g.AnyString(40), "");
                re.TryTest(g.AnyString(200));
            }
            catch (ArgumentException)
            {
                // Refused, as it should be when it cannot be read.
            }
        });
    }

    [Fact]
    public void Redaction_takes_any_text()
    {
        Check(13, 300, g =>
        {
            string text = g.AnyString(300);
            string output = OutputText.RedactSecrets(text);
            Assert.True(output.Length <= text.Length + 16 * OutputText.Redacted.Length * 64);
        });
    }
}

/// <summary>A small seeded generator of the tests' own.</summary>
internal sealed class JsreGen(int seed)
{
    private readonly Random _random = new(seed);

    public bool Bool() => _random.Next(2) == 0;

    public int Int(int bound) => _random.Next(bound);

    /// <summary>Up to <paramref name="most"/> pieces, joined.</summary>
    public string Joined(string[] pieces, int most)
    {
        var b = new StringBuilder();
        int n = Int(most + 1);
        for (int k = 0; k < n; k++)
        {
            b.Append(pieces[Int(pieces.Length)]);
        }
        return b.ToString();
    }

    /// <summary>Up to <paramref name="most"/> code units drawn from <paramref name="alphabet"/>.</summary>
    public string StringOf(string alphabet, int most)
    {
        var b = new StringBuilder();
        int n = Int(most + 1);
        for (int k = 0; k < n; k++)
        {
            b.Append(alphabet[Int(alphabet.Length)]);
        }
        return b.ToString();
    }

    /// <summary>Up to <paramref name="most"/> code units of any kind, lone surrogates included, ASCII the likeliest.</summary>
    public string AnyString(int most)
    {
        var b = new StringBuilder();
        int n = Int(most + 1);
        for (int k = 0; k < n; k++)
        {
            b.Append(Int(4) switch
            {
                0 => (char)Int(0x10000),
                1 => (char)Int(0x80),
                _ => (char)(0x20 + Int(0x5f)),
            });
        }
        return b.ToString();
    }
}
