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
 * Reports alerts to Bugsnag, grouped per job and alert type ({@code alerts/bugsnag.ts}): the Error
 * Reporting API, payload version 5, {@code POST https://notify.bugsnag.com/} with {@code
 * Bugsnag-Api-Key}.
 */
public final class Bugsnag implements Channel {
  private final BugsnagOptions options;

  private Bugsnag(BugsnagOptions options) {
    this.options = Objects.requireNonNull(options, "options");
  }

  /** The channel. */
  public static Bugsnag channel(BugsnagOptions options) {
    return new Bugsnag(options);
  }

  @Override
  public String name() {
    return "bugsnag";
  }

  @Override
  public void send(Alert alert, ChannelContext context) throws Exception {
    if (alert.type().equals(AlertType.RECOVERED) && !options.recovered) {
      return;
    }
    String link = Shared.link(options.link, alert);
    String type = alert.type().value();
    JsObject meta = new JsObject().set("job", alert.job()).set("type", type);
    if (!Shared.triage(alert).isEmpty()) {
      meta.set("triage", Shared.triage(alert));
    }
    if (!link.isEmpty()) {
      meta.set("link", link);
    }
    meta.set("details", alert.details().toValue()).set("run", Shared.runSummary(alert));
    JsObject event =
        new JsObject()
            .set(
                "exceptions",
                List.of(
                    new JsObject()
                        .set("errorClass", "CronWatch " + type)
                        .set("message", Post.cut(alert.title() + "\n" + alert.message(), 8000))
                        .set("stacktrace", List.of())
                        .set("type", "nodejs")))
            .set("severity", Shared.severity(alert.type()))
            .set("unhandled", false)
            .set("severityReason", new JsObject().set("type", "handledException"))
            .set("context", alert.job())
            .set("groupingHash", "cronwatch:" + alert.job() + ":" + type)
            .set("metaData", new JsObject().set("cronwatch", meta))
            .set("app", new JsObject().set("releaseStage", options.releaseStage))
            .set("device", new JsObject().set("time", Shared.isoString(alert.at())));
    JsObject payload =
        new JsObject()
            .set("apiKey", options.apiKey)
            .set("payloadVersion", "5")
            // The notifier's own version, not the library's; Bugsnag asks for one.
            .set(
                "notifier",
                new JsObject()
                    .set("name", "cronwatch")
                    .set("version", "1.0.0")
                    .set("url", "https://cronwatch.dev"))
            .set("events", List.of(event));
    Shared.send(
        Shared.transport(options.transport, context),
        "Bugsnag",
        options.endpoint,
        Shared.headers(
            "content-type",
            "application/json",
            "bugsnag-api-key",
            options.apiKey,
            "bugsnag-payload-version",
            "5",
            "bugsnag-sent-at",
            Shared.isoString(options.now.getAsLong())),
        Json.stringify(payload),
        List.of(options.apiKey));
  }

  @Override
  public String toString() {
    return "Bugsnag";
  }
}
