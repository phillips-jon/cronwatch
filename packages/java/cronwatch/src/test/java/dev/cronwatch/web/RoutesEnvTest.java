package dev.cronwatch.web;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertTrue;

import java.nio.charset.StandardCharsets;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.List;
import java.util.Map;
import java.util.concurrent.TimeUnit;
import org.junit.jupiter.api.Test;

/**
 * What depends on the environment: the dashboard locked without a token outside development, the
 * development token and its sign-in line, and a job's handler with no secret. Each case runs in a
 * child JVM ({@link EnvChild}) with only the variables it names, since a JVM cannot change its own
 * environment, and the parent reads what it printed.
 */
class RoutesEnvTest {
  private static final String INTRO =
      "[cronwatch] CRONWATCH_TOKEN is not set, so this development server made a token for the"
          + " dashboard. Sign in: ";
  private static final String HOSTLESS =
      " on this server (the first request's host is not local, so the link leaves it out)";

  /** Runs {@code name} in a child JVM with only these of CronWatch's variables, and its output. */
  private static String child(String name, Map<String, String> vars) throws Exception {
    String java = Path.of(System.getProperty("java.home"), "bin", "java").toString();
    ProcessBuilder pb =
        new ProcessBuilder(
                java,
                "-Duser.timezone=UTC",
                "-cp",
                System.getProperty("java.class.path"),
                EnvChild.class.getName(),
                name)
            .redirectErrorStream(true);
    for (String v : List.of("CRONWATCH_ENV", "APP_ENV", "CRONWATCH_TOKEN", "CRON_SECRET")) {
      pb.environment().remove(v);
    }
    pb.environment().putAll(vars);
    Process p = pb.start();
    p.getOutputStream().close();
    // Windows ends the child's lines with \r\n; read them as the others.
    String out =
        new String(p.getInputStream().readAllBytes(), StandardCharsets.UTF_8).replace("\r\n", "\n");
    assertTrue(p.waitFor(120, TimeUnit.SECONDS), name + " did not end");
    assertEquals(0, p.exitValue(), name + " failed:\n" + out);
    assertTrue(out.contains("CHILD OK"), name + " did not run:\n" + out);
    return out;
  }

  private static List<String> announced(String out) {
    List<String> lines = new ArrayList<>();
    for (String l : out.split("\n", -1)) {
      int i = l.indexOf("[cronwatch]");
      if (i >= 0) {
        lines.add(l.substring(i).strip());
      }
    }
    return lines;
  }

  @Test
  void routesAreLockedWithoutATokenOutsideDevelopment() throws Exception {
    for (String env : List.of("", "production", "staging", "prod")) {
      child("locked", Map.of("CRONWATCH_ENV", env));
    }
  }

  @Test
  void aDevelopmentTokenIsPrintedOnceAndRequired() throws Exception {
    for (String var : List.of("CRONWATCH_ENV", "APP_ENV")) {
      String out = child("developmentToken", Map.of(var, "test"));
      List<String> lines = announced(out);
      assertEquals(2, lines.size(), var + ": " + out);
      assertTrue(lines.get(0).startsWith(INTRO), lines.get(0));
      String first = lines.get(0).substring(INTRO.length());
      String prefix = "http://localhost:3000/cronwatch/?token=";
      assertTrue(first.startsWith(prefix), "a loopback link: " + first);
      String token = first.substring(prefix.length());
      assertEquals(43, token.length(), "base64url of 32 bytes: " + token);
      assertTrue(token.matches("[A-Za-z0-9_-]+"), token);
      assertTrue(out.contains("\nTOKEN " + token + "\n"), "Routes.token is the one printed");
      String second = lines.get(1).substring(INTRO.length());
      assertTrue(second.startsWith("/?token="), "a root mount's line: " + second);
      assertTrue(second.endsWith(HOSTLESS), second);
      assertFalse(second.contains(token), "each routes value makes its own token");
    }
  }

  @Test
  void anEmptyTokenIsUnsetAndNoTokenOpens() throws Exception {
    child("emptyToken", Map.of("CRONWATCH_ENV", "production"));
    String out = child("openInDevelopment", Map.of("CRONWATCH_ENV", "development"));
    assertEquals(List.of(), announced(out), "no token made: " + out);
    out =
        child(
            "configuredInDevelopment",
            Map.of("CRONWATCH_ENV", "development", "CRONWATCH_TOKEN", "envtok"));
    assertEquals(List.of(), announced(out), "nothing printed: " + out);
  }

  @Test
  void theSignInLineShowsTheHostOnlyWhenConfiguredOrLoopback() throws Exception {
    String out = child("signInLines", Map.of("CRONWATCH_ENV", "development"));
    String[][] expected = {
      {"https://app.example.com/cronwatch", ""},
      {"https://app.example.com/cronwatch", ""},
      {"http://localhost:3000/cronwatch", ""},
      {"http://app.localhost:3000/cronwatch", ""},
      {"http://127.0.0.1:3000/cronwatch", ""},
      {"http://127.8.9.10/cronwatch", ""},
      {"http://[::1]:3000/cronwatch", ""},
      {"http://localhost:5173/cronwatch", ""},
      {"/cronwatch", HOSTLESS},
      {"/cronwatch", HOSTLESS},
      {"/cronwatch", HOSTLESS},
      {"/cronwatch", HOSTLESS},
      {"/cronwatch", HOSTLESS},
      {"", HOSTLESS},
      {"/cronwatch", HOSTLESS},
      {"/cronwatch", HOSTLESS},
    };
    List<String> lines = announced(out);
    assertEquals(expected.length, lines.size(), out);
    for (int i = 0; i < expected.length; i++) {
      String line = lines.get(i);
      String rest = line.substring(line.indexOf("token=") + 6);
      int space = rest.indexOf(' ');
      String token = space < 0 ? rest : rest.substring(0, space);
      assertEquals(43, token.length(), line);
      assertEquals(INTRO + expected[i][0] + "/?token=" + token + expected[i][1], line);
    }
  }

  @Test
  void aHandlerWithoutASecretFailsClosedOutsideDevelopment() throws Exception {
    child("handlerClosed", Map.of());
    child("handlerDevelopment", Map.of("APP_ENV", "local"));
  }

  @Test
  void theStartersFallbackNamesTheEnvironmentWhenNoVariableDoes() throws Exception {
    child("profileFallback", Map.of());
  }
}
