package dev.cronwatch.triage;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertNull;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;

import dev.cronwatch.Alert;
import dev.cronwatch.Cronwatch;
import dev.cronwatch.CronwatchException;
import dev.cronwatch.Fixtures;
import dev.cronwatch.JobOptions;
import dev.cronwatch.Triage;
import dev.cronwatch.alerts.Transport;
import dev.cronwatch.alerts.Transport.Request;
import dev.cronwatch.alerts.Transport.Response;
import dev.cronwatch.json.JsObject;
import java.util.List;
import java.util.concurrent.CopyOnWriteArrayList;
import java.util.concurrent.atomic.AtomicLong;
import org.junit.jupiter.api.Assumptions;
import org.junit.jupiter.api.Test;

/** Claude triage beyond the fixture: refusals, answers that are not JSON, the key, a client. */
class AnthropicTest {
  static Triage.Context context() {
    JsObject f = Fixtures.load("triage");
    return TriageConformanceTest.contexts(f).get("a failure with earlier runs");
  }

  static Transport answering(int status, String body, List<Request> taken) {
    return request -> {
      taken.add(request);
      return Response.of(status, body);
    };
  }

  @Test
  void aRefusedRequestNamesTheStatusAndTheAnswerWithTheKeyCutOut() {
    List<Request> taken = new CopyOnWriteArrayList<>();
    String key = "test-" + "key-" + "0001";
    Anthropic triage =
        Anthropic.triage(
            AnthropicOptions.builder()
                .apiKey(" " + key + "\n")
                .baseUrl("https://gateway.example/anthropic//")
                .transport(answering(401, "{\"error\":\"bad key " + key + "\"}", taken))
                .build());
    CronwatchException e = assertThrows(CronwatchException.class, () -> triage.triage(context()));
    assertEquals(
        "Anthropic https://gateway.example answered 401: {\"error\":\"bad key [redacted]\"}",
        e.getMessage());
    assertEquals("https://gateway.example/anthropic/v1/messages?beta=true", taken.get(0).url());
    assertEquals(key, taken.get(0).header("x-api-key"));
    assertFalse(triage.toString().contains(key), triage.toString());
  }

  @Test
  void anAnswerThatIsNotJsonIsAnErrorAndAnEmptyOneNoDiagnosis() throws Exception {
    List<Request> taken = new CopyOnWriteArrayList<>();
    Anthropic bad =
        Anthropic.triage(
            AnthropicOptions.builder()
                .apiKey("k")
                .baseUrl("https://api.anthropic.com")
                .transport(answering(200, "not json", taken))
                .build());
    CronwatchException e = assertThrows(CronwatchException.class, () -> bad.triage(context()));
    assertTrue(
        e.getMessage()
            .startsWith(
                "Anthropic https://api.anthropic.com answered 200 with JSON that could not be read: "),
        e.getMessage());
    Anthropic refusal =
        Anthropic.triage(
            AnthropicOptions.builder()
                .apiKey("k")
                .baseUrl("https://api.anthropic.com")
                .transport(answering(200, "{\"stop_reason\":\"refusal\",\"content\":[]}", taken))
                .build());
    assertNull(refusal.triage(context()));
  }

  @Test
  void withNoKeyTriageSaysWhereToPutOne() {
    Assumptions.assumeTrue(
        System.getenv("ANTHROPIC_API_KEY") == null, "ANTHROPIC_API_KEY is set here");
    CronwatchException e =
        assertThrows(CronwatchException.class, () -> Anthropic.triage().triage(context()));
    assertEquals("Anthropic triage needs an apiKey, or ANTHROPIC_API_KEY set", e.getMessage());
  }

  @Test
  void aClientTriagesItsAlertsThroughItsOwnTransport() throws Exception {
    List<Request> taken = new CopyOnWriteArrayList<>();
    Transport transport =
        answering(
            200,
            "{\"stop_reason\":\"end_turn\",\"content\":[{\"type\":\"text\",\"text\":\" Disk full. \"}]}",
            taken);
    List<Alert> alerts = new CopyOnWriteArrayList<>();
    AtomicLong clock = new AtomicLong(1767225600000L);
    try (Cronwatch cw =
        Cronwatch.builder()
            .clock(clock::get)
            .noShutdownHook()
            .onError((where, e) -> {})
            .transport(transport)
            .triage(
                Anthropic.triage(
                    AnthropicOptions.builder()
                        .apiKey("k")
                        .baseUrl("https://api.anthropic.com")
                        .build()))
            .alert(dev.cronwatch.Channel.of("capture", (alert, ctx) -> alerts.add(alert)))
            .build()) {
      cw.job("nightly", JobOptions.builder().schedule("0 * * * *"));
      cw.check();
      clock.addAndGet(70 * 60_000L);
      cw.check();
    }
    assertEquals(1, alerts.size());
    assertEquals("Disk full.", alerts.get(0).triage());
    assertEquals(1, taken.size());
    assertEquals("cronwatch-java/" + Cronwatch.VERSION, taken.get(0).header("user-agent"));
  }
}
