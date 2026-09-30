using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Security.Cryptography;
using System.Text;
using Cronwatch.Internal;
using Xunit;

namespace Cronwatch.Tests;

/// <summary>
/// What the replays of <c>conformance/*.json</c> share: reading a fixture in JavaScript's key
/// order, the recipes for long text, the digests of long results, and a collector that reports
/// every case that differs at once.
/// </summary>
internal static class Fixtures
{
    private static readonly Lazy<string> RepoRoot = new(() =>
    {
        // The repository's root, found by walking up from the test assembly to the directory
        // holding conformance/ and packages/.
        string? dir = AppContext.BaseDirectory;
        while (dir != null)
        {
            if (Directory.Exists(Path.Combine(dir, "conformance")) && Directory.Exists(Path.Combine(dir, "packages")))
            {
                return dir;
            }
            dir = Path.GetDirectoryName(dir);
        }
        throw new InvalidOperationException("the repository's root was not found above " + AppContext.BaseDirectory);
    });

    /// <summary>The repository's root.</summary>
    public static string Repo => RepoRoot.Value;

    /// <summary>The repository's <c>conformance/</c> directory.</summary>
    public static string ConformanceDir => Path.Combine(Repo, "conformance");

    /// <summary><c>conformance/&lt;name&gt;.json</c>, in JavaScript's key order.</summary>
    public static JsObject Load(string name) =>
        Json.ParseObject(File.ReadAllText(Path.Combine(ConformanceDir, name + ".json"), Encoding.UTF8));

    /// <summary><c>o[key]</c> as a list of objects.</summary>
    public static List<JsObject> Objects(JsObject o, string key) =>
        o.Get(key) is List<object?> list ? list.OfType<JsObject>().ToList() : [];

    /// <summary><c>o[key]</c> as a list.</summary>
    public static List<object?> List(JsObject o, string key) => o.Get(key) as List<object?> ?? [];

    /// <summary><c>o[key]</c> as an object, or an empty one.</summary>
    public static JsObject Object(JsObject o, string key) => o.Get(key) as JsObject ?? new JsObject();

    /// <summary><c>o[key]</c> as a string, or null.</summary>
    public static string? String(JsObject o, string key) => o.Get(key) as string;

    /// <summary><c>o[key]</c> as a whole number, truncated as the ports hold times; absent as 0.</summary>
    public static long Integer(JsObject o, string key) => o.Get(key) is double d ? Js.ToLong(d) : 0;

    /// <summary><c>o[key]</c> as a whole number, or null when it is not a number.</summary>
    public static long? OptInteger(JsObject o, string key) => o.Get(key) is double d ? Js.ToLong(d) : null;

    /// <summary><c>o[key]</c> as a double, or NaN.</summary>
    public static double Number(JsObject o, string key) => o.Get(key) is double d ? d : double.NaN;

    /// <summary>
    /// The fixtures' recipe for long text: a string, or <c>{parts: [[piece, times], ...]}</c> joined.
    /// </summary>
    public static string Expand(object? spec)
    {
        if (spec is string s)
        {
            return s;
        }
        if (spec is not JsObject o)
        {
            throw new ArgumentException("not a text recipe: " + Json.Stringify(spec));
        }
        var b = new StringBuilder();
        foreach (var p in List(o, "parts"))
        {
            var pair = (List<object?>)p!;
            string piece = (string)pair[0]!;
            int times = (int)(double)pair[1]!;
            for (int i = 0; i < times; i++)
            {
                b.Append(piece);
            }
        }
        return b.ToString();
    }

    /// <summary>SHA-256 of the text's UTF-8 (a lone surrogate as U+FFFD), as lowercase hex.</summary>
    public static string Sha256Hex(string text) => Sha256Hex(Js.Utf8(text));

    /// <summary>SHA-256 as lowercase hex.</summary>
    public static string Sha256Hex(byte[] data) => Convert.ToHexStringLower(SHA256.HashData(data));

    /// <summary>
    /// The fixtures' form of a long result: <c>{text}</c> up to 400 UTF-16 code units, else
    /// <c>{length, sha256}</c>; null stays null.
    /// </summary>
    public static JsObject? Digest(string? text)
    {
        if (text == null)
        {
            return null;
        }
        if (text.Length <= 400)
        {
            return new JsObject().Set("text", text);
        }
        return new JsObject().Set("length", text.Length).Set("sha256", Sha256Hex(text));
    }

    /// <summary>
    /// Collects every case that is not the SDK's JSON, byte for byte, so a replay reports them all.
    /// </summary>
    public sealed class Failures
    {
        private readonly List<string> _failures = [];

        /// <summary>How many cases were compared.</summary>
        public int Compared { get; private set; }

        /// <summary>Records a difference when the two values' JSON differ.</summary>
        public void Same(string what, object? got, object? want)
        {
            Compared++;
            string g = Json.Stringify(got);
            string w = Json.Stringify(want);
            if (!string.Equals(g, w, StringComparison.Ordinal))
            {
                _failures.Add(what + ":\n  got  " + Clip(g) + "\n  want " + Clip(w));
            }
        }

        /// <summary>Records a failure.</summary>
        public void Fail(string what) => _failures.Add(what);

        /// <summary>Fails the test when any case differed.</summary>
        public void Check(string fixture)
        {
            Assert.True(
                _failures.Count == 0,
                fixture + ".json: " + _failures.Count + " cases differ:\n" + string.Join("\n", _failures.Take(40)));
        }

        private static string Clip(string s) => s.Length > 600 ? s[..600] + "..." : s;
    }
}
