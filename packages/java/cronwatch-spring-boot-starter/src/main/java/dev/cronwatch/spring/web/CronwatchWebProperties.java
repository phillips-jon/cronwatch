package dev.cronwatch.spring.web;

import org.jspecify.annotations.Nullable;
import org.springframework.boot.context.properties.ConfigurationProperties;

/**
 * The dashboard's settings, {@code cronwatch.web.*}. Each is optional.
 *
 * <pre>
 * cronwatch.web.path=/cronwatch        # where the dashboard is, within the app's context
 * cronwatch.web.token=${CRONWATCH_TOKEN}
 * cronwatch.web.origin=https://app.example.com
 * cronwatch.web.trust-proxy=false
 * cronwatch.web.open=false             # true serves it with no token, behind the app's own auth
 * cronwatch.web.order=-110             # ahead of Spring Security's filter chain (-100); -90 when open
 * </pre>
 */
@ConfigurationProperties(prefix = "cronwatch.web")
public class CronwatchWebProperties {
  /** Ahead of Spring Security's filter chain, whose order is -100. */
  public static final int DEFAULT_ORDER = -110;

  /**
   * Behind Spring Security's filter chain: the order of a dashboard served {@link #isOpen() open},
   * which has no token of its own and is left to the app's auth.
   */
  public static final int OPEN_ORDER = -90;

  private boolean enabled = true;
  private String path = "/cronwatch";
  private @Nullable String token;
  private boolean open;
  private @Nullable String origin;
  private boolean trustProxy;
  private @Nullable Integer order;

  /** Made by Spring. */
  public CronwatchWebProperties() {}

  /** Whether the dashboard is served. */
  public boolean isEnabled() {
    return enabled;
  }

  /** Sets {@link #isEnabled()}. */
  public void setEnabled(boolean enabled) {
    this.enabled = enabled;
  }

  /** Where the dashboard is, within the app's context path. */
  public String getPath() {
    return path;
  }

  /** Sets {@link #getPath()}. */
  public void setPath(String path) {
    this.path = path;
  }

  /** The token the dashboard asks for. Default {@code $CRONWATCH_TOKEN}. */
  public @Nullable String getToken() {
    return token;
  }

  /** Sets {@link #getToken()}. */
  public void setToken(@Nullable String token) {
    this.token = token;
  }

  /** Whether the dashboard is served to anyone, behind the app's own auth. */
  public boolean isOpen() {
    return open;
  }

  /** Sets {@link #isOpen()}. */
  public void setOpen(boolean open) {
    this.open = open;
  }

  /** The public origin the dashboard is served from, for an app behind a proxy. */
  public @Nullable String getOrigin() {
    return origin;
  }

  /** Sets {@link #getOrigin()}. */
  public void setOrigin(@Nullable String origin) {
    this.origin = origin;
  }

  /** Whether the public origin is taken from the proxy's forwarded headers. */
  public boolean isTrustProxy() {
    return trustProxy;
  }

  /** Sets {@link #isTrustProxy()}. */
  public void setTrustProxy(boolean trustProxy) {
    this.trustProxy = trustProxy;
  }

  /**
   * The filter's order: the one set, else ahead of Spring Security's chain ({@link #DEFAULT_ORDER})
   * for a dashboard with a token, and behind it ({@link #OPEN_ORDER}) for one served open, so the
   * app's auth runs before it.
   */
  public int getOrder() {
    return order != null ? order : open ? OPEN_ORDER : DEFAULT_ORDER;
  }

  /** Sets {@link #getOrder()}. */
  public void setOrder(int order) {
    this.order = order;
  }

  /** Names what is set, never the token. */
  @Override
  public String toString() {
    return "CronwatchWebProperties[path="
        + path
        + ", token="
        + (open ? "none" : token == null ? "CRONWATCH_TOKEN" : "set")
        + ", origin="
        + origin
        + ", trustProxy="
        + trustProxy
        + ", order="
        + getOrder()
        + "]";
  }
}
