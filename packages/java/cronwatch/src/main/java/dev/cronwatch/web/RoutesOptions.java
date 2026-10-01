package dev.cronwatch.web;

import java.util.Objects;
import org.jspecify.annotations.Nullable;

/**
 * How {@link Routes} serve the dashboard: the SDK's {@code RoutesOptions}, with Java's three ways
 * for the token ({@link Builder#token}, {@link Builder#noToken}, or neither for {@code
 * CRONWATCH_TOKEN}). {@link #toString} says whether a token is set, never the token.
 */
public final class RoutesOptions {
  private final boolean tokenGiven;
  private final @Nullable String token;
  private final @Nullable String basePath;
  private final @Nullable String origin;
  private final boolean trustProxy;

  private RoutesOptions(Builder b) {
    this.tokenGiven = b.tokenGiven;
    this.token = b.token;
    this.basePath = b.basePath;
    this.origin = b.origin;
    this.trustProxy = b.trustProxy;
  }

  /** A builder with the defaults. */
  public static Builder builder() {
    return new Builder();
  }

  /**
   * The defaults: the token from {@code CRONWATCH_TOKEN}, mounted where an adapter finds it or at
   * {@code /cronwatch}, the request's own origin.
   */
  public static RoutesOptions defaults() {
    return builder().build();
  }

  boolean tokenGiven() {
    return tokenGiven;
  }

  @Nullable String token() {
    return token;
  }

  @Nullable String basePath() {
    return basePath;
  }

  @Nullable String origin() {
    return origin;
  }

  boolean trustProxy() {
    return trustProxy;
  }

  @Override
  public String toString() {
    return "RoutesOptions[token="
        + (!tokenGiven ? "CRONWATCH_TOKEN" : token == null ? "none" : "set")
        + ", basePath="
        + basePath
        + ", origin="
        + origin
        + ", trustProxy="
        + trustProxy
        + "]";
  }

  /** Builds {@link RoutesOptions}. Not safe for use from several threads at once. */
  public static final class Builder {
    private boolean tokenGiven;
    private @Nullable String token;
    private @Nullable String basePath;
    private @Nullable String origin;
    private boolean trustProxy;

    private Builder() {}

    /**
     * The token the dashboard asks for. Send it as {@code Authorization: Bearer <token>}, or open
     * the dashboard once with {@code ?token=<token>} and a cookie is set. Without it the token is
     * {@code CRONWATCH_TOKEN}; an empty token, or one of only whitespace, given here or in the
     * variable, counts as unset. With no token in development ({@code CRONWATCH_ENV} or {@code
     * APP_ENV} naming it), the routes make a random one and print a sign-in link to standard output
     * on their first request; with no token otherwise they answer 503. {@code /api/check} also
     * takes the client's cron secret as a bearer, so a platform cron can run checks without the
     * token.
     */
    public Builder token(String token) {
      this.tokenGiven = true;
      this.token = Objects.requireNonNull(token, "token");
      return this;
    }

    /**
     * Serves the dashboard to anyone, everywhere, for one behind the app's own auth (the SDK's
     * {@code token: null}).
     */
    public Builder noToken() {
      this.tokenGiven = true;
      this.token = null;
      return this;
    }

    /**
     * Where the dashboard is mounted ({@code ""} for the root), so its links resolve. Without it
     * the base is where an adapter finds the dashboard mounted, else {@code /cronwatch}.
     */
    public Builder basePath(String path) {
      this.basePath = Objects.requireNonNull(path, "path");
      return this;
    }

    /**
     * The public origin the dashboard is served from, such as {@code https://app.example.com}, for
     * an app behind a proxy whose requests carry an internal host or scheme. It stands in for the
     * request's own origin in the cross-site check on writes, the sign-in cookie's {@code Secure}
     * flag, the Referer the redirect back after a form follows, and the development sign-in line.
     * Anything that is not an http or https URL is refused when the routes are made. It takes
     * precedence over {@link #trustProxy}.
     */
    public Builder origin(String origin) {
      this.origin = Objects.requireNonNull(origin, "origin");
      return this;
    }

    /**
     * Takes the public origin from {@code X-Forwarded-Proto} and {@code X-Forwarded-Host} (the
     * first value of each, the request's own scheme or host for whichever is missing) when a
     * request carries either. Only for an app whose proxy sets or overwrites both headers: a client
     * can send them too.
     */
    public Builder trustProxy() {
      this.trustProxy = true;
      return this;
    }

    /** The options. */
    public RoutesOptions build() {
      return new RoutesOptions(this);
    }

    /** Says whether a token is set, never the token. */
    @Override
    public String toString() {
      return build().toString();
    }
  }
}
