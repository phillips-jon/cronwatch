using System.Collections.Generic;
using System.Globalization;
using Cronwatch.Internal;
using Xunit;

namespace Cronwatch.Tests;

/// <summary>
/// <c>conformance/output.json</c>: the output cap, every redaction case, every error message and
/// the recorder's expect text, byte for byte.
/// </summary>
public class OutputConformanceTests
{
    private static readonly JsObject Fixture = Fixtures.Load("output");

    [Fact]
    public void Output_cap()
    {
        Assert.Equal(OutputText.OutputCap, Fixtures.Integer(Fixture, "outputCap"));
    }

    [Fact]
    public void Redact()
    {
        var cases = Fixtures.Objects(Fixture, "redact");
        Assert.Equal(204, cases.Count);
        var failures = new Fixtures.Failures();
        for (int i = 0; i < cases.Count; i++)
        {
            var c = cases[i];
            string input = Fixtures.Expand(c.Get("input"));
            string got = OutputText.RedactSecrets(input);
            failures.Same("redact case " + i + " " + Js.Head(input, 60), Fixtures.Digest(got), c.Get("result"));
        }
        failures.Check("output");
    }

    [Fact]
    public void Error_message()
    {
        var cases = Fixtures.Objects(Fixture, "errorMessage");
        Assert.Equal(16, cases.Count);
        var failures = new Fixtures.Failures();
        for (int i = 0; i < cases.Count; i++)
        {
            var c = cases[i];
            string text;
            if (c.Has("value"))
            {
                object? v = c.Get("value");
                bool recipe = v is JsObject o && o.Has("parts");
                text = OutputText.ErrorMessage(recipe ? Fixtures.Expand(v) : v);
            }
            else
            {
                var frames = new List<string>();
                foreach (var f in Fixtures.List(c, "frames"))
                {
                    frames.Add((string)f!);
                }
                text = OutputText.ErrorMessage(Fixtures.String(c, "name") ?? "null", Fixtures.Expand(c.Get("message")), frames);
            }
            failures.Same("errorMessage case " + i, Fixtures.Digest(text), c.Get("result"));
        }
        failures.Check("output");
    }

    /// <summary>A recorder case's lines: plain strings, recipes, and runs of numbered lines padded to a width.</summary>
    private static List<string> Lines(List<object?> spec)
    {
        var output = new List<string>();
        foreach (var line in spec)
        {
            if (line is JsObject o && o.Has("numbered"))
            {
                string prefix = Fixtures.String(o, "numbered")!;
                long count = Fixtures.Integer(o, "count");
                long width = Fixtures.Integer(o, "width");
                for (long i = 0; i < count; i++)
                {
                    string head = prefix + i.ToString(CultureInfo.InvariantCulture) + " ";
                    output.Add(head + new string('x', (int)System.Math.Max(0, width - head.Length)));
                }
                continue;
            }
            output.Add(Fixtures.Expand(line));
        }
        return output;
    }

    [Fact]
    public void Expect_text()
    {
        var cases = Fixtures.Objects(Fixture, "expectText");
        Assert.Equal(11, cases.Count);
        var failures = new Fixtures.Failures();
        foreach (var c in cases)
        {
            string name = Fixtures.String(c, "name")!;
            var rec = new OutputLines();
            foreach (string line in Lines(Fixtures.List(c, "lines")))
            {
                rec.Log(line);
            }
            string? text = rec.ExpectText();
            failures.Same(name + ": expectText", Fixtures.Digest(text), c.Get("expectText"));
            failures.Same(name + ": output", Fixtures.Digest(rec.Output()), c.Get("output"));
            foreach (var ch in Fixtures.Objects(c, "checks"))
            {
                // The SDK's contains rule: checkExpectation over the expect text.
                string needle = Fixtures.String(ch, "expect")!;
                string? result = (text ?? "").Contains(needle, System.StringComparison.Ordinal)
                    ? null
                    : "Output did not contain " + Json.Quote(needle);
                failures.Same(name + ": expect " + needle, result, ch.Get("result"));
            }
        }
        failures.Check("output");
    }
}
