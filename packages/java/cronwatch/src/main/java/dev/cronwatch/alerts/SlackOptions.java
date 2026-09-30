package dev.cronwatch.alerts;

import dev.cronwatch.Alert;
import java.util.Objects;
import java.util.function.Function;
import org.jspecify.annotations.Nullable;

/** Configures {@link Slack}. */
public final class SlackOptions {
  final String webhookUrl;
  final @Nullable Function<Alert, @Nullable String> link;
  final @Nullable Transport transport;

  private SlackOptions(Builder b) {
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
    return "SlackOptions[webhookUrl=set" + (link == null ? "" : ", link") + "]";
  }

  /** Builds {@link SlackOptions}. */
  public static final class Builder extends ChannelBuilder<Builder> {
    private String webhookUrl = "";

    private Builder() {}

    @Override
    Builder self() {
      return this;
    }

    /**
     * An incoming webhook URL from api.slack.com/messaging/webhooks. It is its own credential:
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
    public SlackOptions build() {
      if (webhookUrl.isEmpty()) {
        throw Shared.invalid("Slack needs a webhookUrl");
      }
      return new SlackOptions(this);
    }

    /** Names what is set, never a value. */
    @Override
    public String toString() {
      return "SlackOptions.Builder";
    }
  }
}
