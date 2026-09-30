package dev.cronwatch;

import static org.junit.jupiter.api.Assertions.assertTrue;

import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.List;
import java.util.concurrent.TimeUnit;
import java.util.regex.Matcher;
import java.util.regex.Pattern;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;

/**
 * Every Java example in packages/java/README.md compiles against this build, each as the body of a
 * method of its own, so the README fails the build when one stops compiling (the Rust port's doc
 * tests, the Elixir port's README test).
 */
class ReadmeTest {
  private static final String IMPORTS =
      """
      import dev.cronwatch.*;
      import dev.cronwatch.alerts.*;
      import dev.cronwatch.jdbc.SqlStore;
      import dev.cronwatch.pgcron.*;
      import dev.cronwatch.triage.*;
      import dev.cronwatch.store.MemoryStore;
      import java.nio.file.Files;
      import java.nio.file.Path;
      import java.time.Duration;
      """;

  @TempDir Path dir;

  @Test
  void everyExampleCompiles() throws IOException, InterruptedException {
    String readme =
        Files.readString(
            Fixtures.repo().resolve("packages/java/README.md"), StandardCharsets.UTF_8);
    Matcher m = Pattern.compile("```java\n(.*?)```", Pattern.DOTALL).matcher(readme);
    List<Path> sources = new ArrayList<>();
    while (m.find()) {
      String name = "ReadmeExample" + sources.size();
      Path file = dir.resolve(name + ".java");
      Files.writeString(
          file,
          IMPORTS
              + "class "
              + name
              + " {\n  static void example() throws Exception {\n"
              + m.group(1)
              + "\n  }\n}\n",
          StandardCharsets.UTF_8);
      sources.add(file);
    }
    assertTrue(sources.size() >= 4, "README examples found: " + sources.size());
    // The JDK's own javac, as a process: the tests' module does not read java.compiler.
    List<String> command =
        new ArrayList<>(
            List.of(
                Path.of(System.getProperty("java.home"), "bin", "javac").toString(),
                "-classpath",
                System.getProperty("java.class.path"),
                "-d",
                dir.resolve("classes").toString(),
                "-proc:none",
                "-Xlint:none"));
    for (Path source : sources) {
      command.add(source.toString());
    }
    Process javac = new ProcessBuilder(command).redirectErrorStream(true).start();
    String out = new String(javac.getInputStream().readAllBytes(), StandardCharsets.UTF_8);
    assertTrue(javac.waitFor(120, TimeUnit.SECONDS), "javac ran on");
    assertTrue(javac.exitValue() == 0, "the README's examples do not compile:\n" + out);
  }
}
