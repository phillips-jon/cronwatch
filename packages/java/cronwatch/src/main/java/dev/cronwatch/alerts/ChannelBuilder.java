package dev.cronwatch.alerts;

import dev.cronwatch.Alert;
import java.util.Objects;
import java.util.function.Function;
import org.jspecify.annotations.Nullable;

/**
 * What every channel's options builder takes: a link back to the job in the app's dashboard, and a
 * transport of the app's own.
 *
 * @param <B> the builder itself
 */
public abstract class ChannelBuilder<B extends ChannelBuilder<B>> {
  @Nullable Function<Alert, @Nullable String> link;
  @Nullable Transport transport;

  ChannelBuilder() {}

  abstract B self();

  /**
   * A link back to the job in your dashboard: {@code alert ->
   * "https://app.example.com/cronwatch/jobs/" + alert.job()}. Null or {@code ""} is no link.
   */
  public B link(Function<Alert, @Nullable String> link) {
    this.link = Objects.requireNonNull(link, "link");
    return self();
  }

  /**
   * Sends this channel's requests; by default the client's transport ({@link JdkTransport} unless
   * the client was given another).
   */
  public B transport(Transport transport) {
    this.transport = Objects.requireNonNull(transport, "transport");
    return self();
  }
}
