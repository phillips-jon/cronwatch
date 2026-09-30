package dev.cronwatch.alerts;

import dev.cronwatch.Alert;
import dev.cronwatch.AlertType;
import dev.cronwatch.Channel;
import dev.cronwatch.ChannelContext;
import dev.cronwatch.internal.js.Js;
import dev.cronwatch.internal.post.Post;
import dev.cronwatch.json.JsObject;
import dev.cronwatch.json.Json;
import java.util.List;
import java.util.Objects;

/**
 * Sends alerts to Sentry as events through its envelope endpoint ({@code alerts/sentry.ts}), one
 * issue per job and alert type.
 */
public final class Sentry implements Channel {
  private final SentryOptions options;

  private Sentry(SentryOptions options) {
    this.options = Objects.requireNonNull(options, "options");
  }

  /** The channel. */
  public static Sentry channel(SentryOptions options) {
    return new Sentry(options);
  }

  @Override
  public String name() {
    return "sentry";
  }

  @Override
  public void send(Alert alert, ChannelContext context) throws Exception {
    if (alert.type().equals(AlertType.RECOVERED) && !options.recovered) {
      return;
    }
    String eventId = Shared.alertId(alert);
    String link = Shared.link(options.link, alert);
    JsObject extra = new JsObject();
    if (!Shared.triage(alert).isEmpty()) {
      extra.set("triage", Shared.triage(alert));
    }
    if (!link.isEmpty()) {
      extra.set("link", link);
    }
    extra.set("details", alert.details().toValue()).set("run", Shared.runSummary(alert));
    JsObject event =
        new JsObject()
            .set("event_id", eventId)
            .set("timestamp", alert.at() / 1000.0)
            .set("platform", "other")
            .set("level", Shared.severity(alert.type()))
            .set("logger", "cronwatch")
            .set("transaction", alert.job())
            .set("environment", options.environment);
    if (!options.release.isEmpty()) {
      event.set("release", options.release);
    }
    event
        // The first line is the issue title.
        .set(
            "logentry",
            new JsObject()
                .set("formatted", Post.cut(alert.title() + "\n\n" + alert.message(), 8192)))
        .set("fingerprint", List.of("cronwatch", alert.job(), alert.type().value()))
        .set(
            "tags",
            new JsObject().set("job", Post.cut(alert.job(), 199)).set("type", alert.type().value()))
        .set("extra", extra);
    String payload = Json.stringify(event);
    String envelope =
        Json.stringify(new JsObject().set("event_id", eventId))
            + "\n"
            + Json.stringify(
                new JsObject()
                    .set("type", "event")
                    .set("content_type", "application/json")
                    .set("length", Js.utf8(payload).length))
            + "\n"
            + payload
            + "\n";
    Shared.send(
        Shared.transport(options.transport, context),
        "Sentry",
        options.endpoint,
        Shared.headers(
            "content-type",
            "application/x-sentry-envelope",
            "x-sentry-auth",
            "Sentry sentry_version=7, sentry_key="
                + options.publicKey
                + ", sentry_client=cronwatch"),
        envelope,
        List.of(options.publicKey));
  }

  @Override
  public String toString() {
    return "Sentry";
  }
}
