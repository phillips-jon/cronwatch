package dev.cronwatch.internal.web;

import dev.cronwatch.json.JsObject;
import java.io.IOException;
import java.io.InputStream;
import java.io.UncheckedIOException;
import java.nio.charset.StandardCharsets;
import java.util.List;
import org.jspecify.annotations.Nullable;

/**
 * What makes the dashboard an installable web app ({@code routes/pwa.ts}): a manifest, icons, a
 * service worker, the script that registers it and a page to show offline. None of it says anything
 * about the jobs, so it is served without the token (a browser fetches the manifest and icons
 * without cookies in some flows). The files are the SDK's, byte for byte, resources in the jar:
 * {@code scripts/make-dashboard-icons.mjs} writes the icons and {@code
 * packages/ruby/test/web/golden.mjs} the style sheet and scripts, and both fail {@code npm run
 * check:conformance} when a copy here is stale.
 */
public final class Pwa {
  private Pwa() {}

  /** The paper behind the sheet, the app window's background. */
  static final String BACKGROUND_COLOR = "#f4f4f5";

  /** The sheet the header sits on, light. */
  static final String THEME_COLOR = "#ffffff";

  /** The sheet the header sits on, dark. */
  static final String THEME_COLOR_DARK = "#111113";

  private static final String CACHE_YEAR = "public, max-age=31536000, immutable";
  private static final String CACHE_REVALIDATE = "no-cache";

  /** The files, read from the jar once, when the routes are first used. */
  static final class Files {
    private Files() {}

    static final String STYLE_CSS = text("style.css");
    static final byte[] APP_JS = bytes("app.js");
    static final byte[] SW_JS = bytes("sw.js");
    static final byte[] ICON_SVG = bytes("icons/icon.svg");
    static final byte[] MASKABLE_SVG = bytes("icons/maskable.svg");
    static final byte[] ICON_192_PNG = bytes("icons/icon-192.png");
    static final byte[] ICON_512_PNG = bytes("icons/icon-512.png");
    static final byte[] MASKABLE_512_PNG = bytes("icons/maskable-512.png");
    static final byte[] APPLE_TOUCH_ICON_PNG = bytes("icons/apple-touch-icon.png");

    private static byte[] bytes(String name) {
      String path = "/dev/cronwatch/web/assets/" + name;
      try (InputStream in = Pwa.class.getResourceAsStream(path)) {
        if (in == null) {
          throw new IllegalStateException("the dashboard's " + path + " is missing from the jar");
        }
        return in.readAllBytes();
      } catch (IOException e) {
        throw new UncheckedIOException(e);
      }
    }

    private static String text(String name) {
      return new String(bytes(name), StandardCharsets.UTF_8);
    }
  }

  /** The pages' style sheet. */
  static String styleCss() {
    return Files.STYLE_CSS;
  }

  /** One file of the app shell. */
  public static final class Asset {
    private final String contentType;
    private final byte[] body;
    private final String cache;
    private final boolean worker;

    Asset(String contentType, byte[] body, String cache, boolean worker) {
      this.contentType = contentType;
      this.body = body;
      this.cache = cache;
      this.worker = worker;
    }

    /** Its type. */
    public String contentType() {
      return contentType;
    }

    /** A copy of its bytes. */
    public byte[] body() {
      return body.clone();
    }

    /** Its {@code cache-control}. */
    public String cache() {
      return cache;
    }

    /** Whether it is the service worker, which may control everything under the base. */
    public boolean worker() {
      return worker;
    }
  }

  /** The web app manifest for the dashboard mounted at {@code base} ({@code ""} at the root). */
  static String manifest(String base) {
    return new JsObject()
        .set("id", base + "/")
        .set("name", "CronWatch")
        .set("short_name", "CronWatch")
        .set(
            "description",
            "The scheduled jobs of this app: their health, their last day and their runs.")
        .set("start_url", base + "/")
        .set("scope", base + "/")
        .set("display", "standalone")
        .set("background_color", BACKGROUND_COLOR)
        .set("theme_color", THEME_COLOR)
        .set(
            "icons",
            List.of(
                icon(base, "icon.svg", "any", "image/svg+xml", "any"),
                icon(base, "maskable.svg", "any", "image/svg+xml", "maskable"),
                icon(base, "icon-192.png", "192x192", "image/png", "any"),
                icon(base, "icon-512.png", "512x512", "image/png", "any"),
                icon(base, "maskable-512.png", "512x512", "image/png", "maskable")))
        .toJson();
  }

  private static JsObject icon(
      String base, String name, String sizes, String type, String purpose) {
    return new JsObject()
        .set("src", base + "/icons/" + name)
        .set("sizes", sizes)
        .set("type", type)
        .set("purpose", purpose);
  }

  private static Asset icon(String type, byte[] body) {
    return new Asset(type, body, CACHE_YEAR, false);
  }

  /**
   * The app shell file at {@code path} (the path under the base), or null. The offline page is HTML
   * and is served by the routes themselves.
   */
  public static @Nullable Asset asset(String path, String base) {
    return switch (path) {
      case "/manifest.webmanifest" ->
          new Asset(
              "application/manifest+json",
              manifest(base).getBytes(StandardCharsets.UTF_8),
              CACHE_REVALIDATE,
              false);
      case "/app.js" ->
          new Asset("text/javascript; charset=utf-8", Files.APP_JS, CACHE_REVALIDATE, false);
      case "/sw.js" ->
          new Asset("text/javascript; charset=utf-8", Files.SW_JS, CACHE_REVALIDATE, true);
      case "/icons/icon.svg" -> icon("image/svg+xml", Files.ICON_SVG);
      case "/icons/maskable.svg" -> icon("image/svg+xml", Files.MASKABLE_SVG);
      case "/icons/icon-192.png" -> icon("image/png", Files.ICON_192_PNG);
      case "/icons/icon-512.png" -> icon("image/png", Files.ICON_512_PNG);
      case "/icons/maskable-512.png" -> icon("image/png", Files.MASKABLE_512_PNG);
      case "/icons/apple-touch-icon.png" -> icon("image/png", Files.APPLE_TOUCH_ICON_PNG);
      default -> null;
    };
  }
}
