package dev.cronwatch;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertTrue;

import java.io.IOException;
import java.nio.file.Files;
import java.nio.file.Path;
import java.time.Instant;
import java.time.ZoneId;
import java.util.List;
import java.util.Set;
import java.util.TimeZone;
import java.util.stream.Stream;
import org.junit.jupiter.api.Test;

/**
 * The fixtures in {@code conformance/}, which {@code scripts/conformance.mjs} writes by running the
 * TypeScript SDK. Each is replayed by the tests beside the code it holds to the SDK; this test
 * fails when the SDK writes a fixture this port does not know, until it is placed.
 */
class ConformanceTest {
  /** Every fixture, each replayed beside the code it holds to the SDK. */
  static final Set<String> REPLAYED =
      Set.of(
          "client",
          "duration",
          "schedule",
          "output",
          "evaluate",
          "format",
          "health",
          "store",
          "channels",
          "triage",
          "pgcron");

  @Test
  void everyFixtureIsKnown() throws IOException {
    List<String> unknown;
    try (Stream<Path> files = Files.list(Fixtures.conformanceDir())) {
      unknown =
          files
              .map(p -> p.getFileName().toString())
              .filter(n -> n.endsWith(".json"))
              .map(n -> n.substring(0, n.length() - 5))
              .filter(n -> !REPLAYED.contains(n))
              .sorted()
              .toList();
    }
    assertTrue(unknown.isEmpty(), "conformance/ has fixtures this port does not know: " + unknown);
  }

  /**
   * The fixtures are made with {@code TZ=UTC}, and a schedule without a zone is read in the JVM's
   * own, so Surefire sets both {@code TZ} and {@code user.timezone}; this fails when something runs
   * the tests without them.
   */
  @Test
  void theTestsRunInUtc() {
    assertEquals("UTC", System.getenv("TZ"), "run the tests with TZ=UTC (Surefire sets it)");
    assertEquals("UTC", System.getProperty("user.timezone"));
    assertEquals(0, TimeZone.getDefault().getOffset(0));
    assertEquals(0, ZoneId.systemDefault().getRules().getOffset(Instant.EPOCH).getTotalSeconds());
  }
}
