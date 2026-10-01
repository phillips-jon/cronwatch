package dev.cronwatch.web;

import java.util.Objects;
import org.jspecify.annotations.Nullable;

/**
 * How a {@link Handler} checks its requests: the SDK's {@code HandlerOptions}, with Java's three
 * ways for the secret ({@link Builder#secret}, {@link Builder#noSecret}, or neither for the
 * client's cron secret). {@link #toString} says whether a secret is set, never the secret.
 */
public final class HandlerOptions {
  private final boolean secretGiven;
  private final @Nullable String secret;

  private HandlerOptions(Builder b) {
    this.secretGiven = b.secretGiven;
    this.secret = b.secret;
  }

  /** A builder with the defaults. */
  public static Builder builder() {
    return new Builder();
  }

  /** The defaults: the client's cron secret ({@code CRON_SECRET}). */
  public static HandlerOptions defaults() {
    return builder().build();
  }

  boolean secretGiven() {
    return secretGiven;
  }

  @Nullable String secret() {
    return secret;
  }

  @Override
  public String toString() {
    return "HandlerOptions[secret="
        + (!secretGiven ? "the client's" : secret == null ? "none" : "set")
        + "]";
  }

  /** Builds {@link HandlerOptions}. Not safe for use from several threads at once. */
  public static final class Builder {
    private boolean secretGiven;
    private @Nullable String secret;

    private Builder() {}

    /**
     * The secret the handler's requests must carry, as {@code Authorization: Bearer <secret>}, in
     * place of the client's cron secret. An empty secret, or one of only whitespace, counts as
     * unset and falls back to the client's.
     */
    public Builder secret(String secret) {
      this.secretGiven = true;
      this.secret = Objects.requireNonNull(secret, "secret");
      return this;
    }

    /**
     * Lets anyone run the job through the handler (the SDK's {@code secret: null}), for one behind
     * the app's own auth, or a function only its platform can invoke.
     */
    public Builder noSecret() {
      this.secretGiven = true;
      this.secret = null;
      return this;
    }

    /** The options. */
    public HandlerOptions build() {
      return new HandlerOptions(this);
    }

    /** Says whether a secret is set, never the secret. */
    @Override
    public String toString() {
      return build().toString();
    }
  }
}
