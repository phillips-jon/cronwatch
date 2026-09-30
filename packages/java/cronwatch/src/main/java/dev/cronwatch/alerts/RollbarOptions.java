package dev.cronwatch.alerts;

import dev.cronwatch.Alert;
import java.util.Objects;
import java.util.function.Function;
import org.jspecify.annotations.Nullable;

/** Configures {@link Rollbar}. */
public final class RollbarOptions {
  final String accessToken;
  final String environment;
  final boolean recovered;
  final @Nullable Function<Alert, @Nullable String> link;
  final @Nullable Transport transport;

  private RollbarOptions(Builder b, String accessToken) {
    this.accessToken = accessToken;
    this.environment = b.environment;
    this.recovered = b.recovered;
    this.link = b.link;
    this.transport = b.transport;
  }

  /** A builder with nothing set. */
  public static Builder builder() {
    return new Builder();
  }

  /** Names what is set, never the access token. */
  @Override
  public String toString() {
    return "RollbarOptions[accessToken=set, environment="
        + environment
        + ", recovered="
        + recovered
        + "]";
  }

  /** Builds {@link RollbarOptions}. */
  public static final class Builder extends ChannelBuilder<Builder> {
    private String accessToken = "";
    private String environment = "production";
    private boolean recovered = true;

    private Builder() {}

    @Override
    Builder self() {
      return this;
    }

    /** A project access token with the {@code post_server_item} scope. */
    public Builder accessToken(String accessToken) {
      this.accessToken = Objects.requireNonNull(accessToken, "accessToken");
      return this;
    }

    /** Default {@code production}. */
    public Builder environment(String environment) {
      this.environment = Objects.requireNonNull(environment, "environment");
      return this;
    }

    /** Also send recoveries, as info items. Default true. */
    public Builder recovered(boolean recovered) {
      this.recovered = recovered;
      return this;
    }

    /**
     * The options.
     *
     * @throws dev.cronwatch.CronwatchException without an access token
     */
    public RollbarOptions build() {
      // A pasted credential often carries a stray space or newline, which a header would refuse.
      String token = Shared.trimmed(accessToken);
      if (token.isEmpty()) {
        throw Shared.invalid("Rollbar needs an accessToken");
      }
      return new RollbarOptions(this, token);
    }

    /** Names what is set, never a value. */
    @Override
    public String toString() {
      return "RollbarOptions.Builder";
    }
  }
}
