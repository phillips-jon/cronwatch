package dev.cronwatch;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertNotNull;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;

import dev.cronwatch.Support.Made;
import dev.cronwatch.internal.output.Output;
import java.util.stream.Collectors;
import java.util.stream.IntStream;
import org.junit.jupiter.api.Test;

/**
 * The SDK's {@code redaction.test.ts} cases for the cut: output and errors are redacted before the
 * 16 KB cap, so the cut cannot keep the rest of a secret whose label it cut off.
 */
class RedactionTest {
  private static final String TRIMMED = "[earlier output trimmed]\n";

  private static String output(Made m, String id) {
    Run run = m.cw().getRun(id);
    assertNotNull(run);
    String out = run.output();
    assertNotNull(out);
    return out;
  }

  @Test
  void aSecretSplitByThe16KbCutIsRedactedWhole() {
    String pem =
        "-----BEGIN PRIVATE KEY-----\n"
            + IntStream.range(0, 25)
                .mapToObj(i -> "QUJD".repeat(15) + String.format("%04d", i))
                .collect(Collectors.joining("\n"))
            + "\n-----END PRIVATE KEY-----";
    String bearer = "Authorization: Bearer opaqueTOKENvalue1234567890";
    Made m = Support.make();
    // The cut lands inside the key's body, and in a second run just after "Bear".
    m.cw()
        .run(
            "pem",
            j -> {
              j.log("x".repeat(Output.OUTPUT_CAP));
              j.log(pem.substring(0, 900));
              j.log(pem.substring(900));
              j.log("done");
            });
    String pemOutput = m.cw().runs("pem", 1).get(0).output();
    assertNotNull(pemOutput);
    assertFalse(pemOutput.contains("QUJD"), pemOutput.substring(pemOutput.length() - 200));
    assertTrue(pemOutput.endsWith("[redacted]\ndone"));
    String tail = "y".repeat(Output.OUTPUT_CAP - 30);
    m.cw().job("bearer").call(j -> bearer + "\n" + tail);
    String bearerOutput = m.cw().runs("bearer", 1).get(0).output();
    assertNotNull(bearerOutput);
    assertFalse(bearerOutput.contains("opaqueTOKEN"));
    assertTrue(bearerOutput.length() <= Output.OUTPUT_CAP + TRIMMED.length());

    // Errors, recorded runs, and flushed lines the same way.
    assertThrows(
        IllegalStateException.class,
        () ->
            m.cw()
                .run(
                    "thrown",
                    j -> {
                      throw new IllegalStateException(
                          "e".repeat(Output.OUTPUT_CAP)
                              + " "
                              + bearer
                              + " "
                              + "z".repeat(Output.OUTPUT_CAP - 40));
                    }));
    String error = m.cw().runs("thrown", 1).get(0).error();
    assertNotNull(error);
    assertFalse(error.contains("opaqueTOKEN"));
    m.cw().job("imported");
    m.cw()
        .recordRun(
            new Run(
                "i1",
                "imported",
                RunStatus.OK,
                1,
                2L,
                1L,
                null,
                bearer + "\n" + tail,
                Metrics.empty(),
                "source"));
    assertFalse(output(m, "i1").contains("opaqueTOKEN"));
    RunHandle handle = m.cw().job("flushed").start();
    handle.log(bearer);
    handle.log(tail);
    handle.flush();
    assertFalse(output(m, handle.id()).contains("opaqueTOKEN"));
    handle.finish();
    assertFalse(output(m, handle.id()).contains("opaqueTOKEN"));
  }

  @Test
  void textPastTheRedactionWindowNeverKeepsWhatCameRightAfterItsCut() {
    // The window starts part way into a key's body, whose header is before it: the body's rest
    // cannot be told from text, so it is never kept.
    String body = "QUJD".repeat(4000);
    String text =
        "-----BEGIN PRIVATE KEY-----\n"
            + body
            + "\n"
            + "k".repeat(Output.OUTPUT_CAP + Output.REDACT_EDGE - 8000);
    String kept = Output.redactAndCap(text, Output::redactSecrets);
    assertTrue(kept.startsWith(TRIMMED));
    assertEquals(TRIMMED.length() + Output.OUTPUT_CAP, kept.length());
    assertFalse(kept.contains("QUJD"));

    // A redaction that shrinks the window cannot pull its first units into view.
    String shrunk =
        Output.redactAndCap(
            "QUJD".repeat(100) + "s".repeat(Output.OUTPUT_CAP + Output.REDACT_EDGE),
            t -> t.replace("s".repeat(100), ""));
    assertEquals(TRIMMED, shrunk);

    // Short text is redacted whole, then capped as before; NULs go either side of redact.
    assertEquals("password=[redacted]", Output.redactAndCap("password=x", Output::redactSecrets));
    assertEquals("ab", Output.redactAndCap("a\u0000b", t -> t + "\u0000"));
    assertEquals(
        TRIMMED + "x".repeat(Output.OUTPUT_CAP),
        Output.redactAndCap("x".repeat(Output.OUTPUT_CAP + 5), Output::redactSecrets));
  }
}
