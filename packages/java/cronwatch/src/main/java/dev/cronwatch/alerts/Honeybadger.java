package dev.cronwatch.alerts;

import dev.cronwatch.Alert;
import dev.cronwatch.AlertType;
import dev.cronwatch.Channel;
import dev.cronwatch.ChannelContext;
import dev.cronwatch.internal.post.Post;
import dev.cronwatch.json.JsObject;
import dev.cronwatch.json.Json;
import java.util.List;
import java.util.Map;
import java.util.Objects;

/**
 * Reports alerts to Honeybadger as error notices ({@code alerts/honeybadger.ts}), one error per job
 * and alert type: {@code POST https://api.honeybadger.io/v1/notices} with {@code X-API-Key}.
 */
public final class Honeybadger implements Channel {
  private static final Map<String, String> CLASS =
      Map.of(
          "missed", "CronWatch::Missed",
          "failed", "CronWatch::Failed",
          "stuck", "CronWatch::Stuck",
          "slow", "CronWatch::Slow",
          "over_budget", "CronWatch::OverBudget",
          "recovered", "CronWatch::Recovered");

  private final HoneybadgerOptions options;

  private Honeybadger(HoneybadgerOptions options) {
    this.options = Objects.requireNonNull(options, "options");
  }

  /** The channel. */
  public static Honeybadger channel(HoneybadgerOptions options) {
    return new Honeybadger(options);
  }

  @Override
  public String name() {
    return "honeybadger";
  }

  @Override
  public void send(Alert alert, ChannelContext context) throws Exception {
    if (alert.type().equals(AlertType.RECOVERED) && !options.recovered) {
      return;
    }
    String link = Shared.link(options.link, alert);
    String type = alert.type().value();
    JsObject error = new JsObject();
    // An unknown type has no class, which JSON.stringify leaves out.
    String errorClass = CLASS.get(type);
    if (errorClass != null) {
      error.set("class", errorClass);
    }
    error
        .set("message", Post.cut(alert.title() + "\n" + alert.message(), 8000))
        // No code ran here; one frame naming the job keeps the notice well formed.
        .set(
            "backtrace",
            List.of(
                new JsObject()
                    .set("number", "0")
                    .set("file", "cronwatch/" + alert.job())
                    .set("method", type)))
        .set("fingerprint", "cronwatch:" + alert.job() + ":" + type)
        .set("tags", List.of("cronwatch", type));
    JsObject request = new JsObject().set("component", "cronwatch").set("action", alert.job());
    if (!link.isEmpty()) {
      request.set("url", link);
    }
    JsObject ctx = new JsObject().set("job", alert.job()).set("type", type);
    if (!Shared.triage(alert).isEmpty()) {
      ctx.set("triage", Shared.triage(alert));
    }
    ctx.set("details", alert.details().toValue()).set("run", Shared.runSummary(alert));
    request.set("context", ctx);
    JsObject notice =
        new JsObject()
            .set(
                "notifier",
                new JsObject().set("name", "cronwatch").set("url", "https://cronwatch.dev"))
            .set("error", error)
            .set("request", request)
            .set("server", new JsObject().set("environment_name", options.environment));
    Shared.send(
        Shared.transport(options.transport, context),
        "Honeybadger",
        options.url,
        Shared.headers(
            "content-type", "application/json",
            "accept", "application/json",
            "x-api-key", options.apiKey),
        Json.stringify(notice),
        List.of(options.apiKey));
  }

  @Override
  public String toString() {
    return "Honeybadger";
  }
}
