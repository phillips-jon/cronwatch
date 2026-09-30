package dev.cronwatch.alerts;

import dev.cronwatch.Alert;
import java.util.Objects;
import java.util.function.Function;
import org.jspecify.annotations.Nullable;

/** Configures {@link NewRelic}. */
public final class NewRelicOptions {
  final String apiKey;
  final String url;
  final String eventType;
  final @Nullable Function<Alert, @Nullable String> link;
  final @Nullable Transport transport;

  private NewRelicOptions(Builder b, String apiKey) {
    this.apiKey = apiKey;
    String host =
        b.region.equals("eu")
            ? "https://insights-collector.eu01.nr-data.net"
            : "https://insights-collector.newrelic.com";
    this.url = host + "/v1/accounts/" + b.accountId + "/events";
    this.eventType = b.eventType;
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
    return "NewRelicOptions[apiKey=set, eventType=" + eventType + "]";
  }

  /** Builds {@link NewRelicOptions}. */
  public static final class Builder extends ChannelBuilder<Builder> {
    private String apiKey = "";
    private String accountId = "";
    private String region = "us";
    private String eventType = "CronWatchAlert";

    private Builder() {}

    @Override
    Builder self() {
      return this;
    }

    /** A license key (INGEST - LICENSE). */
    public Builder apiKey(String apiKey) {
      this.apiKey = Objects.requireNonNull(apiKey, "apiKey");
      return this;
    }

    /** The account id, the number in your New Relic URLs. */
    public Builder accountId(String accountId) {
      this.accountId = Objects.requireNonNull(accountId, "accountId");
      return this;
    }

    /** The account id, the number in your New Relic URLs. */
    public Builder accountId(long accountId) {
      this.accountId = Long.toString(accountId);
      return this;
    }

    /** {@code eu} for an account in the EU data center. Default {@code us}. */
    public Builder region(String region) {
      this.region = Objects.requireNonNull(region, "region");
      return this;
    }

    /** Default {@code CronWatchAlert}. */
    public Builder eventType(String eventType) {
      this.eventType = Objects.requireNonNull(eventType, "eventType");
      return this;
    }

    /**
     * The options.
     *
     * @throws dev.cronwatch.CronwatchException without an API key or a numeric account id
     */
    public NewRelicOptions build() {
      // A pasted credential often carries a stray space or newline, which a header would refuse.
      String key = Shared.trimmed(apiKey);
      if (key.isEmpty()) {
        throw Shared.invalid("New Relic needs an apiKey");
      }
      if (!accountId.matches("[0-9]+")) {
        throw Shared.invalid("New Relic needs a numeric accountId");
      }
      return new NewRelicOptions(this, key);
    }

    /** Names what is set, never a value. */
    @Override
    public String toString() {
      return "NewRelicOptions.Builder";
    }
  }
}
