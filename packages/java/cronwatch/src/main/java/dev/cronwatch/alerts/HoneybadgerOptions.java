package dev.cronwatch.alerts;

import dev.cronwatch.Alert;
import java.util.Objects;
import java.util.function.Function;
import org.jspecify.annotations.Nullable;

/** Configures {@link Honeybadger}. */
public final class HoneybadgerOptions {
  final String apiKey;
  final String environment;
  final String url;
  final boolean recovered;
  final @Nullable Function<Alert, @Nullable String> link;
  final @Nullable Transport transport;

  private HoneybadgerOptions(Builder b, String apiKey) {
    this.apiKey = apiKey;
    this.environment = b.environment;
    String endpoint = b.endpoint;
    int end = endpoint.length();
    while (end > 0 && endpoint.charAt(end - 1) == '/') {
      end--;
    }
    this.url = endpoint.substring(0, end) + "/v1/notices";
    this.recovered = b.recovered;
    this.link = b.link;
    this.transport = b.transport;
  }

  /** A builder with nothing set. */
  public static Builder builder() {
    return new Builder();
  }

  /** Names what is set, never the API key. */
  @Override
  public String toString() {
    return "HoneybadgerOptions[apiKey=set, environment="
        + environment
        + ", recovered="
        + recovered
        + "]";
  }

  /** Builds {@link HoneybadgerOptions}. */
  public static final class Builder extends ChannelBuilder<Builder> {
    private String apiKey = "";
    private String environment = "production";
    private String endpoint = "https://api.honeybadger.io";
    private boolean recovered;

    private Builder() {}

    @Override
    Builder self() {
      return this;
    }

    /** The project API key, from Project Settings. */
    public Builder apiKey(String apiKey) {
      this.apiKey = Objects.requireNonNull(apiKey, "apiKey");
      return this;
    }

    /** Default {@code production}. */
    public Builder environment(String environment) {
      this.environment = Objects.requireNonNull(environment, "environment");
      return this;
    }

    /** Another API host, {@code https://eu-api.honeybadger.io} say. */
    public Builder endpoint(String endpoint) {
      this.endpoint = Objects.requireNonNull(endpoint, "endpoint");
      return this;
    }

    /**
     * Also send recoveries. Default false: Honeybadger has no levels, so a recovery would read as
     * an error.
     */
    public Builder recovered(boolean recovered) {
      this.recovered = recovered;
      return this;
    }

    /**
     * The options.
     *
     * @throws dev.cronwatch.CronwatchException without an API key
     */
    public HoneybadgerOptions build() {
      // A pasted credential often carries a stray space or newline, which a header would refuse.
      String key = Shared.trimmed(apiKey);
      if (key.isEmpty()) {
        throw Shared.invalid("Honeybadger needs an apiKey");
      }
      return new HoneybadgerOptions(this, key);
    }

    /** Names what is set, never a value. */
    @Override
    public String toString() {
      return "HoneybadgerOptions.Builder";
    }
  }
}
