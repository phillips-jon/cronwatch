package dev.cronwatch.internal.evaluate;

import static org.junit.jupiter.api.Assertions.assertEquals;

import dev.cronwatch.Definition;
import dev.cronwatch.Fixtures;
import dev.cronwatch.JobState;
import dev.cronwatch.JobSummary;
import dev.cronwatch.Metrics;
import dev.cronwatch.Run;
import dev.cronwatch.RunStatus;
import dev.cronwatch.StoredJob;
import dev.cronwatch.internal.duration.Durations;
import dev.cronwatch.internal.evaluate.Evaluate.AlertDraft;
import dev.cronwatch.internal.evaluate.Evaluate.CheckOutcome;
import dev.cronwatch.internal.evaluate.Evaluate.Evaluation;
import dev.cronwatch.json.JsObject;
import java.util.ArrayList;
import java.util.Comparator;
import java.util.List;
import java.util.Objects;
import org.jspecify.annotations.Nullable;
import org.junit.jupiter.api.Test;

/**
 * {@code conformance/evaluate.json}: each scenario plays a job's life through the pure functions
 * the way the client does (a run's start and finish, a check with stuck runs first and then missed,
 * a silence, a changed definition), and every event's alerts and state must be the SDK's, byte for
 * byte.
 */
class EvaluateConformanceTest {
  /** {@code scripts/conformance.mjs}'s {@code Sim}: one job, its runs, and its state. */
  private static final class Sim {
    Definition def;
    StoredJob stored;
    JobState state;

    /** Each run and the order it was started in, which breaks ties. */
    final List<Run> runs = new ArrayList<>();

    final List<Integer> order = new ArrayList<>();

    Sim(Definition def, long createdAt) {
      this.def = def;
      this.stored = new StoredJob(def.name(), def, createdAt, createdAt);
      this.state = Evaluate.emptyState(def.name());
    }

    /** The runs newest first, ties broken by insertion. */
    List<Run> sorted() {
      List<Integer> idx = new ArrayList<>();
      for (int i = 0; i < runs.size(); i++) {
        idx.add(i);
      }
      idx.sort(
          Comparator.comparingLong((Integer i) -> runs.get(i).startedAt())
              .thenComparingInt(order::get)
              .reversed());
      List<Run> out = new ArrayList<>();
      for (int i : idx) {
        out.add(runs.get(i));
      }
      return out;
    }

    /** Saves an evaluation as the client does (silence applied), returning its alerts' JSON. */
    List<Object> settle(JobState previous, Evaluation e, long now) {
      Evaluation settled = Evaluate.applySilence(previous, e, now);
      state = settled.state();
      List<Object> out = new ArrayList<>();
      for (AlertDraft d : settled.alerts()) {
        out.add(Format.composeAlert(d, def, now).toValue());
      }
      return out;
    }

    List<Object> finishRun(Run run, long now) {
      List<Run> history = new ArrayList<>();
      for (Run r : sorted()) {
        if (!r.id().equals(run.id())) {
          history.add(r);
        }
      }
      JobState previous = state;
      return settle(previous, Evaluate.onRunFinish(def, run, previous, history, now), now);
    }

    int index(String id) {
      for (int i = 0; i < runs.size(); i++) {
        if (runs.get(i).id().equals(id)) {
          return i;
        }
      }
      throw new IllegalStateException("no run " + id);
    }

    /** Plays one event, returning what the fixture expects of it, or null for none. */
    @Nullable JsObject play(JsObject ev) {
      long at = Fixtures.integer(ev, "at");
      String op = Objects.requireNonNull(Fixtures.string(ev, "op"));
      return switch (op) {
        case "start" -> {
          order.add(runs.size());
          runs.add(Run.running(Fixtures.string(ev, "id"), def.name(), at, "run"));
          state = Evaluate.onRunStart(state);
          yield new JsObject().set("state", state.toValue());
        }
        case "finish" -> {
          int i = index(Objects.requireNonNull(Fixtures.string(ev, "id")));
          Run run = runs.get(i);
          if (run.status().equals(RunStatus.OK) || run.status().equals(RunStatus.FAILED)) {
            yield new JsObject()
                .set("alerts", List.of())
                .set("state", state.toValue())
                .set("ignored", "was already finished as " + run.status());
          }
          boolean marked = run.status().equals(RunStatus.TIMEOUT);
          Metrics metrics =
              ev.has("metrics") ? Metrics.fromValue(ev.get("metrics")) : Metrics.empty();
          run =
              run.finished(
                  RunStatus.of(Objects.requireNonNull(Fixtures.string(ev, "status"))),
                  at,
                  Evaluate.runDuration(run.startedAt(), at),
                  Fixtures.string(ev, "error"),
                  Fixtures.string(ev, "output"),
                  metrics);
          runs.set(i, run);
          if (marked && !run.status().equals(RunStatus.OK)) {
            yield new JsObject().set("alerts", List.of()).set("state", state.toValue());
          }
          List<Object> alerts = finishRun(run, at);
          yield new JsObject().set("alerts", alerts).set("state", state.toValue());
        }
        case "check" -> {
          long now = at;
          List<Object> alerts = new ArrayList<>();
          List<Integer> running = new ArrayList<>();
          for (int i = 0; i < runs.size(); i++) {
            if (runs.get(i).status().equals(RunStatus.RUNNING)) {
              running.add(i);
            }
          }
          running.sort(
              Comparator.comparingLong((Integer i) -> runs.get(i).startedAt())
                  .thenComparingInt(order::get));
          for (int i : running) {
            Run r = runs.get(i);
            if (!Evaluate.isStuck(def, r, now)) {
              continue;
            }
            double timeout = Evaluate.timeoutMs(def);
            r =
                r.finished(
                    RunStatus.TIMEOUT,
                    now,
                    Evaluate.runDuration(r.startedAt(), now),
                    "Still running after " + Durations.format(timeout) + "; marked as timed out",
                    r.output(),
                    r.metrics());
            runs.set(i, r);
            alerts.addAll(finishRun(r, now));
          }
          List<Run> recent = sorted();
          recent = recent.subList(0, Math.min(recent.size(), Evaluate.BASELINE_WINDOW));
          JobState previous = state;
          CheckOutcome out =
              Evaluate.onCheck(def, stored, recent.isEmpty() ? null : recent.get(0), previous, now);
          alerts.addAll(settle(previous, out.evaluation(), now));
          JobSummary summary = Evaluate.summarize(stored, recent, state, out.nextExpectedAt(), now);
          yield new JsObject()
              .set("alerts", alerts)
              .set("state", state.toValue())
              .set("nextExpectedAt", out.nextExpectedAt())
              .set("dueAt", out.dueAt())
              .set("summary", summary.toValue());
        }
        case "silence" -> {
          MutableState s = MutableState.of(state);
          s.silencedUntil = Fixtures.integer(ev, "until");
          state = s.toState();
          yield new JsObject().set("state", state.toValue());
        }
        case "unsilence" -> {
          MutableState s = MutableState.of(state);
          s.silencedUntil = null;
          state = s.toState();
          yield new JsObject().set("state", state.toValue());
        }
        case "define" -> {
          def = Cases.definition(ev.get("definition"));
          stored = new StoredJob(stored.name(), def, stored.createdAt(), stored.updatedAt());
          yield null;
        }
        default -> throw new IllegalStateException("unknown op " + op);
      };
    }
  }

  @Test
  void everyScenarioPlaysAsTheSdkPlaysIt() {
    JsObject f = Fixtures.load("evaluate");
    Fixtures.Failures fails = new Fixtures.Failures();
    List<JsObject> scenarios = Fixtures.objects(f, "scenarios");
    assertEquals(56, scenarios.size(), "evaluate.json scenarios");
    int events = 0;
    for (JsObject sc : scenarios) {
      String name = Fixtures.string(sc, "name");
      Sim sim = new Sim(Cases.definition(sc.get("definition")), Fixtures.integer(sc, "createdAt"));
      int i = 0;
      for (JsObject ev : Fixtures.objects(sc, "events")) {
        events++;
        String what = name + ": event " + i++ + " (" + Fixtures.string(ev, "op") + ")";
        try {
          JsObject got = sim.play(ev);
          if (got != null) {
            fails.same(what, got, ev.get("expect"));
          }
        } catch (RuntimeException e) {
          fails.fail(what + ": " + e);
          break;
        }
      }
    }
    assertEquals(true, events > 0, "no events replayed");
    fails.check("evaluate");
  }
}
