package dev.cronwatch.alerts;

import dev.cronwatch.Alert;
import dev.cronwatch.AlertType;
import dev.cronwatch.Channel;
import dev.cronwatch.ChannelContext;
import dev.cronwatch.internal.post.Post;
import dev.cronwatch.json.JsObject;
import dev.cronwatch.json.Json;
import java.util.List;
import java.util.Objects;

/**
 * Reports alerts to Rollbar, one item per job and alert type ({@code alerts/rollbar.ts}): {@code
 * POST https://api.rollbar.com/api/1/item/} with {@code X-Rollbar-Access-Token}.
 */
public final class Rollbar implements Channel {
  private static final String ENDPOINT = "https://api.rollbar.com/api/1/item/";

  private final RollbarOptions options;

  private Rollbar(RollbarOptions options) {
    this.options = Objects.requireNonNull(options, "options");
  }

  /** The channel. */
  public static Rollbar channel(RollbarOptions options) {
    return new Rollbar(options);
  }

  @Override
  public String name() {
    return "rollbar";
  }

  @Override
  public void send(Alert alert, ChannelContext context) throws Exception {
    if (alert.type().equals(AlertType.RECOVERED) && !options.recovered) {
      return;
    }
    String link = Shared.link(options.link, alert);
    String type = alert.type().value();
    JsObject custom = new JsObject().set("job", alert.job()).set("type", type);
    if (!Shared.triage(alert).isEmpty()) {
      custom.set("triage", Shared.triage(alert));
    }
    if (!link.isEmpty()) {
      custom.set("link", link);
    }
    custom.set("details", alert.details().toValue()).set("run", Shared.runSummary(alert));
    JsObject data =
        new JsObject()
            .set("environment", Post.cut(options.environment, 255))
            .set("level", Shared.severity(alert.type()))
            .set("timestamp", Math.floorDiv(alert.at(), 1000))
            .set("title", Post.cut(alert.title(), 255))
            // Rollbar hashes a fingerprint longer than 40 characters itself.
            .set("fingerprint", "cronwatch:" + alert.job() + ":" + type)
            .set("uuid", Shared.asUuid(Shared.alertId(alert)))
            .set("body", new JsObject().set("message", new JsObject().set("body", alert.message())))
            .set("custom", custom)
            .set("notifier", new JsObject().set("name", "cronwatch"));
    Shared.send(
        Shared.transport(options.transport, context),
        "Rollbar",
        ENDPOINT,
        Shared.headers(
            "content-type", "application/json", "x-rollbar-access-token", options.accessToken),
        Json.stringify(new JsObject().set("data", data)),
        List.of(options.accessToken));
  }

  @Override
  public String toString() {
    return "Rollbar";
  }
}
