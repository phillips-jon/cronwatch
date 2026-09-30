using System;
using System.Collections.Concurrent;
using System.Threading;
using System.Threading.Tasks;
using Cronwatch.Alerts;
using Cronwatch.Internal;
using Cronwatch.Tests.Posting;
using Xunit;

namespace Cronwatch.Tests.Alerts;

/// <summary>
/// A redirect is refused by all fifteen channels over the default transport: each request is sent
/// to a real local server (its path and query as the channel wrote them) that answers 307 with a
/// <c>location</c> on another server, and each channel fails without that server ever being asked.
/// </summary>
public class ChannelRedirectTests
{
    private const string Secret = "not-a-real-key";

    /// <summary>Sends every request to <paramref name="local"/>, keeping its path and query, over the default transport.</summary>
    private sealed class Rerouting(string local, HttpClientTransport inner) : ITransport
    {
        public Task<TransportResponse> PostAsync(TransportRequest request, CancellationToken cancellationToken)
        {
            var (_, _, url) = WhatwgUrl.Parse(request.Url);
            return inner.PostAsync(new TransportRequest(local + url!.Target, request.Headers, request.Body.Span), cancellationToken);
        }
    }

    public static TheoryData<string> Names() =>
    [
        "slack", "discord", "webhook", "resend", "postmark", "sendgrid", "mailgun", "ses",
        "twilio", "sentry", "honeybadger", "datadog", "rollbar", "bugsnag", "newrelic",
    ];

    private static IChannel Make(string name, ITransport t) => name switch
    {
        "slack" => new SlackChannel(new SlackOptions { WebhookUrl = "https://hooks.slack.example/T/B/" + Secret, Transport = t }),
        "discord" => new DiscordChannel(new DiscordOptions { WebhookUrl = "https://discord.example/api/webhooks/1/" + Secret, Transport = t }),
        "webhook" => new WebhookChannel(new WebhookOptions { Url = "https://hooks.example/in", Secret = Secret, Transport = t }),
        "resend" => new ResendChannel(new ResendOptions { ApiKey = Secret, From = "a@example.com", To = { "b@example.com" }, Transport = t }),
        "postmark" => new PostmarkChannel(new PostmarkOptions { ServerToken = Secret, From = "a@example.com", To = { "b@example.com" }, Transport = t }),
        "sendgrid" => new SendGridChannel(new SendGridOptions { ApiKey = Secret, From = "a@example.com", To = { "b@example.com" }, Transport = t }),
        "mailgun" => new MailgunChannel(new MailgunOptions { ApiKey = Secret, Domain = "mg.example.com", From = "a@example.com", To = { "b@example.com" }, Transport = t }),
        "ses" => new SesChannel(new SesOptions { Region = "us-east-1", AccessKeyId = Secret, SecretAccessKey = Secret, From = "a@example.com", To = { "b@example.com" }, Transport = t }),
        "twilio" => new TwilioChannel(new TwilioOptions { AccountSid = "AC1", AuthToken = Secret, From = "+15005550006", To = { "+15551110000" }, Transport = t }),
        "sentry" => new SentryChannel(new SentryOptions { Dsn = "https://" + Secret + "@sentry.example.com/1", Transport = t }),
        "honeybadger" => new HoneybadgerChannel(new HoneybadgerOptions { ApiKey = Secret, Transport = t }),
        "datadog" => new DatadogChannel(new DatadogOptions { ApiKey = Secret, Transport = t }),
        "rollbar" => new RollbarChannel(new RollbarOptions { AccessToken = Secret, Transport = t }),
        "bugsnag" => new BugsnagChannel(new BugsnagOptions { ApiKey = Secret, Transport = t }),
        "newrelic" => new NewRelicChannel(new NewRelicOptions { ApiKey = Secret, AccountId = "12345", Transport = t }),
        _ => throw new ArgumentException(name),
    };

    [Theory]
    [MemberData(nameof(Names))]
    public async Task A_redirect_fails_the_channel_and_is_never_followed(string name)
    {
        await using var evil = RawServer.Start(RawServer.Answer(202));
        await using var provider = RawServer.Start(RawServer.Answer(307, "", "location: " + evil.Url + "/steal"));
        using var transport = new HttpClientTransport();
        var reported = new ConcurrentQueue<Exception>();
        IChannel channel = Make(name, new Rerouting(provider.Url, transport));
        var e = await Assert.ThrowsAsync<CronwatchException>(() =>
            channel.SendAsync(ChannelsConformanceTests.Sample(), new ChannelContext(reported.Enqueue, transport), CancellationToken.None));
        Assert.Contains("307", e.Message + string.Concat(reported), StringComparison.Ordinal);
        Assert.DoesNotContain(Secret, e.Message, StringComparison.Ordinal);
        await provider.SettledAsync();
        Assert.NotEmpty(provider.SeenRequests);
        Assert.Empty(evil.SeenRequests);
    }
}
