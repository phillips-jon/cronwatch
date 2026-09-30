package dev.cronwatch.alerts;

import dev.cronwatch.Alert;
import dev.cronwatch.Channel;
import dev.cronwatch.ChannelContext;
import dev.cronwatch.Run;
import dev.cronwatch.internal.post.Post;
import dev.cronwatch.json.JsObject;
import dev.cronwatch.json.Json;
import java.util.List;
import java.util.Objects;

/**
 * Records alerts as New Relic custom events ({@code alerts/newrelic.ts}): the Event API, {@code
 * POST https://insights-collector.newrelic.com/v1/accounts/<id>/events} ({@code
 * insights-collector.eu01.nr-data.net} for EU accounts) with {@code Api-Key}. Each alert is one
 * event of type {@code CronWatchAlert}, queryable with NRQL: {@code SELECT * FROM CronWatchAlert
 * WHERE job = 'nightly'}.
 */
public final class NewRelic implements Channel {
  private final NewRelicOptions options;

  private NewRelic(NewRelicOptions options) {
    this.options = Objects.requireNonNull(options, "options");
  }

  /** The channel. */
  public static NewRelic channel(NewRelicOptions options) {
    return new NewRelic(options);
  }

  @Override
  public String name() {
    return "newrelic";
  }

  @Override
  public void send(Alert alert, ChannelContext context) throws Exception {
    String link = Shared.link(options.link, alert);
    Run run = alert.run();
    // Flat attributes only, strings under 4096 characters.
    JsObject event =
        new JsObject()
            .set("eventType", options.eventType)
            .set("timestamp", alert.at())
            .set("job", Post.cut(alert.job(), 4095))
            .set("alertType", alert.type().value())
            .set("severity", Shared.severity(alert.type()))
            .set("title", Post.cut(alert.title(), 4095))
            .set("message", Post.cut(alert.message(), 4095));
    if (!Shared.triage(alert).isEmpty()) {
      event.set("triage", Post.cut(Shared.triage(alert), 4095));
    }
    if (!link.isEmpty()) {
      event.set("link", Post.cut(link, 4095));
    }
    if (run != null) {
      event.set("runId", run.id()).set("runStatus", run.status().value());
      if (run.durationMs() != null) {
        event.set("durationMs", run.durationMs());
      }
    }
    Shared.send(
        Shared.transport(options.transport, context),
        "New Relic",
        options.url,
        Shared.headers("content-type", "application/json", "api-key", options.apiKey),
        Json.stringify(List.of(event)),
        List.of(options.apiKey));
  }

  @Override
  public String toString() {
    return "NewRelic";
  }
}
