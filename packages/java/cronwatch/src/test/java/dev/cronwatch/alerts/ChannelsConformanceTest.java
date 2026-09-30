package dev.cronwatch.alerts;

import static org.junit.jupiter.api.Assertions.assertEquals;

import dev.cronwatch.Alert;
import dev.cronwatch.Channel;
import dev.cronwatch.ChannelContext;
import dev.cronwatch.Fixtures;
import dev.cronwatch.alerts.Transport.Request;
import dev.cronwatch.internal.post.Post;
import dev.cronwatch.internal.post.WhatwgUrl;
import dev.cronwatch.json.JsObject;
import dev.cronwatch.json.Json;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.Comparator;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.concurrent.CopyOnWriteArrayList;
import java.util.function.Function;
import org.jspecify.annotations.Nullable;
import org.junit.jupiter.api.Test;

/**
 * Replays {@code conformance/channels.json}, the requests the SDK's channels make ({@code
 * scripts/conformance.mjs} drives them with a stub fetch): every request's URL, headers (name,
 * value and position) and body, byte for byte, for the fixture's sample alerts and each channel's
 * option sets; the error each gives for a refused request; Twilio's partial delivery; and the text
 * cuts.
 */
class ChannelsConformanceTest {
  /** The fixture's first alert, a failure. */
  static Alert sample() {
    JsObject f = Fixtures.load("channels");
    return Alert.fromValue(Fixtures.objects(f, "alerts").get(0).get("alert"));
  }

  private static String s(JsObject o, String key) {
    String v = Fixtures.string(o, key);
    return v == null ? "" : v;
  }

  /** A string or a list of strings. */
  private static List<String> strings(@Nullable Object v) {
    List<String> out = new ArrayList<>();
    if (v instanceof String s) {
      out.add(s);
    } else if (v instanceof List<?> list) {
      for (Object e : list) {
        out.add(e instanceof String s ? s : "");
      }
    }
    return out;
  }

  /**
   * A channel from a fixture's options, as the script's {@code materialize()} makes it: {@code
   * link: true} is the usual link, {@code now} a fixed clock.
   */
  static Channel build(String name, JsObject o, Transport transport) {
    Function<Alert, @Nullable String> link =
        Boolean.TRUE.equals(o.get("link"))
            ? a -> "https://app.example/cronwatch/jobs/" + a.job()
            : null;
    long now = Fixtures.integer(o, "now");
    Object recovered = o.get("recovered");
    Channel made =
        switch (name) {
          case "slack" -> {
            SlackOptions.Builder b = SlackOptions.builder().webhookUrl(s(o, "webhookUrl"));
            yield Slack.channel(common(b, link, transport).build());
          }
          case "discord" -> {
            DiscordOptions.Builder b = DiscordOptions.builder().webhookUrl(s(o, "webhookUrl"));
            yield Discord.channel(common(b, link, transport).build());
          }
          case "webhook" -> {
            WebhookOptions.Builder b = WebhookOptions.builder().url(s(o, "url"));
            for (Map.Entry<String, Object> h : Fixtures.object(o, "headers").entries()) {
              b.header(h.getKey(), String.valueOf(h.getValue()));
            }
            if (o.has("secret")) {
              b.secret(s(o, "secret"));
            }
            yield Webhook.channel(b.transport(transport).build());
          }
          case "resend" ->
              Resend.channel(
                  email(ResendOptions.builder().apiKey(s(o, "apiKey")), o, link, transport)
                      .build());
          case "postmark" -> {
            PostmarkOptions.Builder b = PostmarkOptions.builder().serverToken(s(o, "serverToken"));
            if (o.has("messageStream")) {
              b.messageStream(s(o, "messageStream"));
            }
            yield Postmark.channel(email(b, o, link, transport).build());
          }
          case "sendgrid" -> {
            SendGridOptions.Builder b = SendGridOptions.builder().apiKey(s(o, "apiKey"));
            if (o.has("region")) {
              b.region(s(o, "region"));
            }
            yield SendGrid.channel(email(b, o, link, transport).build());
          }
          case "mailgun" -> {
            MailgunOptions.Builder b =
                MailgunOptions.builder().apiKey(s(o, "apiKey")).domain(s(o, "domain"));
            if (o.has("region")) {
              b.region(s(o, "region"));
            }
            yield Mailgun.channel(email(b, o, link, transport).build());
          }
          case "ses" -> {
            SesOptions.Builder b =
                SesOptions.builder()
                    .region(s(o, "region"))
                    .accessKeyId(s(o, "accessKeyId"))
                    .secretAccessKey(s(o, "secretAccessKey"))
                    .sessionToken(s(o, "sessionToken"))
                    .configurationSetName(s(o, "configurationSetName"))
                    .now(() -> now);
            yield Ses.channel(email(b, o, link, transport).build());
          }
          case "twilio" -> {
            TwilioOptions.Builder b =
                TwilioOptions.builder()
                    .accountSid(s(o, "accountSid"))
                    .authToken(s(o, "authToken"))
                    .apiKeySid(s(o, "apiKeySid"))
                    .apiKeySecret(s(o, "apiKeySecret"))
                    .from(s(o, "from"))
                    .messagingServiceSid(s(o, "messagingServiceSid"))
                    .to(strings(o.get("to")))
                    .recovered(Boolean.TRUE.equals(recovered))
                    .segments(Fixtures.number(o, "segments"));
            yield Twilio.channel(common(b, link, transport).build());
          }
          case "sentry" -> {
            SentryOptions.Builder b = SentryOptions.builder().dsn(s(o, "dsn"));
            if (o.has("environment")) {
              b.environment(s(o, "environment"));
            }
            b.release(s(o, "release")).recovered(!Boolean.FALSE.equals(recovered));
            yield Sentry.channel(common(b, link, transport).build());
          }
          case "honeybadger" -> {
            HoneybadgerOptions.Builder b =
                HoneybadgerOptions.builder()
                    .apiKey(s(o, "apiKey"))
                    .recovered(Boolean.TRUE.equals(recovered));
            if (o.has("environment")) {
              b.environment(s(o, "environment"));
            }
            if (o.has("endpoint")) {
              b.endpoint(s(o, "endpoint"));
            }
            yield Honeybadger.channel(common(b, link, transport).build());
          }
          case "datadog" -> {
            DatadogOptions.Builder b =
                DatadogOptions.builder()
                    .apiKey(s(o, "apiKey"))
                    .tags(strings(o.get("tags")).toArray(String[]::new))
                    .host(s(o, "host"));
            if (o.has("site")) {
              b.site(s(o, "site"));
            }
            yield Datadog.channel(common(b, link, transport).build());
          }
          case "rollbar" -> {
            RollbarOptions.Builder b =
                RollbarOptions.builder()
                    .accessToken(s(o, "accessToken"))
                    .recovered(!Boolean.FALSE.equals(recovered));
            if (o.has("environment")) {
              b.environment(s(o, "environment"));
            }
            yield Rollbar.channel(common(b, link, transport).build());
          }
          case "bugsnag" -> {
            BugsnagOptions.Builder b =
                BugsnagOptions.builder()
                    .apiKey(s(o, "apiKey"))
                    .recovered(Boolean.TRUE.equals(recovered))
                    .now(() -> now);
            if (o.has("releaseStage")) {
              b.releaseStage(s(o, "releaseStage"));
            }
            if (o.has("endpoint")) {
              b.endpoint(s(o, "endpoint"));
            }
            yield Bugsnag.channel(common(b, link, transport).build());
          }
          case "newrelic" -> {
            NewRelicOptions.Builder b = NewRelicOptions.builder().apiKey(s(o, "apiKey"));
            if (o.get("accountId") instanceof Number n) {
              b.accountId(n.longValue());
            } else {
              b.accountId(s(o, "accountId"));
            }
            if (o.has("region")) {
              b.region(s(o, "region"));
            }
            if (o.has("eventType")) {
              b.eventType(s(o, "eventType"));
            }
            yield NewRelic.channel(common(b, link, transport).build());
          }
          default -> throw new IllegalArgumentException("no channel " + name);
        };
    assertEquals(name, made.name());
    return made;
  }

  private static <B extends ChannelBuilder<B>> B common(
      B b, @Nullable Function<Alert, @Nullable String> link, Transport transport) {
    if (link != null) {
      b.link(link);
    }
    return b.transport(transport);
  }

  private static <B extends EmailBuilder<B>> B email(
      B b, JsObject o, @Nullable Function<Alert, @Nullable String> link, Transport transport) {
    b.from(s(o, "from")).to(strings(o.get("to")));
    if (o.has("subjectPrefix")) {
      b.subjectPrefix(s(o, "subjectPrefix"));
    }
    return common(b, link, transport);
  }

  /** A captured request against the fixture's, or why not. */
  private static @Nullable String sameRequest(Request got, JsObject want) {
    if (!got.url().equals(s(want, "url"))) {
      return "url " + got.url() + ", want " + s(want, "url");
    }
    List<Map.Entry<String, String>> headers = new ArrayList<>();
    for (Map.Entry<String, Object> h : Fixtures.object(want, "headers").entries()) {
      headers.add(Map.entry(h.getKey(), String.valueOf(h.getValue())));
    }
    if (!got.headers().equals(headers)) {
      return "headers " + got.headers() + ", want " + headers;
    }
    String body = Recorder.body(got);
    String g = Json.stringify(Fixtures.digest(body));
    String w = Json.stringify(want.get("body"));
    return g.equals(w) ? null : "body " + g + ", want " + w + "\n" + body;
  }

  /** The {@code To} of a form. */
  static String formTo(String body) {
    for (String part : body.split("&", -1)) {
      int eq = part.indexOf('=');
      if (eq > 0 && part.substring(0, eq).equals("To")) {
        return new String(
            WhatwgUrl.percentDecodeBytes(part.substring(eq + 1).replace('+', ' ')),
            StandardCharsets.UTF_8);
      }
    }
    return "";
  }

  /** A Twilio send's requests in the order of its numbers, since they are made at once. */
  private static List<Request> numberOrder(List<Request> requests, List<String> numbers) {
    List<Request> out = new ArrayList<>(requests);
    out.sort(
        Comparator.comparingInt(
            r -> {
              String to = formTo(Recorder.body(r));
              for (int i = 0; i < numbers.size(); i++) {
                if (dev.cronwatch.internal.js.Js.trim(numbers.get(i)).equals(to)) {
                  return i;
                }
              }
              return Integer.MAX_VALUE;
            }));
    return out;
  }

  @Test
  void everyCaseOfChannelsJsonIsTheSdks() throws Exception {
    JsObject f = Fixtures.load("channels");
    Map<String, Alert> alerts = new HashMap<>();
    for (JsObject c : Fixtures.objects(f, "alerts")) {
      alerts.put(s(c, "name"), Alert.fromValue(c.get("alert")));
    }
    Alert first = sample();
    Recorder rec = new Recorder(200, "");
    ChannelContext cx =
        new ChannelContext(
            e -> {
              throw new AssertionError("reported: " + e.getMessage());
            });
    Fixtures.Failures failures = new Fixtures.Failures();
    int count = 0;

    for (String key : List.of("sends", "providerSends")) {
      for (JsObject c : Fixtures.objects(f, key)) {
        JsObject o = Fixtures.object(c, "options");
        Channel ch = build(s(c, "channel"), o, rec);
        rec.answerWith(200, "");
        String what = s(c, "channel") + " " + o.toJson() + " " + s(c, "alert");
        try {
          ch.send(alerts.get(s(c, "alert")), cx);
        } catch (Exception e) {
          failures.fail(what + ": " + e.getMessage());
          continue;
        }
        List<Request> got = numberOrder(rec.taken(), strings(o.get("to")));
        List<JsObject> want = key.equals("sends") ? List.of(c) : Fixtures.objects(c, "requests");
        if (got.size() != want.size()) {
          failures.fail(what + ": " + got.size() + " requests, want " + want.size());
          continue;
        }
        for (int i = 0; i < got.size(); i++) {
          String why = sameRequest(got.get(i), want.get(i));
          if (why != null) {
            failures.fail(what + ": " + why);
          }
        }
        count++;
      }
    }

    for (String key : List.of("failures", "providerFailures")) {
      for (JsObject c : Fixtures.objects(f, key)) {
        JsObject o = Fixtures.object(c, "options");
        Channel ch = build(s(c, "channel"), o, rec);
        int status = (int) Fixtures.integer(c, "status");
        rec.answerWith(status, s(c, "body"));
        String got = null;
        try {
          ch.send(first, cx);
        } catch (Exception e) {
          got = e.getMessage();
        }
        failures.same(
            s(c, "channel") + " " + o.toJson() + " answered " + status, got, c.get("error"));
        count++;
      }
    }

    JsObject partial = Fixtures.object(f, "twilioPartial");
    JsObject po = Fixtures.object(partial, "options");
    List<String> numbers = strings(po.get("to"));
    for (JsObject c : Fixtures.objects(partial, "cases")) {
      List<?> statuses = Fixtures.list(c, "statuses");
      rec.answer(
          body -> {
            String to = formTo(body);
            int i = numbers.indexOf(to);
            if (i < 0) {
              return new Recorder.Reply(500, "");
            }
            int st = ((Number) statuses.get(i)).intValue();
            return st < 400
                ? new Recorder.Reply(st, "{}")
                : new Recorder.Reply(st, "{\"message\":\"refused " + to + " with tw-secret\"}");
          });
      List<Object> reported = new CopyOnWriteArrayList<>();
      Channel ch = build("twilio", po, rec);
      String error = null;
      try {
        ch.send(first, new ChannelContext(e -> reported.add(e.getMessage())));
      } catch (Exception e) {
        error = e.getMessage();
      }
      failures.same("twilio " + statuses + ": error", error, c.get("error"));
      failures.same(
          "twilio " + statuses + ": reported", new ArrayList<>(reported), c.get("reported"));
      List<Request> got = numberOrder(rec.taken(), numbers);
      List<JsObject> want = Fixtures.objects(c, "requests");
      for (int i = 0; i < want.size(); i++) {
        String g = i < got.size() ? got.get(i).url() + " " + formTo(Recorder.body(got.get(i))) : "";
        failures.same(
            "twilio " + statuses + ": request " + i,
            g,
            s(want.get(i), "url") + " " + s(want.get(i), "to"));
      }
      count++;
    }

    JsObject cuts = Fixtures.object(f, "textCuts");
    for (JsObject c : Fixtures.objects(cuts, "errorBodies")) {
      List<@Nullable String> secrets = new ArrayList<>();
      for (Object v : Fixtures.list(c, "secrets")) {
        secrets.add(v instanceof String x ? x : null);
      }
      failures.same("errorBody", Post.errorBody(s(c, "text"), secrets), c.get("body"));
      count++;
    }
    for (JsObject c : Fixtures.objects(cuts, "subjects")) {
      Alert a = withText(first, s(c, "title"), first.message(), first.triage());
      EmailBuilder<ResendOptions.Builder> b =
          ResendOptions.builder().from("a@example.com").to("b@example.com");
      if (c.get("subjectPrefix") instanceof String p) {
        b.subjectPrefix(p);
      }
      Email.Mail mail = Email.compose(a, b.email("Resend"));
      failures.same("subject of " + a.title(), mail.subject(), c.get("subject"));
      count++;
    }
    for (JsObject c : Fixtures.objects(cuts, "smsSegments")) {
      failures.same(
          "smsSegments " + s(c, "text"), Twilio.smsSegments(s(c, "text")), c.get("segments"));
      count++;
    }
    String message = ("a".repeat(152) + "{\n").repeat(12);
    Alert longAlert = withText(first, "nightly failed", message, null);
    for (JsObject c : Fixtures.objects(cuts, "smsBodies")) {
      double segments = Fixtures.number(c, "segments");
      String link =
          "long".equals(c.get("link"))
              ? "https://app.example/" + "p".repeat(2000)
              : "https://app.example/j";
      failures.same(
          "smsBody with " + segments + " segments",
          Fixtures.digest(Twilio.smsBody(longAlert, link, segments)),
          c.get("body"));
      count++;
    }

    failures.check("channels");
    // Every case of the fixture, so a case added there is not skipped here.
    int total = 0;
    for (String key : List.of("sends", "providerSends", "failures", "providerFailures")) {
      total += Fixtures.objects(f, key).size();
    }
    total += Fixtures.objects(partial, "cases").size();
    for (String key : List.of("errorBodies", "subjects", "smsSegments", "smsBodies")) {
      total += Fixtures.objects(cuts, key).size();
    }
    assertEquals(total, count);
    System.out.println("channels.json: " + count + " cases replayed");
  }

  /**
   * The fixture's URLs, each read as Node's {@code new URL} reads it: the href without its user
   * name and password, those as WHATWG encodes them, another scheme, or no URL.
   */
  @Test
  void urlsAreReadAsNodeReadsThem() {
    List<JsObject> cases = Fixtures.objects(Fixtures.load("channels"), "urls");
    List<String> wrong = new ArrayList<>();
    for (JsObject c : cases) {
      String input = s(c, "input");
      String want;
      if (Boolean.TRUE.equals(c.get("invalid"))) {
        want = "invalid";
      } else if (c.get("other") != null) {
        want = "other " + s(c, "other");
      } else {
        want = s(c, "url") + " user " + s(c, "username") + " password " + s(c, "password");
      }
      String got =
          switch (WhatwgUrl.parse(input)) {
            case WhatwgUrl.Special sp ->
                sp.url() + " user " + sp.url().username() + " password " + sp.url().password();
            case WhatwgUrl.Other o -> "other " + o.scheme();
            case WhatwgUrl.Invalid i -> "invalid";
          };
      if (!want.equals(got)) {
        wrong.add(Json.stringify(input) + ": node " + want + ", java " + got);
      }
    }
    assertEquals(List.of(), wrong);
    assertEquals(true, cases.size() > 700);
  }

  /** The alert with another title, message and triage. */
  static Alert withText(Alert a, String title, String message, @Nullable String triage) {
    return new Alert(
        a.type(),
        a.run(),
        a.details(),
        a.job(),
        a.definition(),
        title,
        message,
        triage,
        triage != null || a.triageTried(),
        a.at());
  }
}
