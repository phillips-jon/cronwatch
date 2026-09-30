package dev.cronwatch.internal.evaluate;

import static org.junit.jupiter.api.Assertions.assertTrue;

import dev.cronwatch.Alert;
import dev.cronwatch.Fixtures;
import dev.cronwatch.JobState;
import dev.cronwatch.Run;
import dev.cronwatch.StoredJob;
import dev.cronwatch.internal.evaluate.Evaluate.AlertDraft;
import dev.cronwatch.internal.evaluate.Evaluate.Evaluation;
import dev.cronwatch.json.JsObject;
import dev.cronwatch.json.Json;
import java.util.ArrayList;
import java.util.List;
import java.util.function.Supplier;
import org.jspecify.annotations.Nullable;
import org.junit.jupiter.api.Test;

/**
 * {@code conformance/health.json}: health, summaries, percentiles, state normalization, silence,
 * which queued alerts a retry drops, a run's duration, a state's version and its failures in a row.
 */
class HealthConformanceTest {
  private static List<Run> runs(@Nullable Object v) {
    List<Run> out = new ArrayList<>();
    if (v instanceof List<?> list) {
      for (Object r : list) {
        if (r != null) {
          out.add(Run.fromValue(r));
        }
      }
    }
    return out;
  }

  private static JobState state(@Nullable Object v) {
    return JobState.fromValue(v);
  }

  private static StoredJob stored(@Nullable Object v) {
    JsObject o = (JsObject) v;
    return new StoredJob(
        Fixtures.string(o, "name"),
        Cases.definition(o.get("definition")),
        Fixtures.integer(o, "createdAt"),
        Fixtures.integer(o, "updatedAt"));
  }

  private static List<Double> numbers(@Nullable Object v) {
    List<Double> out = new ArrayList<>();
    if (v instanceof List<?> list) {
      for (Object n : list) {
        if (n instanceof Number x) {
          out.add(x.doubleValue());
        }
      }
    }
    return out;
  }

  /** What a function answers, or {@code error: <message>} as the fixture writes a throw. */
  private static @Nullable Object orError(Supplier<@Nullable Object> f) {
    try {
      return f.get();
    } catch (IllegalArgumentException e) {
      return "error: " + e.getMessage();
    }
  }

  @Test
  void everyCaseAnswersAsTheSdkAnswers() {
    JsObject f = Fixtures.load("health");
    Fixtures.Failures fails = new Fixtures.Failures();
    int cases = 0;
    int i = 0;
    for (JsObject c : Fixtures.objects(f, "jobHealth")) {
      cases++;
      Object got =
          orError(
              () ->
                  Evaluate.jobHealth(
                          Cases.definition(c.get("definition")),
                          Cases.run(c.get("lastRun")),
                          state(c.get("state")),
                          Fixtures.integer(c, "now"))
                      .value());
      fails.same("jobHealth " + i++, got, c.get("health"));
    }
    i = 0;
    for (JsObject c : Fixtures.objects(f, "summarize")) {
      cases++;
      Object got =
          orError(
              () ->
                  Evaluate.summarize(
                          stored(c.get("stored")),
                          runs(c.get("recent")),
                          state(c.get("state")),
                          Fixtures.optInteger(c, "nextExpectedAt"),
                          Fixtures.integer(c, "now"))
                      .toValue());
      fails.same("summarize " + i++, got, c.get("summary"));
    }
    for (JsObject c : Fixtures.objects(f, "percentile")) {
      cases++;
      double p = Fixtures.number(c, "p");
      fails.same(
          "percentile(" + Json.stringify(c.get("values")) + ", " + p + ")",
          Stats.percentile(numbers(c.get("values")), p),
          c.get("percentile"));
    }
    for (JsObject c : Fixtures.objects(f, "median")) {
      cases++;
      fails.same(
          "median(" + Json.stringify(c.get("values")) + ")",
          Stats.median(numbers(c.get("values"))),
          c.get("median"));
    }
    i = 0;
    for (JsObject c : Fixtures.objects(f, "normalizeState")) {
      cases++;
      JobState input = c.get("state") == null ? null : state(c.get("state"));
      fails.same(
          "normalizeState " + i++,
          Evaluate.normalizeState(input, "j").toValue(),
          c.get("normalized"));
    }
    i = 0;
    for (JsObject c : Fixtures.objects(f, "muteOpens")) {
      cases++;
      fails.same(
          "muteOpens " + i++,
          Evaluate.muteOpens(state(c.get("previous")), state(c.get("next"))).toValue(),
          c.get("muted"));
    }
    i = 0;
    for (JsObject c : Fixtures.objects(f, "isStuck")) {
      cases++;
      Object got =
          orError(
              () ->
                  Evaluate.isStuck(
                      Cases.definition(c.get("definition")),
                      Cases.run(c.get("run")),
                      Fixtures.integer(c, "now")));
      fails.same("isStuck " + i++, got, c.get("stuck"));
    }
    i = 0;
    for (JsObject c : Fixtures.objects(f, "unevaluableSummary")) {
      cases++;
      fails.same(
          "unevaluableSummary " + i++,
          Evaluate.unevaluableSummary(
                  stored(c.get("stored")),
                  runs(c.get("recent")),
                  state(c.get("state")),
                  Fixtures.integer(c, "now"))
              .toValue(),
          c.get("summary"));
    }
    i = 0;
    for (JsObject c : Fixtures.objects(f, "applySilence")) {
      cases++;
      JsObject e = Fixtures.object(c, "evaluation");
      List<AlertDraft> drafts = new ArrayList<>();
      for (Object d : Fixtures.list(e, "alerts")) {
        drafts.add(Cases.draft(d));
      }
      Evaluation out =
          Evaluate.applySilence(
              state(c.get("previous")),
              new Evaluation(state(e.get("state")), drafts),
              Fixtures.integer(c, "now"));
      List<Object> alerts = new ArrayList<>();
      for (AlertDraft d : out.alerts()) {
        alerts.add(d.toValue());
      }
      fails.same(
          "applySilence " + i++,
          new JsObject().set("state", out.state().toValue()).set("alerts", alerts),
          c.get("result"));
    }
    i = 0;
    for (JsObject c : Fixtures.objects(f, "staleAlert")) {
      cases++;
      fails.same(
          "staleAlert " + i++,
          Evaluate.staleAlert(Alert.fromValue(c.get("alert")), state(c.get("state"))),
          c.get("stale"));
    }
    i = 0;
    for (JsObject c : Fixtures.objects(f, "runDuration")) {
      cases++;
      fails.same(
          "runDuration " + i++,
          Evaluate.runDuration(Fixtures.integer(c, "startedAt"), Fixtures.integer(c, "finishedAt")),
          c.get("durationMs"));
    }
    i = 0;
    for (JsObject c : Fixtures.objects(f, "stateVersion")) {
      cases++;
      String text = Fixtures.string(c, "state");
      Object parsed = Json.parse(text);
      long fromValue =
          Evaluate.stateVersion(parsed instanceof JsObject o ? o.get("version") : null);
      fails.same("stateVersion " + i, fromValue, c.get("version"));
      fails.same(
          "stateVersion " + i++ + ", read as a state",
          JobState.fromJson(text).countedVersion(),
          c.get("version"));
    }
    i = 0;
    long t0 = 1_767_605_400_000L;
    Run failedRun =
        Run.fromValue(
            Json.parse(
                "{\"id\":\"f\",\"job\":\"j\",\"status\":\"failed\",\"startedAt\":"
                    + (t0 - 60_000)
                    + ",\"finishedAt\":"
                    + (t0 - 59_000)
                    + ",\"durationMs\":1000,\"error\":\"Error: boom\",\"output\":null,"
                    + "\"metrics\":{},\"trigger\":\"run\"}"));
    var failedDef = Cases.definition(Json.parse("{\"name\":\"j\",\"failuresBeforeAlert\":3}"));
    for (JsObject c : Fixtures.objects(f, "failureCount")) {
      cases++;
      String text = Fixtures.string(c, "state");
      Object parsed = Json.parse(text);
      fails.same(
          "failureCount " + i,
          Evaluate.failureCount(parsed instanceof JsObject o ? o.get("consecutiveFailures") : null),
          c.get("consecutiveFailures"));
      JobState normalized = Evaluate.normalizeState(JobState.fromJson(text), "j");
      fails.same(
          "failureCount " + i + ", read as a state",
          normalized.consecutiveFailures(),
          c.get("consecutiveFailures"));
      Evaluation out = Evaluate.onRunFinish(failedDef, failedRun, normalized, List.of(), t0);
      List<Object> alerts = new ArrayList<>();
      for (AlertDraft d : out.alerts()) {
        alerts.add(d.toValue());
      }
      fails.same(
          "failureCount " + i++ + ", then a failed run",
          new JsObject().set("state", out.state().toValue()).set("alerts", alerts),
          c.get("failed"));
    }
    assertTrue(cases == 164, "health.json cases: " + cases);
    fails.check("health");
  }
}
