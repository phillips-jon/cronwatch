package dev.cronwatch;

import static org.junit.jupiter.api.Assertions.assertEquals;

import java.util.List;
import java.util.Map;
import org.junit.jupiter.api.Test;

/**
 * The static factories of the records that may grow (plan D9) build what the canonical constructors
 * build today, so a store or an app built on them keeps compiling when one grows.
 */
class FactoriesTest {
  @Test
  void eachFactoryBuildsTheRecord() {
    Run run = Run.of("r", "j", RunStatus.OK, 1000, 1010L, 10L, null, "out", Metrics.empty(), "run");
    assertEquals(
        new Run("r", "j", RunStatus.OK, 1000, 1010L, 10L, null, "out", Metrics.empty(), "run"),
        run);
    Definition def = Definition.fromJson("{\"name\":\"j\"}");
    assertEquals(new StoredJob("j", def, 1, 2), StoredJob.of("j", def, 1, 2));
    JobState state =
        JobState.of("j", Map.of(Condition.STUCK, 5L), 1, null, 6L, List.of(), List.of(), 3L);
    assertEquals(
        "{\"job\":\"j\",\"open\":{\"stuck\":5},\"consecutiveFailures\":1,\"silencedUntil\":null,"
            + "\"lastAlertAt\":6,\"pendingRecovery\":[],\"undelivered\":[],\"version\":3}",
        state.toJson());
    assertEquals(state.toJson(), JobState.fromJson(state.toJson()).toJson());
    AlertDetails details = new AlertDetails.Failure(1, 1);
    Alert alert =
        Alert.of(AlertType.FAILED, run, details, "j", def, "j failed", "boom", null, false, 7);
    assertEquals(
        new Alert(AlertType.FAILED, run, details, "j", def, "j failed", "boom", null, false, 7),
        alert);
    JobSummary.Stats stats = new JobSummary.Stats(1, 1, 10L, 10L);
    JobSummary summary =
        JobSummary.of("j", def, JobHealth.HEALTHY, List.of(), run, null, 0, null, stats);
    assertEquals(
        new JobSummary("j", def, JobHealth.HEALTHY, List.of(), run, null, 0, null, stats), summary);
    assertEquals(
        new CheckResult(7, List.of(summary), List.of(alert), 0),
        CheckResult.of(7, List.of(summary), List.of(alert), 0));
  }
}
