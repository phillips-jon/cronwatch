using System;
using System.Net;
using System.Net.Http;
using System.Threading;
using System.Threading.Tasks;
using Cronwatch.Alerts;
using Xunit;

namespace Cronwatch.Tests.Posting;

/// <summary>Tests that change what the whole process shares, run alone.</summary>
[CollectionDefinition(nameof(ProcessWide), DisableParallelization = true)]
public sealed class ProcessWide
{
}

/// <summary>No proxy the app did not name ever sees a credential header.</summary>
[Collection(nameof(ProcessWide))]
public class NoProxyTests
{
    [Fact]
    public async Task The_default_transport_uses_no_proxy_even_when_the_process_has_one()
    {
        // HTTPS_PROXY, HTTP_PROXY, and the system's settings reach HttpClient only through
        // HttpClient.DefaultProxy, which is read when a handler that uses a proxy first sends. So
        // setting DefaultProxy stands for setting the variables, without changing the process's
        // environment under tests running at once; this collection runs alone, and it is put back.
        await using var proxy = RawServer.Start(RawServer.Answer(200, "proxied"));
        IWebProxy before = HttpClient.DefaultProxy;
        HttpClient.DefaultProxy = new WebProxy(proxy.Url);
        try
        {
            // The name resolves nowhere, so only a proxy could answer for it.
            const string url = "http://cronwatch-proxy-check.invalid/hook";

            // The control: an ordinary HttpClient goes through the proxy.
            using (var ordinary = new HttpClient())
            {
                using var content = new StringContent("{}");
                using var answer = await ordinary.PostAsync(new Uri(url), content);
                Assert.Equal("proxied", await answer.Content.ReadAsStringAsync());
            }
            Assert.Single(proxy.SeenRequests);
            Assert.Equal("POST " + url + " HTTP/1.1", proxy.SeenRequests[0].RequestLine);

            using var transport = new HttpClientTransport();
            var e = await Assert.ThrowsAsync<CronwatchException>(() => Cronwatch.Internal.Post.FetchAsync(
                transport, TimeSpan.FromSeconds(30), url, [new("authorization", "Bearer not-a-real-token")], "{}", CancellationToken.None));
            Assert.StartsWith("http://cronwatch-proxy-check.invalid: HttpRequestException", e.Message, StringComparison.Ordinal);
            Assert.Single(proxy.SeenRequests);
        }
        finally
        {
            HttpClient.DefaultProxy = before;
        }
    }
}
