package dev.cronwatch.internal.evaluate;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertNull;

import dev.cronwatch.AlertDetails;
import dev.cronwatch.AlertType;
import dev.cronwatch.BudgetBreach;
import dev.cronwatch.Condition;
import dev.cronwatch.Definition;
import dev.cronwatch.JobState;
import dev.cronwatch.Metrics;
import dev.cronwatch.Run;
import dev.cronwatch.RunStatus;
import dev.cronwatch.internal.evaluate.Evaluate.AlertDraft;
import dev.cronwatch.internal.evaluate.Evaluate.Evaluation;
import dev.cronwatch.json.JsObject;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import org.junit.jupiter.api.Test;

/** The SDK's {@code floors} test of {@code evaluate.test.ts}. */
class FloorsTest {
  private static final long T0 = 1_767_600_000_000L;
  private static final long HOUR = 3_600_000;

  private static Run run(long at, Map<String, ? extends Number> metrics) {
    return Run.of(
        "r" + at,
        "j",
        RunStatus.OK,
        at,
        at + 1000,
        1000L,
        null,
        null,
        Metrics.of(metrics),
        "schedule");
  }

  private static Map<String, Integer> metrics(String a, int av, String b, int bv) {
    Map<String, Integer> m = new LinkedHashMap<>();
    m.put(a, av);
    m.put(b, bv);
    return m;
  }

  private static Definition def(JsObject floor) {
    JsObject o = new JsObject().set("name", "j");
    if (!floor.isEmpty()) {
      o.set("floor", floor);
    }
    return Definition.of(o);
  }

  private static List<String> types(Evaluation e) {
    List<String> out = new ArrayList<>();
    for (AlertDraft a : e.alerts()) {
      out.add(a.type().value());
    }
    return out;
  }

  private static List<BudgetBreach> breaches(AlertDraft a) {
    return ((AlertDetails.UnderFloor) a.details()).breaches();
  }

  @Test
  void aFloorOrZeroAfterFiveRunsThatAllReportedMore() {
    Definition floored = def(new JsObject().set("rows", 10));
    Evaluation shortfall =
        Evaluate.onRunFinish(
            floored, run(T0, Map.of("rows", 9)), JobState.empty("j"), List.of(), T0 + 1000);
    assertEquals(List.of("under_floor"), types(shortfall));
    assertEquals(
        List.of(new BudgetBreach("rows", 9, 10, "floor")), breaches(shortfall.alerts().get(0)));
    Evaluation back =
        Evaluate.onRunFinish(
            floored, run(T0 + HOUR, Map.of("rows", 10)), shortfall.state(), List.of(), T0 + HOUR);
    assertEquals(List.of("recovered"), types(back));
    assertNull(back.state().underFloor());

    Definition bare = def(new JsObject());
    List<Run> history = new ArrayList<>();
    for (int i = 1; i <= 5; i++) {
      history.add(run(T0 - i * HOUR, metrics("rows", 100 * i, "errors", 0)));
    }
    assertEquals(
        List.of(),
        Evaluate.onRunFinish(
                bare, run(T0, Map.of("rows", 0)), JobState.empty("j"), history.subList(1, 5), T0)
            .alerts(),
        "four runs are not a baseline");
    assertEquals(
        List.of(),
        Evaluate.onRunFinish(
                bare, run(T0, metrics("rows", 1, "errors", 0)), JobState.empty("j"), history, T0)
            .alerts(),
        "an always-0 metric never alerts");
    Evaluation zero =
        Evaluate.onRunFinish(
            bare, run(T0, metrics("rows", 0, "errors", 0)), JobState.empty("j"), history, T0);
    assertEquals(
        List.of(
            new BudgetBreach(
                "rows", 0, 100, "the last 5 runs all reported more than 0, the lowest 100")),
        breaches(zero.alerts().get(0)));
    assertEquals(List.of("rows"), zero.state().underFloor());

    // A job that keeps writing nothing stays open, past the point where its zeros are all the
    // history there is.
    JobState state = zero.state();
    List<Run> runs = new ArrayList<>(history);
    for (int i = 1; i <= 30; i++) {
      runs.add(0, run(T0 + (i - 1) * HOUR, metrics("rows", 0, "errors", 0)));
      Evaluation next =
          Evaluate.onRunFinish(
              bare,
              run(T0 + i * HOUR, metrics("rows", 0, "errors", 0)),
              state,
              runs.subList(0, Math.min(25, runs.size())),
              T0 + i * HOUR);
      assertEquals(List.of(), next.alerts());
      assertEquals(T0, next.state().openAt(Condition.UNDER_FLOOR));
      state = next.state();
    }
    Evaluation recovered =
        Evaluate.onRunFinish(
            bare,
            run(T0 + 31 * HOUR, metrics("rows", 5, "errors", 0)),
            state,
            runs.subList(0, Math.min(25, runs.size())),
            T0 + 31 * HOUR);
    assertEquals(List.of("recovered"), types(recovered));
    assertEquals(
        List.of(Condition.UNDER_FLOOR),
        ((AlertDetails.Recovered) recovered.alerts().get(0).details()).after());

    // A metric that has reported 0 before is judged as usual for it, and a floor of 0 turns the
    // check off.
    List<Run> mixed = new ArrayList<>(history.subList(0, 4));
    mixed.add(run(T0 - 6 * HOUR, Map.of("rows", 0)));
    assertEquals(
        List.of(),
        Evaluate.onRunFinish(bare, run(T0, Map.of("rows", 0)), JobState.empty("j"), mixed, T0)
            .alerts());
    assertEquals(
        List.of(),
        Evaluate.onRunFinish(
                def(new JsObject().set("rows", 0)),
                run(T0, Map.of("rows", 0)),
                JobState.empty("j"),
                history,
                T0)
            .alerts());
    assertEquals(AlertType.UNDER_FLOOR, AlertType.of(Condition.UNDER_FLOOR));
  }
}
