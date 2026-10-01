using System;
using System.Collections.Concurrent;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;
using Cronwatch.Alerts;
using Cronwatch.Internal;
using Xunit;
using static Cronwatch.Tests.Support;

namespace Cronwatch.Tests.Alerts;

/// <summary>
/// The channels beyond the fixture: their refusals, which never quote a value; their options'
/// <c>ToString</c>, which never shows a secret; the webhook's signature and headers; and Twilio's
/// partial delivery through a client and its transport.
/// </summary>
public class ChannelTests
{
    private const string Secret = "not-a-real-key";

    public static TheoryData<string, string> Refusals() => new()
    {
        { "slack", "Slack needs a WebhookUrl" },
        { "discord", "Discord needs a WebhookUrl" },
        { "webhook", "Webhook needs a Url" },
        { "resend", "Resend needs an ApiKey" },
        { "resend-from", "Resend needs a From address" },
        { "resend-to", "Resend needs at least one To address" },
        { "postmark", "Postmark needs a ServerToken" },
        { "sendgrid", "SendGrid needs an ApiKey" },
        { "mailgun", "Mailgun needs an ApiKey" },
        { "mailgun-domain", "Mailgun needs a Domain" },
        { "ses", "SES needs a Region" },
        { "ses-region", "SES needs a Region like us-east-1" },
        { "ses-keys", "SES needs an AccessKeyId and SecretAccessKey" },
        { "twilio", "Twilio needs an AccountSid" },
        { "twilio-auth", "Twilio needs an AuthToken, or an ApiKeySid and ApiKeySecret" },
        { "twilio-from", "Twilio needs a From number or a MessagingServiceSid" },
        { "twilio-to", "Twilio needs at least one To number" },
        { "sentry", "Sentry needs a Dsn" },
        { "sentry-shape", "Sentry needs a Dsn like https://<key>@<host>/<project>" },
        { "sentry-escape", "Sentry needs a valid Dsn" },
        { "honeybadger", "Honeybadger needs an ApiKey" },
        { "datadog", "Datadog needs an ApiKey" },
        { "datadog-site", "Datadog needs a Site like datadoghq.com" },
        { "rollbar", "Rollbar needs an AccessToken" },
        { "bugsnag", "Bugsnag needs an ApiKey" },
        { "newrelic", "New Relic needs an ApiKey" },
        { "newrelic-account", "New Relic needs a numeric AccountId" },
    };

    private static IChannel Refused(string which) => which switch
    {
        "slack" => new SlackChannel(new SlackOptions()),
        "discord" => DiscordChannel.Webhook(""),
        "webhook" => new WebhookChannel(new WebhookOptions { Secret = Secret }),
        "resend" => new ResendChannel(new ResendOptions { ApiKey = "  \n", From = "a@example.com", To = { "b@example.com" } }),
        "resend-from" => new ResendChannel(new ResendOptions { ApiKey = Secret, To = { "b@example.com" } }),
        "resend-to" => new ResendChannel(new ResendOptions { ApiKey = Secret, From = "a@example.com", To = { " ", "" } }),
        "postmark" => new PostmarkChannel(new PostmarkOptions { From = "a@example.com", To = { "b@example.com" } }),
        "sendgrid" => new SendGridChannel(new SendGridOptions { From = "a@example.com", To = { "b@example.com" } }),
        "mailgun" => new MailgunChannel(new MailgunOptions { Domain = "mg.example.com", From = "a@example.com", To = { "b@example.com" } }),
        "mailgun-domain" => new MailgunChannel(new MailgunOptions { ApiKey = Secret, From = "a@example.com", To = { "b@example.com" } }),
        "ses" => new SesChannel(new SesOptions { AccessKeyId = Secret, SecretAccessKey = Secret, From = "a@example.com", To = { "b@example.com" } }),
        "ses-region" => new SesChannel(new SesOptions { Region = "US East " + Secret, AccessKeyId = Secret, SecretAccessKey = Secret, From = "a@example.com", To = { "b@example.com" } }),
        "ses-keys" => new SesChannel(new SesOptions { Region = "us-east-1", AccessKeyId = Secret, From = "a@example.com", To = { "b@example.com" } }),
        "twilio" => new TwilioChannel(new TwilioOptions { AuthToken = Secret, From = "+15005550006", To = { "+15551110000" } }),
        "twilio-auth" => new TwilioChannel(new TwilioOptions { AccountSid = "AC1", ApiKeySid = "SK1", AuthToken = Secret, From = "+15005550006", To = { "+15551110000" } }),
        "twilio-from" => new TwilioChannel(new TwilioOptions { AccountSid = "AC1", AuthToken = Secret, To = { "+15551110000" } }),
        "twilio-to" => new TwilioChannel(new TwilioOptions { AccountSid = "AC1", AuthToken = Secret, From = "+15005550006" }),
        "sentry" => new SentryChannel(new SentryOptions { Dsn = " " }),
        "sentry-shape" => new SentryChannel(new SentryOptions { Dsn = "https://" + Secret + "@sentry.example.com/project" }),
        "sentry-escape" => new SentryChannel(new SentryOptions { Dsn = "https://%zz" + Secret + "@sentry.example.com/1" }),
        "honeybadger" => new HoneybadgerChannel(new HoneybadgerOptions()),
        "datadog" => new DatadogChannel(new DatadogOptions()),
        "datadog-site" => new DatadogChannel(new DatadogOptions { ApiKey = Secret, Site = "datadog hq/" + Secret }),
        "rollbar" => new RollbarChannel(new RollbarOptions()),
        "bugsnag" => new BugsnagChannel(new BugsnagOptions()),
        "newrelic" => new NewRelicChannel(new NewRelicOptions { AccountId = "12345" }),
        "newrelic-account" => new NewRelicChannel(new NewRelicOptions { ApiKey = Secret, AccountId = "account " + Secret }),
        _ => throw new ArgumentException(which),
    };

    [Theory]
    [MemberData(nameof(Refusals))]
    public void Bad_options_are_refused_in_the_constructor_without_quoting_a_value(string which, string message)
    {
        var e = Assert.Throws<CronwatchException>(() => Refused(which));
        Assert.Equal(CronwatchErrorKind.Invalid, e.Kind);
        Assert.Equal(message, e.Message);
        Assert.DoesNotContain(Secret, e.Message, StringComparison.Ordinal);
    }

    [Fact]
    public void No_options_ToString_shows_a_secret()
    {
        object[] options =
        [
            new SlackOptions { WebhookUrl = "https://hooks.example/" + Secret },
            new DiscordOptions { WebhookUrl = "https://hooks.example/" + Secret },
            new WebhookOptions { Url = "https://hooks.example/" + Secret, Headers = [new("authorization", Secret)], Secret = Secret },
            new ResendOptions { ApiKey = Secret, From = "a@example.com", To = { "b@example.com" } },
            new PostmarkOptions { ServerToken = Secret },
            new SendGridOptions { ApiKey = Secret },
            new MailgunOptions { ApiKey = Secret },
            new SesOptions { AccessKeyId = Secret, SecretAccessKey = Secret, SessionToken = Secret },
            new TwilioOptions { AccountSid = Secret, AuthToken = Secret, To = { "+15551110000" } },
            new TwilioOptions { ApiKeySid = Secret, ApiKeySecret = Secret },
            new SentryOptions { Dsn = "https://" + Secret + "@sentry.example.com/1" },
            new HoneybadgerOptions { ApiKey = Secret },
            new DatadogOptions { ApiKey = Secret },
            new RollbarOptions { AccessToken = Secret },
            new BugsnagOptions { ApiKey = Secret },
            new NewRelicOptions { ApiKey = Secret },
        ];
        foreach (object o in options)
        {
            string text = o.ToString()!;
            Assert.DoesNotContain(Secret, text, StringComparison.Ordinal);
            Assert.DoesNotContain("+15551110000", text, StringComparison.Ordinal);
            Assert.Contains("set", text, StringComparison.Ordinal);
        }
        Assert.Equal("SlackChannel", SlackChannel.Webhook("https://hooks.example/" + Secret).ToString());
        Assert.Equal("DiscordChannel", DiscordChannel.Webhook("https://hooks.example/" + Secret).ToString());
    }

    [Fact]
    public async Task The_webhook_signs_its_body_and_keeps_a_repeated_header_in_its_first_place()
    {
        var rec = new Recorder();
        var channel = new WebhookChannel(new WebhookOptions
        {
            Url = "https://hooks.example.com/in",
            Headers = [new("x-one", " 1\n"), new("content-type", "application/cloudevents+json"), new("x-one", "2")],
            Secret = "s3cret",
            Transport = rec,
        });
        Alert alert = ChannelsConformanceTests.Sample();
        await channel.SendAsync(alert, new ChannelContext(_ => { }), CancellationToken.None);
        TransportRequest sent = Assert.Single(rec.Taken());
        // The payload's version first, then the alert's own fields.
        string body = "{\"schema\":1," + alert.ToJson()[1..];
        Assert.Equal(
            ["content-type: application/cloudevents+json", "user-agent: cronwatch", "x-one: 2", "x-cronwatch-signature: sha256=" + WebhookChannel.Signature("s3cret", body)],
            sent.Headers.Select(h => h.Key + ": " + h.Value).ToList());
        Assert.Equal(body, Recorder.Body(sent));
        // The receiver's check, as the SDK documents it: HMAC-SHA256 of the raw body, hex.
        Assert.Equal(ChannelShared.Hex(System.Security.Cryptography.HMACSHA256.HashData("s3cret"u8, sent.Body.Span)), WebhookChannel.Signature("s3cret", body));
    }

    [Fact]
    public async Task A_channel_without_a_transport_posts_through_the_clients()
    {
        var rec = new Recorder();
        var channel = SlackChannel.Webhook("https://hooks.slack.example/T/B/" + Secret);
        await channel.SendAsync(ChannelsConformanceTests.Sample(), new ChannelContext(_ => { }, rec), CancellationToken.None);
        Assert.Equal("https://hooks.slack.example/T/B/" + Secret, Assert.Single(rec.Taken()).Url);
    }

    [Fact]
    public async Task A_refused_answer_names_the_origin_and_cuts_every_secret_out_of_the_body()
    {
        var rec = new Recorder();
        rec.AnswerWith(401, "bad key " + Secret + " for account");
        var channel = new ResendChannel(new ResendOptions { ApiKey = " " + Secret + "\n", From = "a@example.com", To = { "b@example.com" }, Transport = rec });
        var e = await Assert.ThrowsAsync<CronwatchException>(() => channel.SendAsync(ChannelsConformanceTests.Sample(), new ChannelContext(_ => { }), CancellationToken.None));
        Assert.Equal("Resend https://api.resend.com answered 401: bad key [redacted] for account", e.Message);
        Assert.Equal("Bearer " + Secret, rec.Taken()[0].Header("authorization"));
    }

    [Fact]
    public async Task Twilio_delivers_to_the_numbers_that_took_it_and_reports_the_rest_through_the_client()
    {
        var rec = new Recorder();
        rec.Answer(body => ChannelsConformanceTests.FormTo(body) == "+15552220000" ? (400, "{\"message\":\"refused " + Secret + "\"}") : (201, "{}"));
        var errors = new ConcurrentQueue<(string Where, string Message)>();
        var store = new MemoryStore();
        await using var cw = new CronwatchClient(new CronwatchOptions
        {
            Store = store,
            Clock = Clock(),
            Alerts = { new TwilioChannel(new TwilioOptions { AccountSid = "AC1", AuthToken = Secret, From = "+15005550006", To = { "+15551110000", "+15552220000" } }) },
            Transport = rec,
            CronSecret = CronSecret.None,
            OnError = (e, where) => errors.Enqueue((where, e.Message)),
            OnWarning = _ => { },
            ProcessExitHook = false,
        });
        var job = cw.Job("nightly");
        await Assert.ThrowsAsync<InvalidOperationException>(() => job.RunAsync((j, ct) => throw new InvalidOperationException("boom")));
        Assert.Equal(2, rec.Taken().Count);
        var (where, message) = Assert.Single(errors);
        Assert.Equal("alert channel twilio", where);
        Assert.Equal("Twilio https://api.twilio.com answered 400: {\"message\":\"refused [redacted]\"} (to ********0000; 1 of 2 numbers took the alert)", message);
        // Delivered: nothing is queued for the next check.
        JobState? state = await store.GetStateAsync("nightly");
        Assert.True(state?.Undelivered is null or { Count: 0 });
    }

    [Fact]
    public void Discord_holds_the_whole_description_to_4096_cutting_the_message_and_keeping_the_triage()
    {
        string message = "Error: long\n" + string.Concat(Enumerable.Repeat("```", 1200)) + new string('x', 400) + string.Concat(Enumerable.Repeat("\U0001F600", 200));
        string triage = string.Concat(Enumerable.Repeat("*_`~|[]()<>\\", 100));
        Alert a = ChannelsConformanceTests.Sample() with { Message = message, Triage = triage };
        string description = DiscordChannel.EmbedDescription(a);
        Assert.Equal(4096, description.Length);
        Assert.EndsWith("\n**Triage:** " + DiscordChannel.EscapeMarkdown(triage[..1000]), description, StringComparison.Ordinal);
        Assert.StartsWith("```\nError: long\n", description, StringComparison.Ordinal);
        Assert.Equal(2, description.Split("```").Length - 1);

        // Emoji at the cut: never half a surrogate pair.
        string cut = DiscordChannel.EmbedDescription(a with { Message = string.Concat(Enumerable.Repeat("\U0001F600", 1900)), Triage = new string('t', 1001) });
        Assert.True(cut.Length <= 4096);
        Assert.DoesNotContain(cut.Select((c, i) => (c, i)), p => char.IsHighSurrogate(p.c) && (p.i + 1 == cut.Length || !char.IsLowSurrogate(cut[p.i + 1])));
    }
}
