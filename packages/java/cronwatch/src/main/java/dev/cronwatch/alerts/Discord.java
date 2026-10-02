package dev.cronwatch.alerts;

import dev.cronwatch.Alert;
import dev.cronwatch.Channel;
import dev.cronwatch.ChannelContext;
import dev.cronwatch.internal.js.Js;
import dev.cronwatch.internal.post.Post;
import dev.cronwatch.json.JsObject;
import dev.cronwatch.json.Json;
import java.util.List;
import java.util.Map;
import java.util.Objects;

/** Sends alerts to a Discord channel through a webhook ({@code alerts/discord.ts}). */
public final class Discord implements Channel {
  private static final Map<String, Integer> COLOR =
      Map.of(
          "missed", 0xb7791f,
          "failed", 0xc62828,
          "stuck", 0xc62828,
          "slow", 0xb7791f,
          "over_budget", 0xb7791f,
          "under_floor", 0xb7791f,
          "recovered", 0x1f8a4c);

  /**
   * The longest embed description Discord takes. The title (under 256) and it stay well inside the
   * embed's 6000.
   */
  static final int DESCRIPTION_MAX = 4096;

  private final DiscordOptions options;

  private Discord(DiscordOptions options) {
    this.options = Objects.requireNonNull(options, "options");
  }

  /** The channel. */
  public static Discord channel(DiscordOptions options) {
    return new Discord(options);
  }

  /**
   * The channel for a webhook URL, with no link.
   *
   * @throws dev.cronwatch.CronwatchException for an empty URL
   */
  public static Discord webhook(String webhookUrl) {
    return new Discord(DiscordOptions.builder().webhookUrl(webhookUrl).build());
  }

  @Override
  public String name() {
    return "discord";
  }

  @Override
  public void send(Alert alert, ChannelContext context) throws Exception {
    String url = Shared.link(options.link, alert);
    JsObject embed = new JsObject().set("title", alert.title());
    if (!url.isEmpty()) {
      embed.set("url", url);
    }
    embed.set("description", embedDescription(alert));
    // An unknown type has no colour, which JSON.stringify leaves out.
    Integer color = COLOR.get(alert.type().value());
    if (color != null) {
      embed.set("color", color);
    }
    embed.set("timestamp", Shared.isoString(alert.at()));
    JsObject payload =
        new JsObject()
            .set("content", alert.title())
            // Job output can hold anything, "@everyone" included; ping no one.
            .set("allowed_mentions", new JsObject().set("parse", List.of()))
            .set("embeds", List.of(embed));
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
          "Discord webhook answered " + answer.status() + ": " + Js.head(answer.body(), 200));
    }
  }

  /**
   * The message in a code block, then the triage. Each part has its own cap, and escaping can grow
   * both, so the whole is held to {@link #DESCRIPTION_MAX} UTF-16 units by cutting the message's
   * block, never the triage: Discord refuses a longer one on every retry.
   */
  static String embedDescription(Alert alert) {
    String t = Shared.triage(alert);
    String triage = t.isEmpty() ? "" : "\n**Triage:** " + escapeMarkdown(Js.head(t, 1000));
    int fences = "```\n".length() + "\n```".length();
    return "```\n"
        + Post.cut(
            Slack.codeBlockSafe(Js.head(alert.message(), 3800)),
            DESCRIPTION_MAX - fences - triage.length())
        + "\n```"
        + triage;
  }

  /** Escapes the characters Discord reads as markdown, links included. */
  static String escapeMarkdown(String text) {
    StringBuilder b = new StringBuilder(text.length());
    for (int i = 0; i < text.length(); i++) {
      char c = text.charAt(i);
      if ("\\`*_~|[]()<>".indexOf(c) >= 0) {
        b.append('\\');
      }
      b.append(c);
    }
    return b.toString();
  }

  @Override
  public String toString() {
    return "Discord";
  }
}
