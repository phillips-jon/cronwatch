using System;
using System.Collections.Generic;
using System.Text;
using Cronwatch.Internal;
using Xunit;

namespace Cronwatch.Tests.Web;

/// <summary>The dashboard's origin and request readers, ported from the Java port's WebInternalsTest.</summary>
public class RequestsTests
{
    private static byte[] B(string s) => Encoding.UTF8.GetBytes(s);

    [Theory]
    [InlineData(" HTTPS://App.Example.COM:443/x ", "https://app.example.com")]
    [InlineData("http:\\\\example.com:8080", "http://example.com:8080")]
    [InlineData("http://0x7f.1", "http://127.0.0.1")]
    [InlineData("http://[0:0::1]:80", "http://[::1]")]
    [InlineData("https://bücher.example", "https://xn--bcher-kva.example")]
    [InlineData("http://user:pw@example.com", "http://example.com")]
    [InlineData("http://[::ffff:1.2.3.4]", "http://[::ffff:102:304]")]
    [InlineData("http://1.2.3.4.", "http://1.2.3.4")]
    [InlineData("http://[2001:db8:0:0:1:0:0:1]", "http://[2001:db8::1:0:0:1]")]
    [InlineData("http://%6c%6f%63%61%6c%68%6f%73%74:3000", "http://localhost:3000")]
    [InlineData("http://0177.0.0.1", "http://127.0.0.1")]
    [InlineData("http://2130706433", "http://127.0.0.1")]
    [InlineData("https://app.example.com:0443", "https://app.example.com")]
    public void Origins_are_read_as_url_origin_reads_them(string value, string expected)
    {
        Assert.Equal(expected, Origins.Configured(value));
    }

    [Fact]
    public void The_origin_option_is_refused_with_the_sdks_messages()
    {
        Assert.Equal(
            "routes: origin must be an absolute URL such as \"https://app.example.com\", got \"app.example.com\"",
            Assert.Throws<ArgumentException>(() => Origins.Configured("app.example.com")).Message);
        Assert.Equal(
            "routes: origin must be http or https, got \"ftp://app.example.com\"",
            Assert.Throws<ArgumentException>(() => Origins.Configured("ftp://app.example.com")).Message);
        Assert.Equal(
            "routes: origin must be http or https, got \"javascript:alert(1)\"",
            Assert.Throws<ArgumentException>(() => Origins.Configured("javascript:alert(1)")).Message);
        Assert.Null(Origins.Configured(""));
        Assert.Null(Origins.Configured(null));
        Assert.Throws<ArgumentException>(() => Origins.Configured("http://256.1.1.1.1"));
        Assert.Throws<ArgumentException>(() => Origins.Configured("http://a b"));
        Assert.Throws<ArgumentException>(() => Origins.Configured("http://[::1%25eth0]"));
        Assert.Throws<ArgumentException>(() => Origins.Configured("http://x:65536"));
        Assert.Throws<ArgumentException>(() => Origins.Configured("http://"));
    }

    [Fact]
    public void A_bare_origin_has_nothing_past_its_host()
    {
        Assert.Equal("https://evil.example", Origins.Bare("https://evil.example"));
        Assert.Equal("https://evil.example", Origins.Bare("https://evil.example/"));
        Assert.Null(Origins.Bare("https://evil.example/path"));
        Assert.Null(Origins.Bare("https://user@evil.example"));
        Assert.Null(Origins.Bare("https://evil.example?q"));
        Assert.Null(Origins.Bare("javascript://evil.example"));
    }

    // The Go port's second audit: a Host header outside ASCII is punycoded only up to 1024 bytes;
    // past that it is not read as a URL at all.
    [Fact]
    public void A_long_host_outside_ascii_is_not_read_as_a_url()
    {
        string longHost = new StringBuilder().Insert(0, "é", 600).ToString();
        Assert.Null(Origins.Bare("http://" + longHost));
        // As a server hands the header over: each byte of its UTF-8 one character.
        string sent = Encoding.Latin1.GetString(B(longHost));
        Assert.Equal("http://" + longHost, Origins.OfRequest(false, sent));
        string shortHost = new StringBuilder().Insert(0, "é", 10).ToString();
        Assert.StartsWith("http://xn--", Origins.Bare("http://" + shortHost), StringComparison.Ordinal);
        string wire = Encoding.Latin1.GetString(B("bücher.example"));
        Assert.Equal("http://xn--bcher-kva.example", Origins.OfRequest(false, wire));
        Assert.Equal("https://app.test", Origins.OfRequest(true, "APP.test:443"));
    }

    [Theory]
    [InlineData("http://localhost:3000", true)]
    [InlineData("http://app.localhost", true)]
    [InlineData("http://127.0.0.1", true)]
    [InlineData("http://127.8.9.10", true)]
    [InlineData("http://[::1]:3000", true)]
    [InlineData("http://0x7f.1", true)]
    [InlineData("http://localhost.example", false)]
    [InlineData("http://128.0.0.1", false)]
    [InlineData("http://127.0.0.256", false)]
    [InlineData("http://10.0.0.5:8080", false)]
    [InlineData("http://[::2]", false)]
    // A Host header that is not a host (the Rust audit).
    [InlineData("http://evil.example/.localhost", false)]
    [InlineData("http://localhost:1@evil.example", false)]
    [InlineData("http://evil.example?.localhost", false)]
    [InlineData("http://evil.example#.localhost", false)]
    public void Loopback_hosts(string origin, bool loopback)
    {
        Assert.Equal(loopback, Origins.IsLoopback(origin));
    }

    [Fact]
    public void A_request_origin_from_a_host_that_is_not_a_host_is_not_loopback()
    {
        Assert.False(Origins.IsLoopback(Origins.OfRequest(false, "evil.example/.localhost")));
        Assert.False(Origins.IsLoopback(Origins.OfRequest(false, "localhost:1@evil.example")));
        Assert.True(Origins.IsLoopback(Origins.OfRequest(false, "localhost:5000")));
    }

    [Theory]
    [InlineData("/cronwatch/./jobs/x", "/cronwatch/jobs/x")]
    [InlineData("/cronwatch/nope/../jobs/x", "/cronwatch/jobs/x")]
    [InlineData("/cronwatch\\jobs\\x", "/cronwatch/jobs/x")]
    [InlineData("/cronwatch/%2e/jobs/x", "/cronwatch/jobs/x")]
    [InlineData("/cronwatch/nope/%2E%2e/jobs/x", "/cronwatch/jobs/x")]
    [InlineData("/cronwatch/nope/.%2e/jobs/x", "/cronwatch/jobs/x")]
    [InlineData("/a/..", "/")]
    [InlineData("/a/b/.", "/a/b/")]
    [InlineData("/a b/{c}", "/a%20b/%7Bc%7D")]
    [InlineData("/é", "/%C3%A9")]
    [InlineData("/../..", "/")]
    [InlineData("/cronwatch/jobs/%zz", "/cronwatch/jobs/%zz")]
    public void Paths_are_read_as_the_url_parser_leaves_them(string raw, string expected)
    {
        Assert.Equal(expected, Requests.NormalizePath(raw));
    }

    [Fact]
    public void Targets()
    {
        Assert.Equal(("/a", "b=c"), Requests.Target("/a?b=c#d"));
        Assert.Equal(("/x", "y"), Requests.Target("http://host:1/x?y"));
        Assert.Equal(("/", ""), Requests.Target("http://host"));
        Assert.Equal(("/", ""), Requests.Target("*"));
    }

    [Fact]
    public void The_base_is_stripped_with_a_trailing_slash()
    {
        Assert.Equal("/", Requests.StripBase("/cronwatch", "/cronwatch"));
        Assert.Equal("/", Requests.StripBase("/cronwatch/", "/cronwatch"));
        Assert.Equal("/api/jobs", Requests.StripBase("/cronwatch/api/jobs/", "/cronwatch"));
        Assert.Equal("/api/jobs", Requests.StripBase("/api/jobs", ""));
    }

    [Fact]
    public void Forms_and_queries()
    {
        Assert.Equal(
            [new("a", "b c"), new("d", "%zz"), new("e", "�")],
            Requests.ParseForm(B("a=b+c&&d=%zz&e=%E9")));
        Assert.Equal("b+c%2F%C3%A9", Requests.FormEncode("b c/é"));
        var query = Requests.ParseQuery("token=tok&view=all&token=x");
        Assert.Equal("tok", Requests.Param(query, "token"));
        Assert.Null(Requests.Param(query, "missing"));
    }

    [Fact]
    public void Json_bodies()
    {
        Assert.Equal("7200000", Requests.BodyField("application/json", B("{\"for\":7200000}"), "for"));
        Assert.Equal("true", Requests.BodyField("application/json", B("﻿{\"for\":true}"), "for"));
        Assert.Equal("null", Requests.BodyField("application/json", B("{\"for\":null}"), "for"));
        Assert.Equal("1,,2", Requests.BodyField("application/json", B("{\"for\":[1,null,2]}"), "for"));
        Assert.Equal("[object Object]", Requests.BodyField("application/json", B("{\"for\":{}}"), "for"));
        Assert.Equal("2h", Requests.BodyField("application/json", B("[\"1h\",\"2h\"]"), "1"));
        Assert.Null(Requests.BodyField("application/json", B("[\"1h\",\"2h\"]"), "01"));
        Assert.Null(Requests.BodyField("application/json", B("{"), "for"));
        Assert.Null(Requests.BodyField("application/json", B("{\"other\":1}"), "for"));
    }

    [Fact]
    public void A_json_body_nested_past_256_reads_as_none()
    {
        string deep = new string('[', 5000) + new string(']', 5000);
        Assert.Null(Requests.BodyField("application/json", B(deep), "for"));
        string nested = "{\"for\":\"1h\",\"x\":" + new string('[', 300) + new string(']', 300) + "}";
        Assert.Null(Requests.BodyField("application/json", B(nested), "for"));
        string shallow = "{\"for\":\"1h\",\"x\":" + new string('[', 200) + new string(']', 200) + "}";
        Assert.Equal("1h", Requests.BodyField("application/json", B(shallow), "for"));
    }

    [Fact]
    public void Form_and_multipart_bodies()
    {
        Assert.Equal("2h", Requests.BodyField("application/x-www-form-urlencoded", B("for=1h&for=2h"), "for"));
        Assert.Null(Requests.BodyField("text/plain", B("for=1h"), "for"));
        string multipart = "--b\r\nContent-Disposition: form-data; name=\"for\"\r\n\r\n2h\r\n--b--\r\n";
        Assert.Equal("2h", Requests.BodyField("multipart/form-data; boundary=b", B(multipart), "for"));
        string disposition = "Content-Disposition: form-data; name=\"for\"; filename=\"x.txt\"";
        string file = "--b\r\n" + disposition + "\r\n\r\n2h\r\n--b--\r\n";
        Assert.Equal("[object File]", Requests.BodyField("multipart/form-data; boundary=\"b\"", B(file), "for"));
        Assert.Null(Requests.BodyField(
            "multipart/form-data; boundary=b",
            B("--b\r\nContent-Disposition: form-data; name=\"for\"\r\n\r\n2h"),
            "for"));
        Assert.Null(Requests.BodyField("multipart/form-data", B(multipart), "for"));
        string lf = "preamble\n--b\nContent-Disposition: form-data; name=\"for\"\n\n3h\n--b--\n";
        Assert.Equal("3h", Requests.BodyField("multipart/form-data; BOUNDARY=b", B(lf), "for"));
    }

    [Fact]
    public void Decoding()
    {
        Assert.Equal("a/b", Requests.SafeDecode("a%2Fb"));
        Assert.Equal("é", Requests.SafeDecode("%C3%A9"));
        Assert.Null(Requests.SafeDecode("%zz"));
        Assert.Null(Requests.SafeDecode("%E9"));
        Assert.Null(Requests.SafeDecode("%"));
        Assert.Equal(B("a%zz/"), Requests.PercentDecode(B("a%zz%2f")));
    }

    [Fact]
    public void Headers_join_as_fetch_joins_them()
    {
        var hs = new List<KeyValuePair<string, string>>
        {
            new("cookie", "a=1"),
            new("x-a", "1"),
            new("Cookie", "b=2"),
            new("X-A", "2"),
        };
        Assert.Equal("a=1; b=2", Requests.Header(hs, "Cookie"));
        Assert.Equal("1, 2", Requests.Header(hs, "x-a"));
        Assert.Null(Requests.Header(hs, "x-b"));
    }
}
