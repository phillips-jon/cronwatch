using Cronwatch.Internal;
using Xunit;

namespace Cronwatch.Tests;

/// <summary>
/// <c>conformance/format.json</c>: alert titles and messages, and numbers as
/// <c>toLocaleString</c> writes them. The output cap, stored definitions, and expect rules are
/// the client's and the engine's, replayed where those live.
/// </summary>
public class FormatConformanceTests
{
    [Fact]
    public void Alerts_are_the_sdks_text()
    {
        var f = Fixtures.Load("format");
        var fails = new Fixtures.Failures();
        var alerts = Fixtures.Objects(f, "alerts");
        Assert.Equal(35, alerts.Count);
        int i = 0;
        foreach (var c in alerts)
        {
            var got = AlertFormat.ComposeAlert(EvaluateCases.Draft(c.Get("draft")), EvaluateCases.Definition(c.Get("definition")), Fixtures.Integer(c, "now"));
            fails.Same("alert " + i++, got.ToValue(), c.Get("alert"));
        }
        fails.Check("format");
    }

    [Fact]
    public void Numbers_are_written_as_to_locale_string_writes_them()
    {
        var f = Fixtures.Load("format");
        var fails = new Fixtures.Failures();
        var numbers = Fixtures.Objects(f, "numbers");
        Assert.Equal(38, numbers.Count);
        foreach (var c in numbers)
        {
            double n = Fixtures.Number(c, "n");
            fails.Same("formatNumber(" + Json.Stringify(n) + ")", AlertFormat.FormatNumber(n), c.Get("text"));
        }
        fails.Check("format");
    }

    [Fact]
    public void Cap_output()
    {
        var f = Fixtures.Load("format");
        var fails = new Fixtures.Failures();
        var cases = Fixtures.Objects(f, "capOutput");
        Assert.Equal(14, cases.Count);
        int i = 0;
        foreach (var c in cases)
        {
            var b = new System.Text.StringBuilder(Fixtures.String(c, "prefix"));
            string piece = Fixtures.String(c, "piece")!;
            for (long k = 0; k < Fixtures.Integer(c, "times"); k++)
            {
                b.Append(piece);
            }
            string capped = OutputText.Cap(b.ToString());
            fails.Same(
                "capOutput " + i++,
                new JsObject().Set("length", capped.Length).Set("sha256", Fixtures.Sha256Hex(capped)),
                new JsObject().Set("length", c.Get("length")).Set("sha256", c.Get("sha256")));
        }
        fails.Check("format");
    }

    private static Expect? RuleOf(object? spec)
    {
        switch (spec)
        {
            case null:
                return null;
            case string text:
                return Expect.Contains(text);
            case JsObject o when o.Get("regex") is JsObject re:
                return Expect.Matches(Fixtures.String(re, "source")!, Fixtures.String(re, "flags") ?? "");
            case JsObject o when o.Has("callable"):
                return Expect.That(_ => true);
            default:
                throw new System.ArgumentException("not an expect rule: " + Json.Stringify(spec));
        }
    }

    [Fact]
    public void To_stored()
    {
        var f = Fixtures.Load("format");
        var fails = new Fixtures.Failures();
        var cases = Fixtures.Objects(f, "toStored");
        Assert.Equal(7, cases.Count);
        int i = 0;
        foreach (var c in cases)
        {
            var def = Fixtures.Object(c, "definition");
            var options = new JobOptions { Expect = RuleOf(def.Get("expect")) };
            foreach (var e in def)
            {
                if (e.Key != "expect")
                {
                    options.Field(e.Key, e.Value);
                }
            }
            fails.Same("toStored " + i++, options.Describe(Fixtures.String(def, "name")!).ToObject(), c.Get("stored"));
        }
        fails.Check("format");
    }

    [Fact]
    public void Check_expectation()
    {
        var f = Fixtures.Load("format");
        var fails = new Fixtures.Failures();
        var cases = Fixtures.Objects(f, "checkExpectation");
        Assert.Equal(13, cases.Count);
        int i = 0;
        foreach (var c in cases)
        {
            object? output = c.Get("output");
            string? text = output == null ? null : Fixtures.Expand(output);
            fails.Same("checkExpectation " + i++, Expect.CheckExpectation(RuleOf(c.Get("expect")), text), c.Get("result"));
        }
        fails.Check("format");
    }
}
