package dev.cronwatch.alerts;

import dev.cronwatch.Alert;
import java.util.Objects;
import java.util.function.Function;
import java.util.function.LongSupplier;
import org.jspecify.annotations.Nullable;

/** Configures {@link Bugsnag}. */
public final class BugsnagOptions {
  final String apiKey;
  final String releaseStage;
  final String endpoint;
  final boolean recovered;
  final LongSupplier now;
  final @Nullable Function<Alert, @Nullable String> link;
  final @Nullable Transport transport;

  private BugsnagOptions(Builder b, String apiKey) {
    this.apiKey = apiKey;
    this.releaseStage = b.releaseStage;
    this.endpoint = b.endpoint;
    this.recovered = b.recovered;
    this.now = b.now;
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
    return "BugsnagOptions[apiKey=set, releaseStage="
        + releaseStage
        + ", recovered="
        + recovered
        + "]";
  }

  /** Builds {@link BugsnagOptions}. */
  public static final class Builder extends ChannelBuilder<Builder> {
    private String apiKey = "";
    private String releaseStage = "production";
    private String endpoint = "https://notify.bugsnag.com/";
    private boolean recovered;
    private LongSupplier now = System::currentTimeMillis;

    private Builder() {}

    @Override
    Builder self() {
      return this;
    }

    /** The project's notifier API key. */
    public Builder apiKey(String apiKey) {
      this.apiKey = Objects.requireNonNull(apiKey, "apiKey");
      return this;
    }

    /** Default {@code production}. */
    public Builder releaseStage(String releaseStage) {
      this.releaseStage = Objects.requireNonNull(releaseStage, "releaseStage");
      return this;
    }

    /**
     * Another notify endpoint, for on-premise installs. Default {@code
     * https://notify.bugsnag.com/}.
     */
    public Builder endpoint(String endpoint) {
      this.endpoint = Objects.requireNonNull(endpoint, "endpoint");
      return this;
    }

    /**
     * Also send recoveries, as info events. Default false, since each one is an event on an error.
     */
    public Builder recovered(boolean recovered) {
      this.recovered = recovered;
      return this;
    }

    /** The clock for the {@code Bugsnag-Sent-At} header, epoch milliseconds. For tests. */
    public Builder now(LongSupplier now) {
      this.now = Objects.requireNonNull(now, "now");
      return this;
    }

    /**
     * The options.
     *
     * @throws dev.cronwatch.CronwatchException without an API key
     */
    public BugsnagOptions build() {
      // A pasted credential often carries a stray space or newline, which a header would refuse.
      String key = Shared.trimmed(apiKey);
      if (key.isEmpty()) {
        throw Shared.invalid("Bugsnag needs an apiKey");
      }
      return new BugsnagOptions(this, key);
    }

    /** Names what is set, never a value. */
    @Override
    public String toString() {
      return "BugsnagOptions.Builder";
    }
  }
}
