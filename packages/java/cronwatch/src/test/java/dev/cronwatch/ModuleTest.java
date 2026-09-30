package dev.cronwatch;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertTrue;

import java.lang.module.Configuration;
import java.lang.module.ModuleDescriptor;
import java.lang.module.ModuleFinder;
import java.lang.reflect.Method;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.List;
import java.util.Set;
import java.util.TreeSet;
import org.junit.jupiter.api.Test;

/**
 * The core as a named module: it exports its API packages and none of {@code internal}, requires
 * nothing beyond the JDK but statically, and resolves and runs as a module with none of its
 * optional libraries present. The tests themselves run on the class path, as most apps do.
 */
class ModuleTest {
  private static final Path CLASSES = Path.of("target/classes");

  private static ModuleDescriptor descriptor() {
    assertTrue(Files.isRegularFile(CLASSES.resolve("module-info.class")), "compiled module-info");
    return ModuleFinder.of(CLASSES).find("dev.cronwatch").orElseThrow().descriptor();
  }

  @Test
  void theApiIsExportedAndTheInternalsAreNot() {
    Set<String> exported = new TreeSet<>();
    for (ModuleDescriptor.Exports e : descriptor().exports()) {
      assertTrue(e.targets().isEmpty(), "qualified export " + e);
      exported.add(e.source());
    }
    assertEquals(
        Set.of(
            "dev.cronwatch",
            "dev.cronwatch.bridge",
            "dev.cronwatch.cli",
            "dev.cronwatch.jdbc",
            "dev.cronwatch.json",
            "dev.cronwatch.store",
            "dev.cronwatch.storetest"),
        exported);
  }

  @Test
  void everythingBeyondTheJdkIsRequiredStatically() {
    for (ModuleDescriptor.Requires r : descriptor().requires()) {
      boolean jdk = r.name().startsWith("java.") || r.name().startsWith("jdk.");
      assertTrue(
          jdk || r.modifiers().contains(ModuleDescriptor.Requires.Modifier.STATIC),
          "a module that is not the JDK's is required at run time: " + r);
      assertTrue(
          r.name().equals("java.base")
              || r.modifiers().contains(ModuleDescriptor.Requires.Modifier.STATIC),
          "required at run time: " + r);
    }
  }

  @Test
  void theModuleRunsWithNoneOfItsOptionalLibraries() throws Exception {
    Configuration cf =
        ModuleLayer.boot()
            .configuration()
            .resolve(ModuleFinder.of(CLASSES), ModuleFinder.of(), Set.of("dev.cronwatch"));
    ModuleLayer layer =
        ModuleLayer.boot().defineModulesWithOneLoader(cf, ClassLoader.getPlatformClassLoader());
    Class<?> cronwatch = layer.findLoader("dev.cronwatch").loadClass("dev.cronwatch.Cronwatch");
    assertEquals("dev.cronwatch", cronwatch.getModule().getName());
    Object builder = cronwatch.getMethod("builder").invoke(null);
    Method noHook = builder.getClass().getMethod("noShutdownHook");
    Method alerts = builder.getClass().getMethod("alerts", List.class);
    alerts.invoke(noHook.invoke(builder), List.of());
    try (AutoCloseable cw = (AutoCloseable) builder.getClass().getMethod("build").invoke(builder)) {
      Object job = cronwatch.getMethod("job", String.class).invoke(cw, "modular");
      assertEquals("modular", job.getClass().getMethod("name").invoke(job));
    }
  }
}
