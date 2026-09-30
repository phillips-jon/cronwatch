using System;
using System.Collections.Generic;
using System.Linq;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using Cronwatch.Alerts;
using Cronwatch.Internal;
using Microsoft.Extensions.Time.Testing;
using Xunit;

namespace Cronwatch.Tests.Alerts;

/// <summary>
/// Replays <c>conformance/channels.json</c>, the requests the SDK's channels make
/// (<c>scripts/conformance.mjs</c> drives them with a stub fetch): every request's URL, headers
/// (name, value and position) and body, byte for byte, for the fixture's sample alerts and each
/// channel's option sets; the error each gives for a refused request; Twilio's partial delivery;
/// and the text cuts.
/// </summary>
public class ChannelsConformanceTests
{
    /// <summary>The fixture's first alert, a failure.</summary>
    internal static Alert Sample() =>
        Alert.FromValue(Fixtures.Objects(Fixtures.Load("channels"), "alerts")[0].Get("alert"));

    private static string S(JsObject o, string key) => Fixtures.String(o, key) ?? "";

    private static string? Opt(JsObject o, string key) => o.Has(key) ? S(o, key) : null;

    /// <summary>A string or a list of strings.</summary>
    private static List<string> Strings(object? v) => v switch
    {
        string s => [s],
        List<object?> list => list.Select(e => e as string ?? "").ToList(),
        _ => [],
    };

    /// <summary>
    /// A channel from a fixture's options, as the script's <c>materialize()</c> makes it:
    /// <c>link: true</c> is the usual link, <c>now</c> a fixed clock.
    /// </summary>
    internal static IChannel Build(string name, JsObject o, ITransport transport)
    {
        Func<Alert, string?>? link = o.Get("link") is true ? a => "https://app.example/cronwatch/jobs/" + a.Job : null;
        TimeProvider clock = new FakeTimeProvider(DateTimeOffset.FromUnixTimeMilliseconds(Fixtures.Integer(o, "now")));
        object? recovered = o.Get("recovered");
        IChannel made = name switch
        {
            "slack" => new SlackChannel(new SlackOptions { WebhookUrl = S(o, "webhookUrl"), Link = link, Transport = transport }),
            "discord" => new DiscordChannel(new DiscordOptions { WebhookUrl = S(o, "webhookUrl"), Link = link, Transport = transport }),
            "webhook" => new WebhookChannel(new WebhookOptions
            {
                Url = S(o, "url"),
                Headers = Fixtures.Object(o, "headers").Select(h => new KeyValuePair<string, string>(h.Key, (string)h.Value!)).ToList(),
                Secret = Opt(o, "secret"),
                Transport = transport,
            }),
            "resend" => new ResendChannel(new ResendOptions
            {
                ApiKey = S(o, "apiKey"),
                From = S(o, "from"),
                To = Strings(o.Get("to")),
                SubjectPrefix = Opt(o, "subjectPrefix"),
                Link = link,
                Transport = transport,
            }),
            "postmark" => new PostmarkChannel(new PostmarkOptions
            {
                ServerToken = S(o, "serverToken"),
                MessageStream = Opt(o, "messageStream") ?? "outbound",
                From = S(o, "from"),
                To = Strings(o.Get("to")),
                SubjectPrefix = Opt(o, "subjectPrefix"),
                Link = link,
                Transport = transport,
            }),
            "sendgrid" => new SendGridChannel(new SendGridOptions
            {
                ApiKey = S(o, "apiKey"),
                Region = Opt(o, "region") ?? "us",
                From = S(o, "from"),
                To = Strings(o.Get("to")),
                SubjectPrefix = Opt(o, "subjectPrefix"),
                Link = link,
                Transport = transport,
            }),
            "mailgun" => new MailgunChannel(new MailgunOptions
            {
                ApiKey = S(o, "apiKey"),
                Domain = S(o, "domain"),
                Region = Opt(o, "region") ?? "us",
                From = S(o, "from"),
                To = Strings(o.Get("to")),
                SubjectPrefix = Opt(o, "subjectPrefix"),
                Link = link,
                Transport = transport,
            }),
            "ses" => new SesChannel(new SesOptions
            {
                Region = S(o, "region"),
                AccessKeyId = S(o, "accessKeyId"),
                SecretAccessKey = S(o, "secretAccessKey"),
                SessionToken = S(o, "sessionToken"),
                ConfigurationSetName = S(o, "configurationSetName"),
                Clock = clock,
                From = S(o, "from"),
                To = Strings(o.Get("to")),
                SubjectPrefix = Opt(o, "subjectPrefix"),
                Link = link,
                Transport = transport,
            }),
            "twilio" => new TwilioChannel(new TwilioOptions
            {
                AccountSid = S(o, "accountSid"),
                AuthToken = S(o, "authToken"),
                ApiKeySid = S(o, "apiKeySid"),
                ApiKeySecret = S(o, "apiKeySecret"),
                From = S(o, "from"),
                MessagingServiceSid = S(o, "messagingServiceSid"),
                To = Strings(o.Get("to")),
                Recovered = recovered is true,
                Segments = o.Get("segments") is double d ? d : null,
                Link = link,
                Transport = transport,
            }),
            "sentry" => new SentryChannel(new SentryOptions
            {
                Dsn = S(o, "dsn"),
                Environment = Opt(o, "environment") ?? "production",
                Release = S(o, "release"),
                Recovered = recovered is not false,
                Link = link,
                Transport = transport,
            }),
            "honeybadger" => new HoneybadgerChannel(new HoneybadgerOptions
            {
                ApiKey = S(o, "apiKey"),
                Environment = Opt(o, "environment") ?? "production",
                Endpoint = Opt(o, "endpoint") ?? "https://api.honeybadger.io",
                Recovered = recovered is true,
                Link = link,
                Transport = transport,
            }),
            "datadog" => new DatadogChannel(new DatadogOptions
            {
                ApiKey = S(o, "apiKey"),
                Site = Opt(o, "site") ?? "datadoghq.com",
                Tags = Strings(o.Get("tags")),
                Host = S(o, "host"),
                Link = link,
                Transport = transport,
            }),
            "rollbar" => new RollbarChannel(new RollbarOptions
            {
                AccessToken = S(o, "accessToken"),
                Environment = Opt(o, "environment") ?? "production",
                Recovered = recovered is not false,
                Link = link,
                Transport = transport,
            }),
            "bugsnag" => new BugsnagChannel(new BugsnagOptions
            {
                ApiKey = S(o, "apiKey"),
                ReleaseStage = Opt(o, "releaseStage") ?? "production",
                Endpoint = Opt(o, "endpoint") ?? "https://notify.bugsnag.com/",
                Recovered = recovered is true,
                Clock = clock,
                Link = link,
                Transport = transport,
            }),
            "newrelic" => new NewRelicChannel(new NewRelicOptions
            {
                ApiKey = S(o, "apiKey"),
                AccountId = o.Get("accountId") is double n ? Js.FormatNumber(n) : S(o, "accountId"),
                Region = Opt(o, "region") ?? "us",
                EventType = Opt(o, "eventType") ?? "CronWatchAlert",
                Link = link,
                Transport = transport,
            }),
            _ => throw new ArgumentException("no channel " + name),
        };
        Assert.Equal(name, made.Name);
        return made;
    }

    /// <summary>A captured request against the fixture's, or why not.</summary>
    private static string? SameRequest(TransportRequest got, JsObject want)
    {
        if (got.Url != S(want, "url"))
        {
            return "url " + got.Url + ", want " + S(want, "url");
        }
        var headers = Fixtures.Object(want, "headers").Select(h => h.Key + ": " + h.Value).ToList();
        var gotHeaders = got.Headers.Select(h => h.Key + ": " + h.Value).ToList();
        if (!headers.SequenceEqual(gotHeaders, StringComparer.Ordinal))
        {
            return "headers [" + string.Join(", ", gotHeaders) + "], want [" + string.Join(", ", headers) + "]";
        }
        string body = Recorder.Body(got);
        string g = Json.Stringify(Fixtures.Digest(body));
        string w = Json.Stringify(want.Get("body"));
        return g == w ? null : "body " + g + ", want " + w + "\n" + body;
    }

    /// <summary>The <c>To</c> of a form.</summary>
    internal static string FormTo(string body)
    {
        foreach (string part in body.Split('&'))
        {
            int eq = part.IndexOf('=', StringComparison.Ordinal);
            if (eq > 0 && part[..eq] == "To")
            {
                return Encoding.UTF8.GetString(WhatwgUrl.PercentDecodeBytes(part[(eq + 1)..].Replace('+', ' ')));
            }
        }
        return "";
    }

    /// <summary>A Twilio send's requests in the order of its numbers, since they are made at once.</summary>
    private static List<TransportRequest> NumberOrder(List<TransportRequest> requests, List<string> numbers) =>
        requests.OrderBy(r =>
        {
            string to = FormTo(Recorder.Body(r));
            int i = numbers.FindIndex(n => Js.Trim(n) == to);
            return i < 0 ? int.MaxValue : i;
        }).ToList();

    [Fact]
    public async Task Every_case_of_channels_json_is_the_sdks()
    {
        JsObject f = Fixtures.Load("channels");
        var alerts = new Dictionary<string, Alert>(StringComparer.Ordinal);
        foreach (JsObject c in Fixtures.Objects(f, "alerts"))
        {
            alerts[S(c, "name")] = Alert.FromValue(c.Get("alert"));
        }
        Alert first = Sample();
        var rec = new Recorder();
        var cx = new ChannelContext(e => throw new InvalidOperationException("reported: " + e.Message), rec);
        var failures = new Fixtures.Failures();
        int count = 0;
        var counts = new SortedDictionary<string, int>(StringComparer.Ordinal);

        foreach (string key in new[] { "sends", "providerSends" })
        {
            foreach (JsObject c in Fixtures.Objects(f, key))
            {
                JsObject o = Fixtures.Object(c, "options");
                IChannel ch = Build(S(c, "channel"), o, rec);
                rec.AnswerWith(200, "");
                string what = S(c, "channel") + " " + o.ToJson() + " " + S(c, "alert");
                try
                {
                    await ch.SendAsync(alerts[S(c, "alert")], cx, CancellationToken.None);
                }
                catch (Exception e)
                {
                    failures.Fail(what + ": " + e.Message);
                    continue;
                }
                var got = NumberOrder(rec.Taken(), Strings(o.Get("to")));
                var want = key == "sends" ? new List<JsObject> { c } : Fixtures.Objects(c, "requests");
                if (got.Count != want.Count)
                {
                    failures.Fail(what + ": " + got.Count + " requests, want " + want.Count);
                    continue;
                }
                for (int i = 0; i < got.Count; i++)
                {
                    string? why = SameRequest(got[i], want[i]);
                    if (why != null)
                    {
                        failures.Fail(what + ": " + why);
                    }
                }
                count++;
                counts[key] = counts.GetValueOrDefault(key) + 1;
            }
        }

        foreach (string key in new[] { "failures", "providerFailures" })
        {
            foreach (JsObject c in Fixtures.Objects(f, key))
            {
                JsObject o = Fixtures.Object(c, "options");
                IChannel ch = Build(S(c, "channel"), o, rec);
                int status = (int)Fixtures.Integer(c, "status");
                rec.AnswerWith(status, S(c, "body"));
                string? got = null;
                try
                {
                    await ch.SendAsync(first, cx, CancellationToken.None);
                }
                catch (CronwatchException e)
                {
                    got = e.Message;
                }
                failures.Same(S(c, "channel") + " " + o.ToJson() + " answered " + status, got, c.Get("error"));
                count++;
                counts[key] = counts.GetValueOrDefault(key) + 1;
            }
        }

        JsObject partial = Fixtures.Object(f, "twilioPartial");
        JsObject po = Fixtures.Object(partial, "options");
        List<string> numbers = Strings(po.Get("to"));
        foreach (JsObject c in Fixtures.Objects(partial, "cases"))
        {
            List<object?> statuses = Fixtures.List(c, "statuses");
            rec.Answer(body =>
            {
                string to = FormTo(body);
                int i = numbers.IndexOf(to);
                if (i < 0)
                {
                    return (500, "");
                }
                int st = (int)(double)statuses[i]!;
                return st < 400 ? (st, "{}") : (st, "{\"message\":\"refused " + to + " with tw-secret\"}");
            });
            var reported = new List<object?>();
            var reportedLock = new Lock();
            IChannel ch = Build("twilio", po, rec);
            string? error = null;
            try
            {
                await ch.SendAsync(first, new ChannelContext(e => { lock (reportedLock) { reported.Add(e.Message); } }, rec), CancellationToken.None);
            }
            catch (CronwatchException e)
            {
                error = e.Message;
            }
            string label = "twilio " + Json.Stringify(statuses);
            failures.Same(label + ": error", error, c.Get("error"));
            failures.Same(label + ": reported", reported, c.Get("reported"));
            var got = NumberOrder(rec.Taken(), numbers);
            var want = Fixtures.Objects(c, "requests");
            for (int i = 0; i < want.Count; i++)
            {
                string g = i < got.Count ? got[i].Url + " " + FormTo(Recorder.Body(got[i])) : "";
                failures.Same(label + ": request " + i, g, S(want[i], "url") + " " + S(want[i], "to"));
            }
            count++;
            counts["twilioPartial"] = counts.GetValueOrDefault("twilioPartial") + 1;
        }

        JsObject cuts = Fixtures.Object(f, "textCuts");
        foreach (JsObject c in Fixtures.Objects(cuts, "errorBodies"))
        {
            var secrets = Fixtures.List(c, "secrets").Select(v => v as string).ToList();
            failures.Same("errorBody", Post.ErrorBody(S(c, "text"), secrets), c.Get("body"));
            count++;
        }
        foreach (JsObject c in Fixtures.Objects(cuts, "subjects"))
        {
            Alert a = first with { Title = S(c, "title") };
            var settings = EmailSettings.Of("Resend", "a@example.com", ["b@example.com"], c.Get("subjectPrefix") as string, null);
            failures.Same("subject of " + a.Title, EmailText.Compose(a, settings).Subject, c.Get("subject"));
            count++;
        }
        foreach (JsObject c in Fixtures.Objects(cuts, "smsSegments"))
        {
            failures.Same("smsSegments " + S(c, "text"), TwilioChannel.SmsSegments(S(c, "text")), c.Get("segments"));
            count++;
        }
        string message = string.Concat(Enumerable.Repeat(new string('a', 152) + "{\n", 12));
        Alert longAlert = first with { Title = "nightly failed", Message = message, Triage = null };
        foreach (JsObject c in Fixtures.Objects(cuts, "smsBodies"))
        {
            double segments = Fixtures.Number(c, "segments");
            string link = c.Get("link") as string == "long" ? "https://app.example/" + new string('p', 2000) : "https://app.example/j";
            failures.Same("smsBody with " + segments + " segments", Fixtures.Digest(TwilioChannel.SmsBody(longAlert, link, segments)), c.Get("body"));
            count++;
        }
        counts["textCuts"] = new[] { "errorBodies", "subjects", "smsSegments", "smsBodies" }.Sum(k => Fixtures.Objects(cuts, k).Count);

        failures.Check("channels");
        // Every case of the fixture, so a case added there is not skipped here.
        int total = new[] { "sends", "providerSends", "failures", "providerFailures" }.Sum(k => Fixtures.Objects(f, k).Count)
            + Fixtures.Objects(partial, "cases").Count
            + counts["textCuts"];
        Assert.Equal(total, count);
        TestContext.Current.SendDiagnosticMessage("channels.json: " + string.Join(", ", counts.Select(p => p.Key + " " + p.Value)));
    }
}
