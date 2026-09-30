package dev.cronwatch.alerts;

import dev.cronwatch.Alert;
import java.util.Objects;
import java.util.function.Function;
import org.jspecify.annotations.Nullable;

/** Configures {@link Discord}. */
public final class DiscordOptions {
  final String webhookUrl;
  final @Nullable Function<Alert, @Nullable String> link;
  final @Nullable Transport transport;

  private DiscordOptions(Builder b) {
    this.webhookUrl = b.webhookUrl;
    this.link = b.link;
    this.transport = b.transport;
  }

  /** A builder with nothing set. */
  public static Builder builder() {
    return new Builder();
  }

  /** Names what is set, never the webhook URL, which is its own credential. */
  @Override
  public String toString() {
    return "DiscordOptions[webhookUrl=set" + (link == null ? "" : ", link") + "]";
  }

  /** Builds {@link DiscordOptions}. */
  public static final class Builder extends ChannelBuilder<Builder> {
    private String webhookUrl = "";

    private Builder() {}

    @Override
    Builder self() {
      return this;
    }

    /**
     * A channel webhook URL from Server Settings, Integrations, Webhooks. It is its own credential:
     * errors never quote it.
     */
    public Builder webhookUrl(String webhookUrl) {
      this.webhookUrl = Objects.requireNonNull(webhookUrl, "webhookUrl");
      return this;
    }

    /**
     * The options.
     *
     * @throws dev.cronwatch.CronwatchException without a webhook URL
     */
    public DiscordOptions build() {
      if (webhookUrl.isEmpty()) {
        throw Shared.invalid("Discord needs a webhookUrl");
      }
      return new DiscordOptions(this);
    }

    /** Names what is set, never a value. */
    @Override
    public String toString() {
      return "DiscordOptions.Builder";
    }
  }
}
