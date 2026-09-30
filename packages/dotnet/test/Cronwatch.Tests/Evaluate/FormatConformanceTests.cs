using Cronwatch.Internal;
using Xunit;

namespace Cronwatch.Tests;

/// <summary>
/// <c>conformance/format.json</c>: alert titles and messages, and numbers as
/// <c>toLocaleString</c> writes them. The output cap, stored definitions and expect rules are
/// the client's and the engine's, replayed where those live.
/// </summary>
public class FormatConformanceTests
{
    [Fact]
    public void Alerts_are_the_sdks_text()
    {
        EvaluateTestDeps.Bind();
        var f = Fixtures.Load("format");
        var fails = new Fixtures.Failures();
        var alerts = Fixtures.Objects(f, "alerts");
        Assert.Equal(32, alerts.Count);
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

    [Fact(Skip = "format.json capOutput: needs the output cap (OutputText), replayed once merged")]
    public void Cap_output()
    {
    }

    [Fact(Skip = "format.json toStored: needs the client's JobOptions and Expect, replayed once merged")]
    public void To_stored()
    {
    }

    [Fact(Skip = "format.json checkExpectation: needs Expect and the regex engine, replayed once merged")]
    public void Check_expectation()
    {
    }
}
