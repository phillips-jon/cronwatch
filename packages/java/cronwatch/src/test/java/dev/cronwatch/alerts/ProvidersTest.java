package dev.cronwatch.alerts;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;

import dev.cronwatch.Alert;
import dev.cronwatch.AlertType;
import dev.cronwatch.Channel;
import dev.cronwatch.ChannelContext;
import dev.cronwatch.Cronwatch;
import dev.cronwatch.CronwatchException;
import dev.cronwatch.JobOptions;
import dev.cronwatch.alerts.Transport.Request;
import dev.cronwatch.internal.js.Js;
import dev.cronwatch.json.JsObject;
import java.util.ArrayList;
import java.util.List;
import java.util.Map;
import java.util.concurrent.CopyOnWriteArrayList;
import java.util.concurrent.atomic.AtomicLong;
import java.util.function.Supplier;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.function.Executable;

/**
 * What the SDK's channel tests and the other ports' provider tests hold beyond the fixture: the AWS
 * SigV4 test suite, DSNs, Datadog sites and addresses read as the SDK reads them, every option the
 * SDK refuses refused with its message, nothing a channel holds printed by {@code toString},
 * recoveries per channel, the mail's content, Twilio's limits and its partial delivery through a
 * client.
 */
class ProvidersTest {
  static final ChannelContext QUIET = new ChannelContext(e -> {});

  // Cases from the AWS Signature Version 4 test suite (as the SDK's sigv4.test.ts has them):
  // service "service", region us-east-1, the example credentials, 2015-08-30T12:36:00Z.
  private static final String SCOPE =
      "Credential=AKIDEXAMPLE/20150830/us-east-1/service/aws4_request";
  private static final String STS_TOKEN =
      "AQoDYXdzEPT//////////wEXAMPLEtc764bNrC9SAPBSM22wDOk4x4HIZ8j4FZTwdQWLWsKWHGBuFqwAeMicRXmxfpSPfIeoIYRqTflfKD8YUuwthAx7mSEI/qkPpKPi/kMcGdQrmGdeehM4IC1NtBmUpp2wUE8phUZampKsburEDy0KPkyQDYwT7WZ0wq5VSXDvp75YU9HFvlRd8Tx6q6fE8YQcHNVXAkiY9q6d+xo0rKwT38xVqr7ZD0u0iPPkUL64lIZbqBAz+scqKmlzm8FDrypNC9Yjc8fPOLn9FX9KSYvKTr4rvx3iSIlTJabIQwj2ICCR/oLxBA==";

  @Test
  void signaturesMatchTheAwsTestSuite() {
    long now = Js.dateUtc(2015, 7, 30, 12, 36, 0, 0);
    String[][] cases = {
      {
        "GET",
        "https://example.amazonaws.com/",
        "",
        "",
        "SignedHeaders=host;x-amz-date, Signature=5fa00fa31553b73ebf1942676e86291e8372ff2a2260956d9b8aae1d763fbf31"
      },
      {
        "POST",
        "https://example.amazonaws.com/",
        "",
        "",
        "SignedHeaders=host;x-amz-date, Signature=5da7c1a2acd57cee7505fc6676e4e544621c30862966e37dddb68e92efbe5d6b"
      },
      {
        "GET",
        "https://example.amazonaws.com/?Param2=value2&Param1=value1",
        "",
        "",
        "SignedHeaders=host;x-amz-date, Signature=b97d918cfa904a5beff61c982a1b6f458b799221646efd99d3219ec94cdf2500"
      },
      {
        "POST",
        "https://example.amazonaws.com/",
        "My-Header1",
        "",
        "SignedHeaders=host;my-header1;x-amz-date, Signature=cdbc9802e29d2942e5e10b5bccfdd67c5f22c7c4e8ae67b53629efa58b974b7d"
      },
      {
        "POST",
        "https://example.amazonaws.com/",
        "",
        STS_TOKEN,
        "SignedHeaders=host;x-amz-date;x-amz-security-token, Signature=85d96828115b5dc0cfc3bd16ad9e210dd772bbebba041836c64533a82be05ead"
      },
    };
    for (String[] c : cases) {
      List<Map.Entry<String, String>> given =
          c[2].isEmpty() ? List.of() : List.of(Map.entry(c[2], "VALUE1"));
      List<Map.Entry<String, String>> headers =
          SigV4.sign(
              c[0],
              c[1],
              given,
              "",
              "us-east-1",
              "service",
              now,
              "AKIDEXAMPLE",
              "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY",
              c[3].isEmpty() ? null : c[3]);
      Map<String, String> byName = new java.util.HashMap<>();
      for (Map.Entry<String, String> h : headers) {
        byName.put(h.getKey(), h.getValue());
      }
      assertEquals("AWS4-HMAC-SHA256 " + SCOPE + ", " + c[4], byName.get("authorization"), c[1]);
      assertEquals("20150830T123600Z", byName.get("x-amz-date"));
      assertFalse(byName.containsKey("host"), "the transport sets host itself");
      if (!c[3].isEmpty()) {
        assertEquals(c[3], byName.get("x-amz-security-token"));
      }
    }
  }

  @Test
  void dsnsAreReadAsTheSdkReadsThem() {
    String[] a = SentryOptions.parseDsn("https://pubkey@o1.ingest.sentry.io/42");
    assertEquals("https://o1.ingest.sentry.io/api/42/envelope/", a[0]);
    assertEquals("pubkey", a[1]);
    String[] b = SentryOptions.parseDsn("http://k%40y@sentry.example.com:9000/prefix/deep/7");
    assertEquals("http://sentry.example.com:9000/prefix/deep/api/7/envelope/", b[0]);
    assertEquals("k@y", b[1]);
    assertEquals(
        "Sentry needs a dsn like https://<key>@<host>/<project>",
        refusal(() -> SentryOptions.parseDsn("https://o1.ingest.sentry.io/42")));
    assertEquals(
        "Sentry needs a dsn like https://<key>@<host>/<project>",
        refusal(() -> SentryOptions.parseDsn("https://k@o1.ingest.sentry.io/project")));
    assertEquals("Sentry needs a valid dsn", refusal(() -> SentryOptions.parseDsn("not a dsn")));
    assertEquals(
        "Sentry needs a valid dsn", refusal(() -> SentryOptions.parseDsn("https://%zz@h/1")));
  }

  @Test
  void datadogSitesAreReadAsTheSdkReadsThem() {
    assertEquals("datadoghq.eu", DatadogOptions.readSite("https://app.datadoghq.eu/"));
    assertEquals("us5.datadoghq.com", DatadogOptions.readSite("api.us5.datadoghq.com"));
    assertEquals("DDOG-gov.com", DatadogOptions.readSite("DDOG-gov.com"));
    assertEquals(
        "Datadog needs a site like datadoghq.com", refusal(() -> DatadogOptions.readSite("")));
    assertEquals(
        "Datadog needs a site like datadoghq.com",
        refusal(() -> DatadogOptions.readSite("evil.example/path?x")));
  }

  @Test
  void addressesSplitAsTheSdkSplitsThem() {
    String[][] cases = {
      {"ops@example.com", "{\"email\":\"ops@example.com\"}"},
      {" Ops <ops@example.com> ", "{\"email\":\"ops@example.com\",\"name\":\"Ops\"}"},
      {"\"Ops, Team\" <ops@example.com>", "{\"email\":\"ops@example.com\",\"name\":\"Ops, Team\"}"},
      {"<ops@example.com>", "{\"email\":\"ops@example.com\"}"},
      {"a <b> <c@d>", "{\"email\":\"c@d\",\"name\":\"a <b>\"}"},
      {"x\ny <c@d>", "{\"email\":\"x\\ny <c@d>\"}"},
    };
    for (String[] c : cases) {
      assertEquals(c[1], Email.parseAddress(c[0]).toJson(), c[0]);
    }
    assertEquals("a b c", Email.oneLine("a\r\n\nb\rc"));
    assertEquals("HTTPS://x", Email.safeLink("HTTPS://x"));
    assertEquals("", Email.safeLink("javascript:alert(1)"));
  }

  static String refusal(Executable build) {
    CronwatchException e = assertThrows(CronwatchException.class, build);
    assertEquals(CronwatchException.Kind.INVALID, e.kind());
    return e.getMessage();
  }

  @Test
  void everyOptionTheSdkRefusesIsRefusedWithItsMessage() {
    Map<String, Executable> cases = new java.util.LinkedHashMap<>();
    cases.put("Slack needs a webhookUrl", () -> SlackOptions.builder().build());
    cases.put("Discord needs a webhookUrl", () -> DiscordOptions.builder().build());
    cases.put("Webhook needs a url", () -> WebhookOptions.builder().build());
    cases.put(
        "Resend needs an apiKey", () -> ResendOptions.builder().from("a@b.c").to("d@e.f").build());
    cases.put(
        "Resend needs a from address",
        () -> ResendOptions.builder().apiKey("x").to("d@e.f").build());
    cases.put(
        "Postmark needs a serverToken",
        () -> PostmarkOptions.builder().from("a@b.c").to("d@e.f").build());
    cases.put(
        "SendGrid needs at least one to address",
        () -> SendGridOptions.builder().apiKey("x").from("a@b.c").to(" ", "").build());
    cases.put(
        "Mailgun needs a domain",
        () -> MailgunOptions.builder().apiKey("x").from("a@b.c").to("d@e.f").build());
    cases.put("SES needs a region", () -> SesOptions.builder().from("a@b.c").to("d@e.f").build());
    cases.put(
        "SES needs a region like us-east-1",
        () -> SesOptions.builder().region("US East").from("a@b.c").to("d@e.f").build());
    cases.put(
        "SES needs an accessKeyId and secretAccessKey",
        () ->
            SesOptions.builder()
                .region("us-east-1")
                .accessKeyId("x")
                .from("a@b.c")
                .to("d@e.f")
                .build());
    cases.put("Twilio needs an accountSid", () -> TwilioOptions.builder().build());
    cases.put(
        "Twilio needs an authToken, or an apiKeySid and apiKeySecret",
        () -> TwilioOptions.builder().accountSid("AC1").apiKeySid("SK1").authToken("x").build());
    cases.put(
        "Twilio needs a from number or a messagingServiceSid",
        () -> TwilioOptions.builder().accountSid("AC1").authToken("x").build());
    cases.put(
        "Twilio needs at least one to number",
        () -> TwilioOptions.builder().accountSid("AC1").authToken("x").from("+1").build());
    cases.put("Sentry needs a dsn", () -> SentryOptions.builder().dsn(" \n").build());
    cases.put(
        "Sentry needs a dsn like https://<key>@<host>/<project>",
        () -> SentryOptions.builder().dsn("https://o1.ingest.sentry.io/42").build());
    cases.put(
        "New Relic needs a numeric accountId",
        () -> NewRelicOptions.builder().apiKey("x").accountId("12a").build());
    cases.put("New Relic needs an apiKey", () -> NewRelicOptions.builder().accountId(1).build());
    cases.put(
        "Honeybadger needs an apiKey", () -> HoneybadgerOptions.builder().apiKey("\n").build());
    cases.put("Bugsnag needs an apiKey", () -> BugsnagOptions.builder().build());
    cases.put("Rollbar needs an accessToken", () -> RollbarOptions.builder().build());
    cases.put("Datadog needs an apiKey", () -> DatadogOptions.builder().build());
    cases.put(
        "Datadog needs a site like datadoghq.com",
        () -> DatadogOptions.builder().apiKey("x").site("a b").build());
    for (Map.Entry<String, Executable> c : cases.entrySet()) {
      assertEquals(c.getKey(), refusal(c.getValue()));
    }
  }

  @Test
  void nothingAChannelHoldsIsPrintedByToString() throws Exception {
    String secret = "sekret-" + "value-" + "1234";
    List<Object> held = new ArrayList<>();
    held.add(SlackOptions.builder().webhookUrl("https://hooks.slack.example/" + secret).build());
    held.add(DiscordOptions.builder().webhookUrl("https://discord.example/" + secret).build());
    held.add(
        WebhookOptions.builder()
            .url("https://h.example/" + secret)
            .header("authorization", secret)
            .secret(secret)
            .build());
    held.add(ResendOptions.builder().apiKey(secret).from("a@b.c").to("d@e.f").build());
    held.add(PostmarkOptions.builder().serverToken(secret).from("a@b.c").to("d@e.f").build());
    held.add(SendGridOptions.builder().apiKey(secret).from("a@b.c").to("d@e.f").build());
    held.add(
        MailgunOptions.builder()
            .apiKey(secret)
            .domain("mg.example.com")
            .from("a@b.c")
            .to("d@e.f")
            .build());
    held.add(
        SesOptions.builder()
            .region("us-east-1")
            .accessKeyId(secret)
            .secretAccessKey(secret)
            .sessionToken(secret)
            .from("a@b.c")
            .to("d@e.f")
            .build());
    held.add(
        TwilioOptions.builder().accountSid(secret).authToken(secret).from("+1").to(secret).build());
    held.add(SentryOptions.builder().dsn("https://" + secret + "@o1.ingest.sentry.io/42").build());
    held.add(HoneybadgerOptions.builder().apiKey(secret).build());
    held.add(DatadogOptions.builder().apiKey(secret).build());
    held.add(RollbarOptions.builder().accessToken(secret).build());
    held.add(BugsnagOptions.builder().apiKey(secret).build());
    held.add(NewRelicOptions.builder().accountId(1).apiKey(secret).build());
    List<Object> all = new ArrayList<>(held);
    all.add(Slack.channel((SlackOptions) held.get(0)));
    all.add(Webhook.channel((WebhookOptions) held.get(2)));
    all.add(Twilio.channel((TwilioOptions) held.get(8)));
    all.add(Ses.channel((SesOptions) held.get(7)));
    all.add(
        new Request(
            "https://h.example/" + secret + "?k=" + secret,
            List.of(Map.entry("authorization", secret)),
            secret.getBytes(java.nio.charset.StandardCharsets.UTF_8)));
    all.add(SlackOptions.builder().webhookUrl(secret));
    all.add(new JdkTransport());
    for (Object o : all) {
      String text = o.toString();
      assertFalse(text.contains(secret) || text.contains("value-1234"), text);
    }
    ((JdkTransport) all.get(all.size() - 1)).close();
  }

  @Test
  void recoveriesFollowEachChannelsDefaultAndTheRecoveredOption() throws Exception {
    Alert sample = ChannelsConformanceTest.sample();
    Alert recovered =
        new Alert(
            AlertType.RECOVERED,
            sample.run(),
            sample.details(),
            sample.job(),
            sample.definition(),
            "nightly recovered",
            "ok",
            null,
            false,
            sample.at());
    Recorder rec = new Recorder(200, "{}");
    Supplier<List<Channel>> defaults =
        () ->
            List.of(
                Sentry.channel(
                    SentryOptions.builder()
                        .dsn("https://k@o1.ingest.sentry.io/1")
                        .transport(rec)
                        .build()),
                Rollbar.channel(RollbarOptions.builder().accessToken("t").transport(rec).build()),
                Honeybadger.channel(
                    HoneybadgerOptions.builder().apiKey("k").transport(rec).build()),
                Bugsnag.channel(BugsnagOptions.builder().apiKey("k").transport(rec).build()),
                Twilio.channel(
                    TwilioOptions.builder()
                        .accountSid("AC1")
                        .authToken("t")
                        .from("+1")
                        .to("+2")
                        .transport(rec)
                        .build()));
    for (Channel ch : defaults.get()) {
      ch.send(recovered, QUIET);
    }
    List<String> sent = new ArrayList<>();
    for (Request r : rec.taken()) {
      sent.add(dev.cronwatch.internal.post.Post.origin(r.url()));
    }
    assertEquals(List.of("https://o1.ingest.sentry.io", "https://api.rollbar.com"), sent);
    rec.answerWith(200, "{}");
    List<Channel> flipped =
        List.of(
            Sentry.channel(
                SentryOptions.builder()
                    .dsn("https://k@o1.ingest.sentry.io/1")
                    .recovered(false)
                    .transport(rec)
                    .build()),
            Rollbar.channel(
                RollbarOptions.builder().accessToken("t").recovered(false).transport(rec).build()),
            Honeybadger.channel(
                HoneybadgerOptions.builder().apiKey("k").recovered(true).transport(rec).build()),
            Bugsnag.channel(
                BugsnagOptions.builder().apiKey("k").recovered(true).transport(rec).build()),
            Twilio.channel(
                TwilioOptions.builder()
                    .accountSid("AC1")
                    .authToken("t")
                    .from("+1")
                    .to("+2")
                    .recovered(true)
                    .transport(rec)
                    .build()));
    for (Channel ch : flipped) {
      ch.send(recovered, QUIET);
    }
    assertEquals(3, rec.taken().size());
  }

  @Test
  void theMailIsOneLineOfSubjectAndLeavesOutALinkThatIsNotHttp() {
    Alert sample = ChannelsConformanceTest.sample();
    Alert a =
        ChannelsConformanceTest.withText(
            sample, "line one\r\nline two <b>", sample.message(), "check the \"db\"");
    Email.Settings s =
        ResendOptions.builder()
            .from("a@b.c")
            .to("d@e.f")
            .subjectPrefix("[prod]")
            .link(x -> "javascript:alert(1)")
            .email("Resend");
    Email.Mail m = Email.compose(a, s);
    assertEquals("[prod] line one line two <b>", m.subject());
    assertFalse(m.html().contains("javascript:") || m.text().contains("javascript:"));
    assertTrue(
        m.html().contains("line two &lt;b&gt;") && m.html().contains("check the &quot;db&quot;"));
  }

  @Test
  void theWebhookSignatureIsHmacSha256() {
    // RFC 4231's second case.
    assertEquals(
        "5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843",
        Webhook.signature("Jefe", "what do ya want for nothing?"));
    // An empty secret signs as HMAC does with an empty key.
    assertEquals(
        "b613679a0814d9ec772f95d778c35fc5ff1697c493715653c6c712144292c5ad",
        Webhook.signature("", ""));
  }

  @Test
  void encodingsAreTheSdks() {
    assertEquals("a%20b%2Fc%3Fd%3D%C3%A9!'()*~", Shared.encodeUriComponent("a b/c?d=é!'()*~"));
    assertEquals(
        "To=%2B1+555&Body=a%26b%3Dc*%7E",
        Shared.form(List.of(Map.entry("To", "+1 555"), Map.entry("Body", "a&b=c*~"))));
    assertEquals(
        "01234567-89ab-cdef-0123-456789abcdef", Shared.asUuid("0123456789abcdef0123456789abcdef"));
    assertEquals("Basic YXBpOsOp", Shared.basicAuth("api", "é"));
    assertEquals("********0000", Twilio.maskNumber("+15550000000"));
    assertEquals("1234", Twilio.maskNumber("1234"));
  }

  @Test
  void smsBodiesStayInsideTwiliosLimits() {
    Alert sample = ChannelsConformanceTest.sample();
    Alert big = ChannelsConformanceTest.withText(sample, "j failed", "x".repeat(3000), null);
    assertTrue(Twilio.smsBody(big, "", 12).length() <= 1530, "segments held to 10");
    assertTrue(
        Twilio.smsBody(big, "", Double.NaN).length() <= 459, "not a number is the default 3");
    Object[][] segments = {
      {"a".repeat(160), 1},
      {"a".repeat(161), 2},
      {"a".repeat(152) + "{" + "a".repeat(152), 3},
      {"😀".repeat(35), 1},
      {"a".repeat(66) + "😀" + "a".repeat(66), 3},
    };
    for (Object[] c : segments) {
      assertEquals(c[1], Twilio.smsSegments((String) c[0]), ((String) c[0]).length() + " units");
    }
    Alert packed =
        ChannelsConformanceTest.withText(sample, "t", ("a".repeat(152) + "{").repeat(3), null);
    assertTrue(Twilio.smsSegments(Twilio.smsBody(packed, "", 3)) <= 3);
    Alert shortAlert = ChannelsConformanceTest.withText(sample, sample.title(), "m", null);
    assertTrue(
        Twilio.smsBody(shortAlert, "https://example.com/" + "p".repeat(2000), 10).length() <= 1600);
  }

  @Test
  void twilioTextsEveryNumberOnceAndReportsTheRefusalOnceThroughAClient() throws Exception {
    List<String> sent = new CopyOnWriteArrayList<>();
    Recorder rec = new Recorder(201, "{}");
    rec.answer(
        body -> {
          String to = ChannelsConformanceTest.formTo(body);
          if (to.equals("+15550000000")) {
            return new Recorder.Reply(400, "{\"code\":21211,\"message\":\"Invalid To\"}");
          }
          sent.add(to);
          return new Recorder.Reply(201, "{}");
        });
    Channel sms =
        Twilio.channel(
            TwilioOptions.builder()
                .accountSid("AC1")
                .authToken("tok")
                .from("+15551112222")
                .to("+15553334444", "+15550000000")
                .transport(rec)
                .build());
    AtomicLong clock = new AtomicLong(1767225600000L);
    List<String> errors = new CopyOnWriteArrayList<>();
    try (Cronwatch cw =
        Cronwatch.builder()
            .clock(clock::get)
            .noCronSecret()
            .noShutdownHook()
            .onError((where, e) -> errors.add(where + ": " + e.getMessage()))
            .alert(sms)
            .build()) {
      cw.job("nightly", JobOptions.builder().schedule("0 * * * *"));
      cw.check();
      for (int i = 0; i < 6; i++) {
        clock.addAndGet(70 * 60_000L);
        cw.check();
      }
    }
    assertEquals(
        List.of("+15553334444"), sent, "one text for one open missed condition, never resent");
    assertEquals(1, errors.size(), errors.toString());
    String e = errors.get(0);
    assertTrue(
        e.startsWith("alert channel twilio: Twilio https://api.twilio.com answered 400: ")
            && e.contains("Invalid To")
            && e.endsWith(" (to ********0000; 1 of 2 numbers took the alert)"),
        e);

    // Every number refusing it is a failure, retried at the next check.
    Recorder refusing = new Recorder(500, "no");
    Channel all =
        Twilio.channel(
            TwilioOptions.builder()
                .accountSid("AC1")
                .authToken("tok")
                .from("+1")
                .to("+2", "+3")
                .transport(refusing)
                .build());
    String err = ChannelHardeningTest.error(all, ChannelsConformanceTest.sample());
    assertTrue(err.endsWith("(2 of 2 numbers failed)"), err);
  }

  @Test
  void aClientsTransportIsTheOneItsChannelsSendThrough() throws Exception {
    Recorder rec = new Recorder(200, "");
    AtomicLong clock = new AtomicLong(1767225600000L);
    try (Cronwatch cw =
        Cronwatch.builder()
            .clock(clock::get)
            .noShutdownHook()
            .onError((where, e) -> {})
            .transport(rec)
            .alert(Slack.webhook("https://hooks.slack.example/T/B/secret"))
            .build()) {
      cw.job("nightly", JobOptions.builder().schedule("0 * * * *"));
      cw.check();
      clock.addAndGet(70 * 60_000L);
      cw.check();
    }
    assertEquals(1, rec.taken().size());
    assertTrue(Recorder.body(rec.taken().get(0)).contains("nightly"));
    JsObject parsed = (JsObject) dev.cronwatch.json.Json.parse(Recorder.body(rec.taken().get(0)));
    assertTrue(parsed.has("blocks"));
  }
}
