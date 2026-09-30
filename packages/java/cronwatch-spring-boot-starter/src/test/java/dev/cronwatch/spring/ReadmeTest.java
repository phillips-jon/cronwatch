package dev.cronwatch.spring;

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
 * The integrations' examples in packages/java/README.md ({@code ```java spring}, {@code ```java
 * quartz} and {@code ```java jobrunr} blocks) compile against this build, each as the body of a
 * method of its own; the core's own test compiles the plain {@code ```java} blocks.
 */
class ReadmeTest {
  private static final String IMPORTS =
      """
      import dev.cronwatch.*;
      import dev.cronwatch.jobrunr.*;
      import dev.cronwatch.quartz.*;
      import dev.cronwatch.spring.*;
      """;

  @TempDir Path dir;

  @Test
  void everyIntegrationExampleCompiles() throws IOException, InterruptedException {
    String repo = System.getProperty("cronwatch.repo", "../../..");
    String readme =
        Files.readString(Path.of(repo, "packages/java/README.md"), StandardCharsets.UTF_8);
    Matcher m =
        Pattern.compile("```java (spring|quartz|jobrunr)\n(.*?)```", Pattern.DOTALL)
            .matcher(readme);
    List<String> kinds = new ArrayList<>();
    List<Path> sources = new ArrayList<>();
    while (m.find()) {
      kinds.add(m.group(1));
      String name = "ReadmeExample" + sources.size();
      Path file = dir.resolve(name + ".java");
      Files.writeString(
          file,
          IMPORTS
              + "class "
              + name
              + " {\n  static void example() throws Exception {\n"
              + m.group(2)
              + "\n  }\n}\n",
          StandardCharsets.UTF_8);
      sources.add(file);
    }
    assertTrue(
        kinds.containsAll(List.of("spring", "quartz", "jobrunr")),
        "README integration examples found: " + kinds);
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
