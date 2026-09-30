using System;
using System.Collections.Generic;
using Cronwatch.Internal;
using Xunit;

namespace Cronwatch.Tests;

/// <summary>
/// Replays conformance/duration.json, the cases scripts/conformance.mjs writes by running the SDK,
/// comparing every answer as the JSON the SDK writes, byte for byte.
/// </summary>
public class DurationConformanceTests
{
    /// <summary>A number that may travel as <c>{"special": "NaN"}</c>.</summary>
    internal static double Number(object? v)
    {
        if (v is JsObject o)
        {
            return (o.Get("special") as string) switch
            {
                "NaN" => double.NaN,
                "Infinity" => double.PositiveInfinity,
                "-Infinity" => double.NegativeInfinity,
                _ => throw new ArgumentException("not a number: " + o.ToJson()),
            };
        }
        return (double)v!;
    }

    /// <summary>Fails when the SDK writes a section a replay does not know.</summary>
    internal static void Known(JsObject fixture, params string[] sections)
    {
        var known = new HashSet<string>(sections, StringComparer.Ordinal) { "generatedBy", "sdkVersion" };
        foreach (string key in fixture.Keys)
        {
            Assert.True(known.Contains(key), "the fixture has a section this port does not replay: " + key);
        }
    }

    [Fact]
    public void Every_case_matches_the_sdk()
    {
        JsObject f = Fixtures.Load("duration");
        var failures = new Fixtures.Failures();
        var parse = Fixtures.Objects(f, "parse");
        foreach (JsObject c in parse)
        {
            object? input = c.Get("input");
            string label = c.Has("label") ? Fixtures.String(c, "label")! : "";
            var got = new JsObject().Set("input", input);
            if (c.Has("label"))
            {
                got.Set("label", label);
            }
            try
            {
                double ms = input is string s ? Durations.Parse(s, label) : Durations.Parse(Number(input), label);
                got.Set("ms", ms);
            }
            catch (ArgumentException e)
            {
                got.Set("error", e.Message);
            }
            failures.Same("parse", got, c);
        }
        var format = Fixtures.Objects(f, "format");
        foreach (JsObject c in format)
        {
            var got = new JsObject().Set("ms", c.Get("ms")).Set("text", Durations.Format(Number(c.Get("ms"))));
            failures.Same("format", got, c);
        }
        var relative = Fixtures.Objects(f, "relative");
        foreach (JsObject c in relative)
        {
            var got = new JsObject().Set("at", c.Get("at")).Set("now", c.Get("now"))
                .Set("text", Durations.FormatRelative(Fixtures.Integer(c, "at"), Fixtures.Integer(c, "now")));
            failures.Same("relative", got, c);
        }
        failures.Check("duration");
        Assert.Equal(68, parse.Count);
        Assert.Equal(26, format.Count);
        Assert.Equal(9, relative.Count);
        Known(f, "parse", "format", "relative");
    }
}
