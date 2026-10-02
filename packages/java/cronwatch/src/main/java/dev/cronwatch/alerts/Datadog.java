package dev.cronwatch.alerts;

import dev.cronwatch.Alert;
import dev.cronwatch.Channel;
import dev.cronwatch.ChannelContext;
import dev.cronwatch.internal.post.Post;
import dev.cronwatch.json.JsObject;
import dev.cronwatch.json.Json;
import java.util.ArrayList;
import java.util.List;
import java.util.Map;
import java.util.Objects;

/**
 * Posts alerts to the Datadog event stream, aggregated per job and alert type ({@code
 * alerts/datadog.ts}): the Events API v1, {@code POST https://api.<site>/api/v1/events} with {@code
 * DD-API-KEY}.
 */
public final class Datadog implements Channel {
  private static final Map<String, String> ALERT_TYPE =
      Map.of(
          "missed", "error",
          "failed", "error",
          "stuck", "error",
          "slow", "warning",
          "over_budget", "warning",
          "under_floor", "warning",
          "recovered", "success");

  private final DatadogOptions options;

  private Datadog(DatadogOptions options) {
    this.options = Objects.requireNonNull(options, "options");
  }

  /** The channel. */
  public static Datadog channel(DatadogOptions options) {
    return new Datadog(options);
  }

  @Override
  public String name() {
    return "datadog";
  }

  @Override
  public void send(Alert alert, ChannelContext context) throws Exception {
    String link = Shared.link(options.link, alert);
    String type = alert.type().value();
    List<Object> tags =
        new ArrayList<>(List.of("cronwatch", "job:" + alert.job(), "alert:" + type));
    tags.addAll(options.tags);
    JsObject event =
        new JsObject()
            .set("title", Post.cut(alert.title(), 500))
            .set("text", Post.cut(Shared.plainText(alert, link), 4000));
    // An unknown type has none, which JSON.stringify leaves out.
    String alertType = ALERT_TYPE.get(type);
    if (alertType != null) {
      event.set("alert_type", alertType);
    }
    event
        .set("aggregation_key", aggregationKey(alert))
        .set("date_happened", Math.floorDiv(alert.at(), 1000))
        .set("priority", "normal")
        .set("tags", tags);
    if (!options.host.isEmpty()) {
      event.set("host", options.host);
    }
    Shared.send(
        Shared.transport(options.transport, context),
        "Datadog",
        options.url,
        Shared.headers(
            "content-type", "application/json",
            "accept", "application/json",
            "dd-api-key", options.apiKey),
        Json.stringify(event),
        List.of(options.apiKey));
  }

  /** {@code cronwatch:<job>:<type>}, or a hash of it when that passes Datadog's 100 characters. */
  static String aggregationKey(Alert alert) {
    String key = "cronwatch:" + alert.job() + ":" + alert.type().value();
    return key.length() <= 100 ? key : "cronwatch:" + Shared.sha256Hex(key).substring(0, 40);
  }

  @Override
  public String toString() {
    return "Datadog";
  }
}
