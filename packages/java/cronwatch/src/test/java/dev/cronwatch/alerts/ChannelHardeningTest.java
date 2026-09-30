package dev.cronwatch.alerts;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertInstanceOf;
import static org.junit.jupiter.api.Assertions.assertNotNull;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;

import dev.cronwatch.Alert;
import dev.cronwatch.Channel;
import dev.cronwatch.ChannelContext;
import dev.cronwatch.CronwatchException;
import dev.cronwatch.internal.post.Post;
import dev.cronwatch.internal.post.WhatwgUrl;
import dev.cronwatch.json.Json;
import java.io.ByteArrayOutputStream;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.List;
import java.util.Map;
import java.util.zip.GZIPOutputStream;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;

/**
 * The channels' hardening, as the SDK's {@code channels-hardening.test.ts} and the other ports'
 * tests have it, against real local servers where it matters: redirects refused, one deadline,
 * bodies capped as they arrive, only the origin in an error, URLs and headers checked, credentials
 * trimmed and cut out of quoted answers, TLS verified, Twilio's partial delivery and lone
 * surrogates. Each confirms one of the design's answers about the JDK's {@code HttpClient}.
 */
class ChannelHardeningTest {
  @TempDir Path dir;

  static final ChannelContext QUIET = new ChannelContext(e -> {});

  /** A transport that sends every request to a local server instead, as the SDK's test does. */
  record Rewrite(TestServer to, Transport inner) implements Transport {
    @Override
    public Response post(Request request) throws Exception {
      WhatwgUrl u = ((WhatwgUrl.Special) WhatwgUrl.parse(request.url())).url();
      return inner.post(new Request(to.url() + u.target(), request.headers(), request.body()));
    }
  }

  /** One of each channel, posting through {@code transport}. */
  static List<Channel> every(Transport t, String webhookUrl) {
    return List.of(
        Datadog.channel(DatadogOptions.builder().apiKey("dd-secret-key-123").transport(t).build()),
        Resend.channel(
            ResendOptions.builder()
                .apiKey("re_secret")
                .from("a@b.c")
                .to("d@e.f")
                .transport(t)
                .build()),
        Postmark.channel(
            PostmarkOptions.builder()
                .serverToken("pm-secret")
                .from("a@b.c")
                .to("d@e.f")
                .transport(t)
                .build()),
        SendGrid.channel(
            SendGridOptions.builder()
                .apiKey("SG.secret")
                .from("a@b.c")
                .to("d@e.f")
                .transport(t)
                .build()),
        Mailgun.channel(
            MailgunOptions.builder()
                .apiKey("key-secret")
                .domain("mg.example.com")
                .from("a@b.c")
                .to("d@e.f")
                .transport(t)
                .build()),
        Ses.channel(
            SesOptions.builder()
                .region("us-east-1")
                .accessKeyId("AKIDEXAMPLE")
                .secretAccessKey("sekret-sekret")
                .from("a@b.c")
                .to("d@e.f")
                .transport(t)
                .build()),
        Twilio.channel(
            TwilioOptions.builder()
                .accountSid("AC1")
                .authToken("tw-secret")
                .from("+1")
                .to("+2")
                .transport(t)
                .build()),
        Sentry.channel(
            SentryOptions.builder()
                .dsn("https://pubkey@o1.ingest.sentry.io/42")
                .transport(t)
                .build()),
        Honeybadger.channel(HoneybadgerOptions.builder().apiKey("hb-secret").transport(t).build()),
        Rollbar.channel(RollbarOptions.builder().accessToken("rb-secret").transport(t).build()),
        Bugsnag.channel(BugsnagOptions.builder().apiKey("bs-secret").transport(t).build()),
        NewRelic.channel(
            NewRelicOptions.builder().accountId("1").apiKey("nr-secret").transport(t).build()),
        Webhook.channel(
            WebhookOptions.builder()
                .url(webhookUrl)
                .header("authorization", "Bearer wh-secret")
                .secret("s")
                .transport(t)
                .build()),
        Slack.channel(SlackOptions.builder().webhookUrl(webhookUrl).transport(t).build()),
        Discord.channel(DiscordOptions.builder().webhookUrl(webhookUrl).transport(t).build()));
  }

  static String error(Channel ch, Alert alert) {
    try {
      ch.send(alert, QUIET);
      return "";
    } catch (Exception e) {
      return String.valueOf(e.getMessage());
    }
  }

  @Test
  void everyChannelRefusesToFollowARedirect() throws Exception {
    try (TestServer evil = TestServer.start(r -> new TestServer.Answer(202));
        JdkTransport jdk = new JdkTransport()) {
      String target = evil.url() + "/steal";
      try (TestServer provider =
          TestServer.start(
              r ->
                  new TestServer.Answer(
                      307, List.of(Map.entry("location", target)), new byte[0]))) {
        List<Channel> channels = every(new Rewrite(provider, jdk), provider.url() + "/in");
        assertEquals(15, channels.size());
        Alert sample = ChannelsConformanceTest.sample();
        for (Channel ch : channels) {
          String err = error(ch, sample);
          assertTrue(err.contains("answered 307"), ch.name() + " followed the redirect: " + err);
        }
        assertTrue(evil.seen().isEmpty(), "the other origin was reached");
        // The credentials went to the provider, and no further.
        assertEquals(15, provider.seen().size());
        assertTrue(
            provider.seen().stream()
                .anyMatch(s -> "Bearer wh-secret".equals(s.header("authorization"))));
      }
    }
  }

  @Test
  void oneDeadlineForTheWholeRequest() throws Exception {
    assertEquals(10_000, Post.TIMEOUT_MS);
    try (TestServer hang = TestServer.start(r -> new TestServer.Hang());
        TestServer drip = TestServer.start(r -> new TestServer.Drip());
        JdkTransport jdk = new JdkTransport()) {
      long started = System.nanoTime();
      CronwatchException e =
          assertThrows(
              CronwatchException.class,
              () -> Post.fetch(jdk, 300, hang.url() + "/T/B/secret", List.of(), "{}"));
      assertEquals(Post.TIMED_OUT, e.getMessage());
      assertTrue((System.nanoTime() - started) / 1_000_000 < 30_000, "the deadline held");

      // An answer whose body is still arriving at the deadline is the answer with no body.
      Post.Answer answer = Post.fetch(jdk, 300, drip.url(), List.of(), "{}");
      assertEquals(500, answer.status());
      assertEquals("", answer.body());
      assertEquals(
          "Rollbar https://api.rollbar.com answered 500",
          Post.refused("Rollbar", "https://api.rollbar.com/api/1/item/", answer, List.of())
              .getMessage());
    }
  }

  @Test
  void aChannelStopsWaitingAtItsDeadline() throws Exception {
    try (TestServer hang = TestServer.start(r -> new TestServer.Hang())) {
      Post.timeoutForTests(500);
      try {
        Channel ch =
            Slack.channel(SlackOptions.builder().webhookUrl(hang.url() + "/T/B/secret").build());
        assertEquals(Post.TIMED_OUT, error(ch, ChannelsConformanceTest.sample()));
      } finally {
        Post.timeoutForTests(Post.TIMEOUT_MS);
      }
    }
  }

  @Test
  void anAnswerIsReadToOneMebibyteAsItArrivesWhateverItsFraming() throws Exception {
    long large = 64L << 20;
    for (String framing : List.of("length", "chunked", "close")) {
      try (TestServer big = TestServer.start(r -> new TestServer.Stream(500, large, framing));
          JdkTransport jdk = new JdkTransport()) {
        Post.Answer answer = Post.fetch(jdk, 30_000, big.url(), List.of(), "{}");
        assertEquals(500, answer.status(), framing);
        assertEquals(Post.MAX_BODY, answer.body().length(), framing);
        // The subscription was cancelled at the cap, which closed the connection: the server
        // could not write the rest.
        assertTrue(
            Await.until(() -> big.stoppedAt.get() >= 0),
            framing + ": the connection stayed open after the cap");
        assertTrue(big.written.get() < large, framing + ": the whole answer was written");
      }
    }
  }

  @Test
  void aGzipAnswerIsNotDecompressed() throws Exception {
    // 64 MiB of zeros, gzipped. The JDK asks for no encoding and decodes none, so what is read is
    // the compressed bytes, never the 64 MiB.
    ByteArrayOutputStream zipped = new ByteArrayOutputStream();
    try (GZIPOutputStream z = new GZIPOutputStream(zipped)) {
      byte[] chunk = new byte[1 << 20];
      for (int i = 0; i < 64; i++) {
        z.write(chunk);
      }
    }
    byte[] bomb = zipped.toByteArray();
    try (TestServer server =
            TestServer.start(
                r ->
                    new TestServer.Answer(
                        500, List.of(Map.entry("content-encoding", "gzip")), bomb));
        JdkTransport jdk = new JdkTransport()) {
      Post.Answer answer = Post.fetch(jdk, 30_000, server.url(), List.of(), "{}");
      assertEquals(500, answer.status());
      assertTrue(answer.body().length() <= bomb.length, "decompressed");
      assertEquals(null, server.seen().get(0).header("accept-encoding"));
      Channel rb =
          Rollbar.channel(
              RollbarOptions.builder()
                  .accessToken("rb-secret")
                  .transport(new Rewrite(server, jdk))
                  .build());
      String err = error(rb, ChannelsConformanceTest.sample());
      assertTrue(
          err.length() <= "Rollbar https://api.rollbar.com answered 500: ".length() + 200, err);
    }
  }

  @Test
  void aUrlThatCannotBePostedToIsRefusedWithoutQuotingIt() throws Exception {
    Recorder rec = new Recorder(200, "");
    String secretPath = String.join("/", "services", "T0", "B0", "not" + "areal" + "secret");
    List<String[]> cases =
        List.of(
            new String[] {"hooks.example.com/" + secretPath, "this URL"},
            new String[] {"ftp://hooks.example.com/" + secretPath, "ftp:"},
            new String[] {"https://user:pw@hooks.example.com/" + secretPath, "this URL"},
            new String[] {"https://hooks.example.com:99999/" + secretPath, "this URL"},
            // An IPv6 host with a zone, which fetch refuses and the JDK would drop.
            new String[] {"https://[fe80::1%25eth0]/" + secretPath, "this URL"},
            // A host outside ASCII: the JDK's IDNA is not WHATWG's.
            new String[] {"https://b\u00fccher.example/" + secretPath, "this URL"},
            // A host java.net.URI reads as a registry name, so it would reach another.
            new String[] {"https://a_b.example.com/" + secretPath, "this URL"},
            // Fetch reads it as a URL with a scheme and refuses the scheme.
            new String[] {"javascript:alert(1)", "javascript:"});
    for (String[] c : cases) {
      List<Channel> channels =
          List.of(
              Slack.channel(SlackOptions.builder().webhookUrl(c[0]).transport(rec).build()),
              Discord.channel(DiscordOptions.builder().webhookUrl(c[0]).transport(rec).build()),
              Webhook.channel(WebhookOptions.builder().url(c[0]).transport(rec).build()));
      for (Channel ch : channels) {
        assertEquals(
            "only http and https URLs can be posted to, not " + c[1],
            error(ch, ChannelsConformanceTest.sample()),
            ch.name() + " " + c[0]);
      }
    }
    assertTrue(rec.taken().isEmpty(), "something was sent");
    // A stray newline or space around a pasted URL, or a tab inside it, is dropped, as fetch
    // drops it; a space inside is encoded, as fetch encodes it.
    String[][] posted = {
      {
        "  https://hooks.exa\tmple.com/" + secretPath + "\n",
        "https://hooks.example.com/" + secretPath
      },
      {
        "https://hooks.example.com/" + secretPath + " x",
        "https://hooks.example.com/" + secretPath + "%20x"
      },
      {"https://hooks.example.com/a|b?c={d}", "https://hooks.example.com/a|b?c={d}"},
    };
    for (String[] p : posted) {
      Channel ch = Slack.channel(SlackOptions.builder().webhookUrl(p[0]).transport(rec).build());
      ch.send(ChannelsConformanceTest.sample(), QUIET);
      List<Request> taken = rec.taken();
      assertEquals(p[1], taken.get(taken.size() - 1).url());
    }
    // What the WHATWG URL keeps and java.net.URI cannot hold goes to the JDK encoded.
    assertEquals(
        "https://hooks.example.com/a%7Cb?c=%7Bd%7D",
        Post.uri(((WhatwgUrl.Special) WhatwgUrl.parse("https://hooks.example.com/a|b?c={d}")).url())
            .toString());
    String[][] origins = {
      {"https://hooks.example.com/" + secretPath + "\n", "https://hooks.example.com"},
      {"HTTPS://Hooks.Example.com:443/x", "https://hooks.example.com"},
      {"http://hooks.example.com:8080/x", "http://hooks.example.com:8080"},
      {"not a url", "(invalid URL)"},
    };
    for (String[] o : origins) {
      assertEquals(o[1], Post.origin(o[0]), o[0]);
    }
  }

  @Test
  void anErrorNamesOnlyTheOrigin() throws Exception {
    String secret = "not" + "areal" + "secret";
    // Nothing listens on port 1: the transport's own error is kept, the URL's path is not.
    Channel ch =
        Webhook.channel(
            WebhookOptions.builder()
                .url("http://127.0.0.1:1/hooks/" + secret + "?token=" + secret)
                .build());
    String err = error(ch, ChannelsConformanceTest.sample());
    assertFalse(err.contains(secret), err);
    assertTrue(err.startsWith("http://127.0.0.1:1: ConnectException"), err);
    try (TestServer refuse = TestServer.start(r -> new TestServer.Answer(403))) {
      ch =
          Webhook.channel(
              WebhookOptions.builder()
                  .url(refuse.url() + "/services/" + secret + "?key=" + secret)
                  .build());
      assertEquals(
          "Webhook " + refuse.url() + " answered 403", error(ch, ChannelsConformanceTest.sample()));
    }
  }

  @Test
  void anErrorNamesOnlyTheOriginWhateverTheTransportQuotes() {
    String secret = "not" + "areal" + "secret";
    // An app's transport that fails the way a wrapper around a client of its own does: with its
    // own text quoting the URL, whole or decoded.
    Transport quoting =
        request -> {
          WhatwgUrl u = ((WhatwgUrl.Special) WhatwgUrl.parse(request.url())).url();
          String decoded = Post.text(WhatwgUrl.percentDecodeBytes(u.path()));
          throw new IllegalStateException(
              "giving up on " + request.url() + " (" + decoded + ") after 3 tries");
        };
    Channel ch =
        Webhook.channel(
            WebhookOptions.builder()
                .url("https://hooks.example.com/services/" + secret + "%20x?token=" + secret)
                .transport(quoting)
                .build());
    String err = error(ch, ChannelsConformanceTest.sample());
    assertFalse(err.contains(secret) || err.contains("/services"), err);
    assertTrue(err.startsWith("https://hooks.example.com: IllegalStateException: "), err);
  }

  @Test
  void aThrowWhileTextingIsThatNumbersFailure() {
    Channel sms =
        Twilio.channel(
            TwilioOptions.builder()
                .accountSid("AC1")
                .authToken("tok")
                .from("+15551112222")
                .to("+15553334444", "+15553335555")
                .transport(
                    r -> {
                      throw new IllegalStateException("transport broke");
                    })
                .build());
    assertEquals(
        "https://api.twilio.com: IllegalStateException: transport broke (2 of 2 numbers failed)",
        error(sms, ChannelsConformanceTest.sample()));
  }

  @Test
  void tlsIsVerifiedWithTheHostCheckForAnIpAddress() throws Exception {
    Certificates local = Certificates.make(dir, "ip:127.0.0.1,dns:localhost");
    try (TestServer server = TestServer.tls(local.server(), r -> new TestServer.Answer(200))) {
      assertTrue(server.url().startsWith("https://127.0.0.1:"));
      // The JDK's trust store does not know the certificate: refused, the path never quoted.
      Channel ch =
          Slack.channel(SlackOptions.builder().webhookUrl(server.url() + "/T/B/secret").build());
      String err = error(ch, ChannelsConformanceTest.sample());
      assertTrue(err.contains("SSLHandshakeException"), "a certificate no one trusts: " + err);
      assertFalse(err.contains("/T/B/secret"), err);
      assertTrue(server.seen().isEmpty());

      // Trusted, a certificate for the address is taken for it.
      try (JdkTransport trusting = new JdkTransport(local.trusting())) {
        Channel ok =
            Slack.channel(
                SlackOptions.builder()
                    .webhookUrl(server.url() + "/T/B/secret")
                    .transport(trusting)
                    .build());
        ok.send(ChannelsConformanceTest.sample(), QUIET);
        assertEquals(1, server.seen().size());
      }
    }
    // A trusted certificate for another address is refused at this one: the host check runs for
    // an IP address too, whatever SNI does (the JDK sends none for an address).
    Certificates other = Certificates.make(dir, "ip:127.0.0.2");
    try (TestServer server = TestServer.tls(other.server(), r -> new TestServer.Answer(200));
        JdkTransport trusting = new JdkTransport(other.trusting())) {
      Channel ch =
          Slack.channel(
              SlackOptions.builder()
                  .webhookUrl(server.url() + "/T/B/secret")
                  .transport(trusting)
                  .build());
      String err = error(ch, ChannelsConformanceTest.sample());
      assertTrue(err.contains("SSLHandshakeException"), err);
      assertTrue(server.seen().isEmpty());
    }
  }

  @Test
  void theHeadersTheDefaultTransportSendsInTheOrderItSendsThem() throws Exception {
    try (TestServer server = TestServer.start(r -> new TestServer.Answer(200));
        JdkTransport jdk = new JdkTransport()) {
      Post.fetch(
          jdk,
          30_000,
          server.url() + "/in",
          List.of(
              Map.entry("content-type", "application/json"),
              Map.entry("authorization", "Bearer x"),
              Map.entry("X-Custom", "1"),
              Map.entry("host", "evil.example"),
              Map.entry("content-length", "1"),
              Map.entry("connection", "keep-alive")),
          "{\"a\":1}");
      TestServer.Seen seen = server.seen().get(0);
      List<String> names = new ArrayList<>();
      for (Map.Entry<String, String> h : seen.headers()) {
        names.add(h.getKey());
      }
      // What the JDK sends: its own content-length, host and user-agent first, then the
      // request's sorted by name without regard to case (the JDK keeps them in a TreeMap), names
      // in the case given; host, content-length and connection given by the request are dropped.
      assertEquals(
          List.of(
              "Content-Length", "Host", "User-Agent", "authorization", "content-type", "X-Custom"),
          names,
          seen.headers().toString());
      assertEquals(server.url().substring("http://".length()), seen.header("host"));
      assertEquals("7", seen.header("content-length"));
      assertTrue(seen.header("user-agent").startsWith("Java-http-client/"));
      assertEquals("{\"a\":1}", new String(seen.body(), java.nio.charset.StandardCharsets.UTF_8));
    }
  }

  @Test
  void headersAreCheckedAndCredentialsTrimmed() throws Exception {
    Recorder rec = new Recorder(200, "{}");
    for (String value : List.of("Bearer a\r\nX-Evil: 1", "Bearer a\nb", "a\0b")) {
      Channel ch =
          Webhook.channel(
              WebhookOptions.builder()
                  .url("https://hooks.example.com/in")
                  .header("authorization", value)
                  .transport(rec)
                  .build());
      assertEquals(
          "the authorization header's value may not contain a line break",
          error(ch, ChannelsConformanceTest.sample()),
          Json.stringify(value));
    }
    Channel bad =
        Webhook.channel(
            WebhookOptions.builder()
                .url("https://hooks.example.com/in")
                .header("bad name", "x")
                .transport(rec)
                .build());
    assertTrue(
        error(bad, ChannelsConformanceTest.sample()).startsWith("a header name must be a token"));
    assertTrue(rec.taken().isEmpty(), "a request with a bad header was sent");

    List<Channel> channels =
        List.of(
            Resend.channel(
                ResendOptions.builder()
                    .apiKey(" re_secret\n")
                    .from("a@b.c")
                    .to("d@e.f")
                    .transport(rec)
                    .build()),
            Postmark.channel(
                PostmarkOptions.builder()
                    .serverToken("\tpm-secret ")
                    .from("a@b.c")
                    .to("d@e.f")
                    .transport(rec)
                    .build()),
            SendGrid.channel(
                SendGridOptions.builder()
                    .apiKey("SG.secret\n")
                    .from("a@b.c")
                    .to("d@e.f")
                    .transport(rec)
                    .build()),
            Mailgun.channel(
                MailgunOptions.builder()
                    .apiKey(" key-secret ")
                    .domain("mg.example.com")
                    .from("a@b.c")
                    .to("d@e.f")
                    .transport(rec)
                    .build()),
            Datadog.channel(DatadogOptions.builder().apiKey("dd-secret\n").transport(rec).build()),
            Honeybadger.channel(
                HoneybadgerOptions.builder().apiKey(" hb-secret").transport(rec).build()),
            Rollbar.channel(
                RollbarOptions.builder().accessToken("rb-secret \n").transport(rec).build()),
            Bugsnag.channel(BugsnagOptions.builder().apiKey("bs-secret\n").transport(rec).build()),
            NewRelic.channel(
                NewRelicOptions.builder()
                    .accountId("1")
                    .apiKey(" nr-secret")
                    .transport(rec)
                    .build()),
            Sentry.channel(
                SentryOptions.builder()
                    .dsn(" https://pubkey@o1.ingest.sentry.io/42\n")
                    .transport(rec)
                    .build()),
            Twilio.channel(
                TwilioOptions.builder()
                    .accountSid(" AC1 ")
                    .authToken("tok\n")
                    .from("+1")
                    .to("+2")
                    .transport(rec)
                    .build()),
            Ses.channel(
                SesOptions.builder()
                    .region("us-east-1")
                    .accessKeyId(" AKIDEXAMPLE")
                    .secretAccessKey("sekret\n")
                    .from("a@b.c")
                    .to("d@e.f")
                    .transport(rec)
                    .build()),
            Webhook.channel(
                WebhookOptions.builder()
                    .url("https://hooks.example.com/in")
                    .header("authorization", " Bearer wh-secret\n")
                    .transport(rec)
                    .build()));
    for (Channel ch : channels) {
      ch.send(ChannelsConformanceTest.sample(), QUIET);
    }
    List<Request> got = rec.taken();
    for (Request r : got) {
      for (Map.Entry<String, String> h : r.headers()) {
        assertEquals(h.getValue().strip(), h.getValue(), h.getKey() + " has spaces around it");
      }
    }
    assertEquals("Bearer re_secret", rec.header(0, "authorization"));
    assertEquals("pm-secret", rec.header(1, "x-postmark-server-token"));
    assertEquals("dd-secret", rec.header(4, "dd-api-key"));
    assertTrue(Recorder.body(got.get(7)).contains("\"apiKey\":\"bs-secret\""));
    assertEquals("https://api.twilio.com/2010-04-01/Accounts/AC1/Messages.json", got.get(10).url());
    assertEquals("Basic QUMxOnRvaw==", rec.header(10, "authorization"));
    assertTrue(
        rec.header(11, "authorization").startsWith("AWS4-HMAC-SHA256 Credential=AKIDEXAMPLE/"));
    assertEquals("Bearer wh-secret", rec.header(12, "authorization"));
    CronwatchException e =
        assertThrows(
            CronwatchException.class,
            () -> ResendOptions.builder().apiKey("  ").from("a@b.c").to("d@e.f").build());
    assertEquals("Resend needs an apiKey", e.getMessage());
    assertEquals(CronwatchException.Kind.INVALID, e.kind());
  }

  @Test
  void aSecretThatStraddlesTheCutIsStillCutOut() throws Exception {
    String key = String.join("-", "key", "0123456789abcdef", "0123456789abcdef").substring(0, 36);
    Recorder rec = new Recorder(401, "x".repeat(180) + "invalid key " + key);
    Channel ch =
        Mailgun.channel(
            MailgunOptions.builder()
                .apiKey(key)
                .domain("mg.example.com")
                .from("a@b.c")
                .to("d@e.f")
                .transport(rec)
                .build());
    String err = error(ch, ChannelsConformanceTest.sample());
    for (int i = 0; i + 6 <= key.length(); i++) {
      assertFalse(err.contains(key.substring(i, i + 6)), "a piece of the key survives: " + err);
    }
    assertTrue(err.endsWith(": " + "x".repeat(180) + "invalid key [redacte"), err);
    assertEquals("a".repeat(199), Post.errorBody("a".repeat(199) + "\ud83d\ude00tail", List.of()));
    String cut = Post.errorBody("y".repeat(10) + "sekret" + "z".repeat(300), List.of("sekret"));
    assertTrue(cut.startsWith("y".repeat(10) + "[redacted]"), cut);
  }

  @Test
  void aJsonBodyCutThroughASurrogatePairKeepsTheLoneHalf() throws Exception {
    Recorder rec = new Recorder(200, "");
    Alert sample = ChannelsConformanceTest.sample();
    Alert a =
        ChannelsConformanceTest.withText(
            sample,
            sample.title(),
            "a".repeat(2899) + "\ud83d\ude00 and on",
            "b".repeat(2989) + "\ud83d\ude00");
    Channel slack =
        Slack.channel(
            SlackOptions.builder()
                .webhookUrl("https://hooks.slack.example/T/B/secret")
                .transport(rec)
                .build());
    slack.send(a, QUIET);
    String body = Recorder.body(rec.taken().get(0));
    assertTrue(body.contains("a".repeat(2899) + "\\ud83d```"), body.substring(body.length() - 80));
    assertTrue(body.contains("b".repeat(2989) + "\\ud83d\""));
    assertInstanceOf(dev.cronwatch.json.JsObject.class, Json.parse(body));

    rec.answerWith(204, "");
    Alert d =
        ChannelsConformanceTest.withText(
            sample,
            sample.title(),
            "c".repeat(3799) + "\ud83d\ude00",
            "d".repeat(999) + "\ud83d\ude00");
    Channel discord =
        Discord.channel(
            DiscordOptions.builder()
                .webhookUrl("https://discord.example/api/webhooks/1/x")
                .transport(rec)
                .build());
    discord.send(d, QUIET);
    body = Recorder.body(rec.taken().get(0));
    assertTrue(body.contains("c".repeat(3799) + "\\ud83d\\n```"), body);
    assertTrue(body.contains("d".repeat(999) + "\\ud83d\""));
  }

  @Test
  void triageReachesARealServerThroughTheDefaultTransport() throws Exception {
    byte[] answer =
        "{\"stop_reason\":\"end_turn\",\"content\":[{\"type\":\"text\",\"text\":\"Disk full.\"}]}"
            .getBytes(java.nio.charset.StandardCharsets.UTF_8);
    try (TestServer api =
            TestServer.start(
                r ->
                    new TestServer.Answer(
                        200, List.of(Map.entry("content-type", "application/json")), answer));
        JdkTransport jdk = new JdkTransport()) {
      dev.cronwatch.triage.Anthropic triage =
          dev.cronwatch.triage.Anthropic.triage(
              dev.cronwatch.triage.AnthropicOptions.builder()
                  .apiKey("k")
                  .baseUrl(api.url())
                  .build());
      Alert sample = ChannelsConformanceTest.sample();
      assertEquals(
          "Disk full.", triage.triage(new dev.cronwatch.Triage.Context(sample, List.of(), jdk)));
      TestServer.Seen seen = api.seen().get(0);
      assertEquals("k", seen.header("x-api-key"));
      assertEquals("server-side-fallback-2026-07-01", seen.header("anthropic-beta"));
      assertEquals("cronwatch-java/" + dev.cronwatch.Cronwatch.VERSION, seen.header("user-agent"));
    }
  }

  @Test
  void theClientsTransportReachesAChannelGivenNone() throws Exception {
    Recorder rec = new Recorder(200, "");
    Channel slack = Slack.webhook("https://hooks.slack.example/T/B/secret");
    slack.send(ChannelsConformanceTest.sample(), new ChannelContext(e -> {}, rec));
    assertEquals(1, rec.taken().size());
    // One the channel names wins.
    Recorder own = new Recorder(200, "");
    Channel named =
        Slack.channel(
            SlackOptions.builder()
                .webhookUrl("https://hooks.slack.example/T/B/secret")
                .transport(own)
                .build());
    named.send(ChannelsConformanceTest.sample(), new ChannelContext(e -> {}, rec));
    assertEquals(1, own.taken().size());
    assertEquals(1, rec.taken().size());
    assertNotNull(new ChannelContext(e -> {}).transport());
  }
}
