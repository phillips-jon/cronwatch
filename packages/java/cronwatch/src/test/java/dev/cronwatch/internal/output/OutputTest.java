package dev.cronwatch.internal.output;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertTrue;

import dev.cronwatch.json.JsObject;
import java.io.IOException;
import org.junit.jupiter.api.Test;

/** Error text as the Java port writes a throwable, and the cap and NUL rules. */
class OutputTest {
  private static final class ReportException extends IOException {
    private static final long serialVersionUID = 1L;

    ReportException(String message) {
      super(message);
    }
  }

  private static StackTraceElement[] frames(int n) {
    StackTraceElement[] out = new StackTraceElement[n];
    for (int k = 0; k < n; k++) {
      out[k] = new StackTraceElement("com.example.Reports", "build" + k, "Reports.java", 40 + k);
    }
    return out;
  }

  @Test
  void aCheckedExceptionIsItsSimpleNameMessageAndFiveFrames() {
    ReportException e = new ReportException("disk full");
    e.setStackTrace(frames(7));
    assertEquals(
        """
        ReportException: disk full
            at com.example.Reports.build0 (Reports.java:40)
            at com.example.Reports.build1 (Reports.java:41)
            at com.example.Reports.build2 (Reports.java:42)
            at com.example.Reports.build3 (Reports.java:43)
            at com.example.Reports.build4 (Reports.java:44)""",
        Output.errorMessage(e));
  }

  @Test
  void aNullMessageIsEmptyAsNewErrorsIs() {
    IllegalStateException e = new IllegalStateException();
    e.setStackTrace(new StackTraceElement[0]);
    // new Error() is written "Error: ", its message empty.
    assertEquals("IllegalStateException: ", Output.errorMessage(e));
  }

  @Test
  void anAnonymousClassIsItsBinaryName() {
    RuntimeException e =
        new RuntimeException("boom") {
          private static final long serialVersionUID = 1L;
        };
    e.setStackTrace(new StackTraceElement[0]);
    assertEquals(e.getClass().getName() + ": boom", Output.errorMessage(e));
    assertTrue(e.getClass().getName().startsWith(OutputTest.class.getName() + "$"));
  }

  @Test
  void causesAreNotWritten() {
    RuntimeException e = new RuntimeException("outer", new IOException("inner"));
    e.setStackTrace(new StackTraceElement[0]);
    assertEquals("RuntimeException: outer", Output.errorMessage(e));
  }

  @Test
  void framesAsAJavaScriptStackReadsThem() {
    assertEquals(
        "a.B.c (Native Method)", Output.frame(new StackTraceElement("a.B", "c", "B.java", -2)));
    assertEquals(
        "a.B.c (Unknown Source)", Output.frame(new StackTraceElement("a.B", "c", null, -1)));
    assertEquals("a.B.c (B.java)", Output.frame(new StackTraceElement("a.B", "c", "B.java", -1)));
  }

  @Test
  void aValueThatIsNotAnErrorIsItselfOrItsJson() {
    assertEquals("plain", Output.errorMessage((Object) "plain"));
    assertEquals("{\"code\":5}", Output.errorMessage(new JsObject().set("code", 5)));
    assertEquals("[1,\"two\",null]", Output.errorMessage(java.util.Arrays.asList(1, "two", null)));
    assertEquals("null", Output.errorMessage((Object) null));
    // Something JSON cannot write is written as its toString, as String(error) would be.
    Object thing =
        new Object() {
          @Override
          public String toString() {
            return "a thing";
          }
        };
    assertEquals("a thing", Output.errorMessage(thing));
  }

  @Test
  void theCapKeepsTheTailAndNulsGoFirst() {
    assertEquals("ab", Output.cap("a\0b\0"));
    String longText = "x".repeat(Output.OUTPUT_CAP) + "tail";
    String capped = Output.cap(longText);
    assertEquals("[earlier output trimmed]\n", capped.substring(0, 25));
    assertTrue(capped.endsWith("tail"));
    assertEquals(25 + Output.OUTPUT_CAP, capped.length());
    // A cut through a pair keeps the lone half, as JavaScript's slice does.
    String pair = "😀".repeat(Output.OUTPUT_CAP) + "a";
    assertEquals('\ude00', Output.cap(pair).charAt(25));
  }
}
