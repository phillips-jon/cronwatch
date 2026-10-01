package dev.cronwatch;

import static org.junit.jupiter.api.Assertions.assertEquals;

import java.util.HashMap;
import java.util.Map;
import org.jspecify.annotations.Nullable;
import org.junit.jupiter.api.Test;

/**
 * The environment as every port reads it: {@code CRONWATCH_ENV}, then {@code APP_ENV}, then the
 * port's own (here the Spring starter's profiles, given as the fallback), the first not blank once
 * trimmed, lowercased, with the aliases. The SDK's table ({@code packages/sdk/test/env.test.ts}).
 */
class EnvTest {
  private static String read(
      @Nullable String cronwatchEnv, @Nullable String appEnv, @Nullable String own) {
    Map<String, String> vars = new HashMap<>();
    if (cronwatchEnv != null) {
      vars.put("CRONWATCH_ENV", cronwatchEnv);
    }
    if (appEnv != null) {
      vars.put("APP_ENV", appEnv);
    }
    return Env.environment(vars::get, own);
  }

  @Test
  void theSdksTable() {
    assertEquals("", read(null, null, null));
    assertEquals("development", read(null, null, "development"));
    assertEquals("development", read(null, null, "test"));
    assertEquals("production", read(null, null, "production"));
    assertEquals("development", read(null, "local", "production"));
    assertEquals("production", read("production", "dev", "development"));
    assertEquals("staging", read("staging", null, "development"));
    assertEquals("production", read("  PROD ", null, null));
    assertEquals("development", read(null, "Testing", null));
    assertEquals("development", read(null, "DEV", null));
    assertEquals("production", read("", "   ", "production"));
    assertEquals("", read(" \t", null, null));
  }

  @Test
  void spacesAreTrimmedAsJavaScriptTrimsThem() {
    // A no-break space and a byte order mark are spaces to JavaScript's trim, not to strip().
    assertEquals("production", read(" prod﻿", null, null));
  }
}
