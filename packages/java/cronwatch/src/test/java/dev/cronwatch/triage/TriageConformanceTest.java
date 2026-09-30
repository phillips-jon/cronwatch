package dev.cronwatch.triage;

import static org.junit.jupiter.api.Assertions.assertEquals;

import dev.cronwatch.Alert;
import dev.cronwatch.Cronwatch;
import dev.cronwatch.Fixtures;
import dev.cronwatch.Run;
import dev.cronwatch.Triage;
import dev.cronwatch.alerts.Request;
import dev.cronwatch.alerts.Response;
import dev.cronwatch.alerts.Transport;
import dev.cronwatch.json.JsObject;
import dev.cronwatch.json.Json;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.concurrent.CopyOnWriteArrayList;
import org.junit.jupiter.api.Test;

/**
 * Replays {@code conformance/triage.json}: the parameters the SDK hands the official client for
 * each context and option set, the diagnosis read from each answer, and (the {@code wire} cases)
 * the HTTP request that client sends, which the port makes itself.
 */
class TriageConformanceTest {
  /** The fixture's triage contexts, by name. */
  static Map<String, Triage.Context> contexts(JsObject f) {
    Map<String, Triage.Context> out = new HashMap<>();
    for (JsObject c : Fixtures.objects(f, "contexts")) {
      List<Run> runs = new ArrayList<>();
      for (Object r : Fixtures.list(c, "recentRuns")) {
        runs.add(Run.fromValue(r));
      }
      out.put(
          Fixtures.string(c, "name"), new Triage.Context(Alert.fromValue(c.get("alert")), runs));
    }
    return out;
  }

  /** A fixture's option set. */
  static AnthropicOptions.Builder options(JsObject o) {
    AnthropicOptions.Builder b = AnthropicOptions.builder();
    if (o.get("model") instanceof String m) {
      b.model(m);
    }
    if (o.get("effort") instanceof String e) {
      b.effort(e);
    }
    if (o.get("context") instanceof String c) {
      b.context(c);
    }
    if (o.get("maxTokens") instanceof Number n) {
      b.maxTokens(n.longValue());
    }
    if (Boolean.FALSE.equals(o.get("fallbacks"))) {
      b.noFallbacks();
    }
    return b;
  }

  /** Answers every request with one Messages API answer and keeps the request. */
  static final class Recorder implements Transport {
    final List<Request> taken = new CopyOnWriteArrayList<>();

    @Override
    public Response post(Request request) {
      taken.add(request);
      return Response.of(
          200,
          "{\"id\":\"msg_1\",\"type\":\"message\",\"role\":\"assistant\",\"model\":\"m\","
              + "\"stop_reason\":\"end_turn\",\"content\":[{\"type\":\"text\",\"text\":\"ok\"}],"
              + "\"usage\":{}}");
    }
  }

  @Test
  void everyCaseOfTriageJsonIsTheSdks() throws Exception {
    JsObject f = Fixtures.load("triage");
    Map<String, Triage.Context> byName = contexts(f);
    Fixtures.Failures failures = new Fixtures.Failures();
    int count = 0;
    for (JsObject c : Fixtures.objects(f, "requests")) {
      JsObject o = Fixtures.object(c, "options");
      String context = Fixtures.string(c, "context");
      JsObject params = Anthropic.params(options(o).build(), byName.get(context));
      failures.same(o.toJson() + " " + context + ": params", params, c.get("params"));
      JsObject ro = Fixtures.object(c, "requestOptions");
      assertEquals(Anthropic.REQUEST_TIMEOUT_MS, Fixtures.integer(ro, "timeout"));
      assertEquals(0, Fixtures.integer(ro, "maxRetries"));
      count++;
    }
    for (JsObject c : Fixtures.objects(f, "responses")) {
      String got = Anthropic.diagnosis(c.get("response"));
      Object want = c.get("result");
      failures.same(Json.stringify(c.get("response")), got.isEmpty() ? null : got, want);
      count++;
    }
    Set<String> kept =
        Set.of("accept", "anthropic-beta", "anthropic-version", "content-type", "x-api-key");
    for (JsObject c : Fixtures.objects(f, "wire")) {
      JsObject o = Fixtures.object(c, "options");
      Recorder rec = new Recorder();
      Anthropic triage =
          Anthropic.triage(
              options(o)
                  .apiKey("test-key")
                  .baseUrl("https://api.anthropic.com")
                  .transport(rec)
                  .build());
      String context = Fixtures.string(c, "context");
      assertEquals("ok", triage.triage(byName.get(context)));
      assertEquals(1, rec.taken.size());
      Request r = rec.taken.get(0);
      JsObject want = Fixtures.object(c, "request");
      assertEquals("POST", want.get("method"));
      failures.same(o.toJson() + ": url", r.url(), want.get("url"));
      JsObject headers = new JsObject();
      for (Map.Entry<String, String> h : r.headers()) {
        if (kept.contains(h.getKey())) {
          headers.set(h.getKey(), h.getValue());
        }
      }
      failures.same(o.toJson() + ": headers", headers, want.get("headers"));
      assertEquals("cronwatch-java/" + Cronwatch.VERSION, r.header("user-agent"));
      failures.same(
          o.toJson() + ": body",
          Fixtures.digest(new String(r.body(), StandardCharsets.UTF_8)),
          want.get("body"));
      count++;
    }
    failures.check("triage");
    int total = 0;
    for (String key : List.of("requests", "responses", "wire")) {
      total += Fixtures.objects(f, key).size();
    }
    assertEquals(total, count);
    System.out.println("triage.json: " + count + " cases replayed");
  }
}
