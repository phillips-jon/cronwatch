package dev.cronwatch.alerts;

import dev.cronwatch.Alert;
import dev.cronwatch.Channel;
import dev.cronwatch.ChannelContext;
import dev.cronwatch.internal.js.Js;
import dev.cronwatch.internal.post.Post;
import dev.cronwatch.json.JsObject;
import dev.cronwatch.json.Json;
import java.util.ArrayList;
import java.util.List;
import java.util.Map;
import java.util.Objects;

/** Sends alerts to a Slack channel through an incoming webhook ({@code alerts/slack.ts}). */
public final class Slack implements Channel {
  private static final Map<String, String> EMOJI =
      Map.of(
          "missed", ":hourglass_flowing_sand:",
          "failed", ":x:",
          "stuck", ":no_entry:",
          "slow", ":turtle:",
          "over_budget", ":moneybag:",
          "under_floor", ":chart_with_downwards_trend:",
          "recovered", ":white_check_mark:");

  private final SlackOptions options;

  private Slack(SlackOptions options) {
    this.options = Objects.requireNonNull(options, "options");
  }

  /** The channel. */
  public static Slack channel(SlackOptions options) {
    return new Slack(options);
  }

  /**
   * The channel for an incoming webhook URL, with no link.
   *
   * @throws dev.cronwatch.CronwatchException for an empty URL
   */
  public static Slack webhook(String webhookUrl) {
    return new Slack(SlackOptions.builder().webhookUrl(webhookUrl).build());
  }

  @Override
  public String name() {
    return "slack";
  }

  @Override
  public void send(Alert alert, ChannelContext context) throws Exception {
    String url = Shared.link(options.link, alert);
    String title =
        EMOJI.getOrDefault(alert.type().value(), "undefined")
            + " *"
            + escape(alert.title())
            + "*"
            + (url.isEmpty() ? "" : " (<" + url + "|open>)");
    String body = Js.head(codeBlockSafe(escape(alert.message())), 2900);
    List<Object> blocks = new ArrayList<>();
    blocks.add(section(title));
    blocks.add(section("```" + body + "```"));
    // Its own block, so a long diagnosis cannot push a block past Slack's 3000 character limit.
    if (!Shared.triage(alert).isEmpty()) {
      blocks.add(section(Js.head("_Triage:_ " + escape(Shared.triage(alert)), 3000)));
    }
    JsObject payload =
        new JsObject()
            // The notification fallback is parsed as mrkdwn too, so it is escaped like the blocks.
            .set("text", escape(alert.title() + "\n" + alert.message()))
            .set("blocks", blocks);
    // A redirect is refused, not followed: a webhook URL is its own credential.
    Post.Answer answer =
        Post.fetch(
            Shared.transport(options.transport, context),
            Post.timeoutMs(),
            options.webhookUrl,
            Shared.headers("content-type", "application/json"),
            Json.stringify(payload));
    if (!answer.ok()) {
      throw Post.fail(
          "Slack webhook answered " + answer.status() + ": " + Js.head(answer.body(), 200));
    }
  }

  private static JsObject section(String text) {
    return new JsObject()
        .set("type", "section")
        .set("text", new JsObject().set("type", "mrkdwn").set("text", text));
  }

  /** Slack's three control characters. Escaping < and > also stops <!channel> and links. */
  static String escape(String text) {
    return text.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;");
  }

  /** Breaks up ``` so text inside a code block cannot close it. */
  static String codeBlockSafe(String text) {
    return text.replace("```", "`​`​`");
  }

  @Override
  public String toString() {
    return "Slack";
  }
}
