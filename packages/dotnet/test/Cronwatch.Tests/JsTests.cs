using System.Collections.Generic;
using Cronwatch.Internal;
using Xunit;

namespace Cronwatch.Tests;

public class JsTests
{
    [Theory]
    [InlineData(2.0, "2")]
    [InlineData(1e-7, "1e-7")]
    [InlineData(1e21, "1e+21")]
    [InlineData(123456789012345680000.0, "123456789012345680000")]
    [InlineData(0.1, "0.1")]
    [InlineData(-1.5, "-1.5")]
    [InlineData(5e-324, "5e-324")]
    [InlineData(1.7976931348623157e308, "1.7976931348623157e+308")]
    [InlineData(0.000001, "0.000001")]
    [InlineData(1e20, "100000000000000000000")]
    [InlineData(-0.0, "0")]
    [InlineData(123.456, "123.456")]
    public void Numbers_are_written_as_javascript_writes_them(double n, string expected)
    {
        Assert.Equal(expected, Js.FormatNumber(n));
    }

    [Fact]
    public void Longs_beyond_two_to_the_53_are_written_as_doubles()
    {
        Assert.Equal("9007199254740991", Js.FormatLong(Js.MaxSafeInteger));
        Assert.Equal("9223372036854776000", Js.FormatLong(long.MaxValue));
    }

    [Fact]
    public void Strings_escape_only_what_javascript_escapes()
    {
        Assert.Equal("\"<a>&'+é\\u0000\\n\\ud83d\"", Json.Quote("<a>&'+é\0\n\ud83d"));
        Assert.Equal("\"\ud83d\ude00\"", Json.Quote("\ud83d\ude00"));
    }

    [Fact]
    public void Keys_keep_javascripts_order()
    {
        var o = Json.ParseObject("{\"b\":1,\"2\":2,\"a\":3,\"1\":4,\"b\":5}");
        Assert.Equal("{\"1\":4,\"2\":2,\"b\":5,\"a\":3}", o.ToJson());
    }

    [Fact]
    public void Nesting_past_the_limit_is_refused()
    {
        string deep = new string('[', 300) + new string(']', 300);
        Assert.Throws<JsonException>(() => Json.Parse(deep));
        Assert.IsType<List<object?>>(Json.Parse(new string('[', 200) + new string(']', 200)));
    }

    [Fact]
    public void Dates_are_written_as_to_iso_string_writes_them()
    {
        Assert.Equal("1970-01-01T00:00:00.000Z", Js.IsoString(0));
        Assert.Equal("0001-01-01T00:00:00.000Z", Js.IsoString(Js.FirstDateMs));
        Assert.Equal("9999-12-31T23:59:59.999Z", Js.IsoString(Js.LastDateMs));
        Assert.Equal("+275760-09-13T00:00:00.000Z", Js.IsoString(8_640_000_000_000_000));
        Assert.Null(Js.IsoTime(long.MinValue));
        Assert.Equal("after 9999-12-31 23:59:59 UTC", Js.IsoOrWords(long.MaxValue));
    }

    [Fact]
    public void Trim_is_javascripts()
    {
        Assert.Equal("\u0085x", Js.Trim("\ufeff\u0085x "));
    }
}
