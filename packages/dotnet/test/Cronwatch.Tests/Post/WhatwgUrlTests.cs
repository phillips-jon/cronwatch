using System;
using System.Linq;
using Cronwatch.Internal;
using Xunit;

namespace Cronwatch.Tests.Posting;

/// <summary>The URL read as fetch reads it, the headers checked as fetch checks them, and the cuts (the Java port's <c>PostTest</c>).</summary>
public class WhatwgUrlTests
{
    private static string Written(string raw)
    {
        var (kind, scheme, url) = WhatwgUrl.Parse(raw);
        return kind switch
        {
            UrlKind.Special => url!.ToString(),
            UrlKind.Other => "other " + scheme,
            _ => "invalid",
        };
    }

    /// <summary>What WHATWG writes for each, checked against Node's <c>new URL</c> below.</summary>
    private static readonly string[][] Read =
    [
        ["HTTPS://EXAMPLE.com:443/a/./b/../c?x y#f g", "https://example.com/a/c?x%20y#f%20g"],
        ["https:\\\\h.example\\a\\b", "https://h.example/a/b"],
        ["https:h.example/x", "https://h.example/x"],
        ["http://ex%41mple.com/", "http://example.com/"],
        ["http://h:80/", "http://h/"],
        ["http://h:0080/", "http://h/"],
        ["http://h:/p", "http://h/p"],
        ["http://h:8080", "http://h:8080/"],
        ["http://0x7f.1/", "http://127.0.0.1/"],
        ["http://2130706433/", "http://127.0.0.1/"],
        ["http://0177.0.0.1/", "http://127.0.0.1/"],
        ["http://127.1/", "http://127.0.0.1/"],
        ["http://0x/", "http://0.0.0.0/"],
        ["http://1.2.3.4./", "http://1.2.3.4/"],
        ["http://[0:0:0:0:0:0:0:1]/", "http://[::1]/"],
        ["http://[2001:DB8::1:0:0:1]/", "http://[2001:db8::1:0:0:1]/"],
        ["http://[::ffff:192.168.0.1]/", "http://[::ffff:c0a8:1]/"],
        ["http://[1:0:0:2:0:0:0:3]/", "http://[1:0:0:2::3]/"],
        ["http://[1:0:2:0:3:0:4:0]/", "http://[1:0:2:0:3:0:4:0]/"],
        ["http://h/a/%2e%2E/b/.", "http://h/b/"],
        ["http://h/a/..", "http://h/"],
        ["http:///x", "http://x/"],
        ["http://h/a/b/../../../c", "http://h/c"],
        ["http://h/?q='\"<>", "http://h/?q=%27%22%3C%3E"],
        ["http://h/a|b{c}^`?q={d}|`^#`x", "http://h/a|b%7Bc%7D%5E%60?q={d}|`^#%60x"],
        ["http://h/%zz?%zz", "http://h/%zz?%zz"],
        ["http://h/\u00e9?\u00e9#\u00e9", "http://h/%C3%A9?%C3%A9#%C3%A9"],
        ["http://h/\ud800", "http://h/%EF%BF%BD"],
        ["  http://h/\t\n  ", "http://h/"],
        ["http://h/a\tb\nc", "http://h/abc"],
        ["http://us%65r:p@h/x", "http://h/x"],
        ["http://a@b@h/x", "http://h/x"],
        ["ws://h:80/", "ws://h/"],
    ];

    private static readonly string[] Bad =
    [
        "http://1.2.3.4.5/",
        "http://256.1.1.1/",
        "http://1.2.3.256/",
        "http://0x100000000/",
        "http://example.1/",
        "http://[::1::2]/",
        "http://[1:2:3:4:5:6:7:8:9]/",
        "http://[fe80::1%25eth0]/",
        "http://h:65536/",
        "http://h:8x/",
        "http://a b/",
        "http:///",
        "http://h%00/",
        "1http://h/",
        "no scheme",
    ];

    [Fact]
    public void Urls_are_read_as_fetch_reads_them()
    {
        foreach (var c in Read)
        {
            Assert.True(c[1] == Written(c[0]), c[0] + " read as " + Written(c[0]));
        }
        foreach (string bad in Bad)
        {
            Assert.True(Written(bad) == "invalid", bad + " read as " + Written(bad));
        }
        // A host outside ASCII is refused here, where WHATWG would write its punycode.
        Assert.Equal("invalid", Written("http://b\u00fccher.example/"));
        Assert.Equal("other mailto", Written("mailto:a@b.c"));
        Assert.Equal("other javascript", Written("JavaScript:alert(1)"));
        var (_, _, u) = WhatwgUrl.Parse("https://us%65r:p@h/x");
        Assert.Equal("us%65r", u!.Username);
        Assert.True(u.HasCredentials);
        Assert.Null(WhatwgUrl.Ipv6("1:2:3:4:5:6:7:8:9"));
        Assert.Equal("::", WhatwgUrl.Ipv6Text(new int[8]));
    }

    [Fact]
    public void The_readings_are_nodes()
    {
        // Every URL above that Node reads as WHATWG does (all but the host outside ASCII, which
        // Node converts to punycode and this port refuses) through Node's own new URL.
        var inputs = Read.Select(c => c[0]).Concat(Bad).ToList();
        string script = "const inputs = JSON.parse(process.argv[1]);"
            + "const out = inputs.map(s => { try { const u = new URL(s); return ['http:','https:','ws:','wss:','ftp:'].includes(u.protocol) ? u.protocol.slice(0, -1) + '://' + u.host + u.pathname + u.search + u.hash : 'other ' + u.protocol.slice(0, -1); } catch { return 'invalid'; } });"
            + "process.stdout.write(JSON.stringify(out));";
        string? printed = Node.Run("-e", script, Json.Stringify(inputs));
        if (printed == null)
        {
            Assert.Skip("node is not on the PATH");
        }
        var node = ((System.Collections.IEnumerable)Json.Parse(printed)!).Cast<object?>().Select(o => (string)o!).ToList();
        for (int i = 0; i < inputs.Count; i++)
        {
            string ours = Written(inputs[i]);
            // Node writes the user name back into the URL; the port reads it and posts nothing with one.
            string theirs = node[i];
            Assert.True(theirs == ours, inputs[i] + ": node " + theirs + ", .NET " + ours);
        }
    }

    [Fact]
    public void A_url_is_postable_only_when_the_uri_reads_the_same_host_and_port()
    {
        Assert.Equal("https://h.example/a", Cronwatch.Internal.Post.Postable("https://h.example/a").Url.ToString());
        // Underscores are a host to WHATWG and to Uri alike, so fetch and .NET reach the same place.
        Assert.Equal("a_b.example", Cronwatch.Internal.Post.Postable("https://a_b.example/x").Uri.Host);
        foreach (string raw in new[] { "https://u:p@h.example/x", "https://h.example:99999/", "https://[fe80::1%25eth0]/x", "https://b\u00fccher.example/x", "http:///" })
        {
            var e = Assert.Throws<CronwatchException>(() => Cronwatch.Internal.Post.Postable(raw));
            Assert.Equal("only http and https URLs can be posted to, not this URL", e.Message);
        }
        Assert.Equal("only http and https URLs can be posted to, not ws:", Assert.Throws<CronwatchException>(() => Cronwatch.Internal.Post.Postable("ws://h/")).Message);
        Assert.Equal("only http and https URLs can be posted to, not ftp:", Assert.Throws<CronwatchException>(() => Cronwatch.Internal.Post.Postable("ftp://h/secret-path")).Message);
        Assert.Equal("only http and https URLs can be posted to, not javascript:", Assert.Throws<CronwatchException>(() => Cronwatch.Internal.Post.Postable("javascript:alert(1)")).Message);
        // The path and query go to the transport as WHATWG wrote them, not re-escaped by Uri.
        var (url, uri) = Cronwatch.Internal.Post.Postable("https://hooks.example.com/a|b%2F?c={d}&e=%zz");
        Assert.Equal("/a|b%2F?c={d}&e=%zz", url.Target);
        Assert.Equal("/a|b%2F?c={d}&e=%zz", uri.PathAndQuery);
        Assert.Equal("null", Cronwatch.Internal.Post.Origin("mailto:x"));
        Assert.Equal("(invalid URL)", Cronwatch.Internal.Post.Origin("not a url"));
        Assert.Equal("https://hooks.example.com", Cronwatch.Internal.Post.Origin("HTTPS://Hooks.Example.com:443/x"));
        Assert.Equal("http://hooks.example.com:8080", Cronwatch.Internal.Post.Origin("http://hooks.example.com:8080/x"));
    }

    [Fact]
    public void Headers_are_checked_as_fetch_checks_them_naming_the_header_and_never_its_value()
    {
        Assert.Equal(
            [new("a", "b c"), new("X-Y", "")],
            Cronwatch.Internal.Post.Headers([new("a", " \t b c \r\n"), new("X-Y", "  ")]));
        var e = Assert.Throws<CronwatchException>(() => Cronwatch.Internal.Post.Headers([new("a b", "v")]));
        Assert.Equal("a header name must be a token (letters, digits and !#$%&'*+.^_`|~-)", e.Message);
        foreach (string bad in new[] { "sekret\rX: y", "sekret\nX: y", "sek\0ret" })
        {
            e = Assert.Throws<CronwatchException>(() => Cronwatch.Internal.Post.Headers([new("authorization", bad)]));
            Assert.Equal("the authorization header's value may not contain a line break", e.Message);
        }
        Assert.Throws<CronwatchException>(() => Cronwatch.Internal.Post.Headers([new("", "v")]));
    }

    [Fact]
    public void Cuts_and_bodies_are_the_sdks()
    {
        Assert.Equal("ab", Cronwatch.Internal.Post.Cut("ab\ud83d\ude00", 3));
        Assert.Equal("ab\ud83d\ude00", Cronwatch.Internal.Post.Cut("ab\ud83d\ude00", 4));
        Assert.Equal("", Cronwatch.Internal.Post.Cut("\ud83d\ude00", 1));
        Assert.Equal("[redacted]x", Cronwatch.Internal.Post.ErrorBody("sekretx", ["sekret", "abc", null]));
        Assert.Equal("a\ufffdb", Cronwatch.Internal.Post.Text([(byte)'a', 0xff, (byte)'b']));
        Assert.Equal("x", Cronwatch.Internal.Post.Text([0xef, 0xbb, 0xbf, (byte)'x']));
        // A secret that starts inside the first 200 characters and runs past them is still cut
        // out, whole, before the cut.
        string secret = "not-a-real-token-0123456789";
        string body = new string('a', 190) + secret + "tail";
        string cut = Cronwatch.Internal.Post.ErrorBody(body, [secret]);
        Assert.Equal(new string('a', 190) + "[redacted]", cut);
        Assert.Equal(new string('a', 199), Cronwatch.Internal.Post.ErrorBody(new string('a', 199) + "\ud83d\ude00tail", []));
    }

    [Fact]
    public void A_transports_error_is_written_as_its_name_and_message_with_its_inner_exceptions()
    {
        Assert.Equal(
            "IOException: boom: TimeoutException: refused",
            Cronwatch.Internal.Post.Describe(new AggregateException(new System.IO.IOException("boom", new TimeoutException("refused")))));
        // An inner exception whose text the message already carries adds nothing.
        Assert.Equal(
            "HttpRequestException: Connection refused (h:1)",
            Cronwatch.Internal.Post.Describe(new System.Net.Http.HttpRequestException("Connection refused (h:1)", new System.IO.IOException("Connection refused"))));
        Assert.Equal("Oops", Cronwatch.Internal.Post.Describe(new Oops<int>()));
    }

    private sealed class Oops<T> : Exception
    {
        public Oops()
            : base("")
        {
        }
    }
}
