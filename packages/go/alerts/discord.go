package alerts

import (
	"context"
	"errors"
	"fmt"
	"net/http"
	"strings"

	cronwatch "cronwatch.dev/go"
	"cronwatch.dev/go/internal/js"
	"cronwatch.dev/go/internal/post"
)

// DiscordOptions configure Discord.
type DiscordOptions struct {
	// WebhookURL is a channel webhook URL from Server Settings,
	// Integrations, Webhooks. It is its own credential: errors never quote it.
	WebhookURL string
	// Link is a link back to the job in your dashboard, "" for none.
	Link func(cronwatch.Alert) string
	// HTTPClient sends the request; nil for Go's default transport. It is
	// used as a copy that never follows a redirect.
	HTTPClient *http.Client
}

var discordColor = map[cronwatch.AlertType]int{
	cronwatch.AlertMissed:     0xb7791f,
	cronwatch.AlertFailed:     0xc62828,
	cronwatch.AlertStuck:      0xc62828,
	cronwatch.AlertSlow:       0xb7791f,
	cronwatch.AlertOverBudget: 0xb7791f,
	cronwatch.AlertRecovered:  0x1f8a4c,
}

// Discord sends alerts to a Discord channel through a webhook.
func Discord(o DiscordOptions) (cronwatch.Channel, error) {
	if o.WebhookURL == "" {
		return nil, errors.New("alerts.Discord needs a WebhookURL")
	}
	return &channel{name: "discord", send: func(ctx context.Context, a cronwatch.Alert, _ cronwatch.ChannelContext) error {
		title := js.WellFormed(a.Title)
		link := js.WellFormed(linkFor(o.Link, a))
		description := embedDescription(a)
		embed := js.NewObject("title", title)
		if link != "" {
			embed.Set("url", link)
		}
		embed.Set("description", description)
		embed.Set("color", discordColor[a.Type])
		embed.Set("timestamp", js.ISOString(a.At))
		payload := js.StringifyLone(js.NewObject(
			"content", title,
			// Job output can hold anything, "@everyone" included; ping no one.
			"allowed_mentions", js.NewObject("parse", []any{}),
			"embeds", []any{embed},
		))
		// A redirect is refused, not followed: a webhook URL is its own credential.
		resp, err := post.Do(ctx, o.HTTPClient, o.WebhookURL, []header{{Name: "content-type", Value: "application/json"}}, payload)
		if err != nil {
			return err
		}
		if !resp.OK() {
			return fmt.Errorf("%s webhook answered %d: %s", "Discord", resp.Status, js.Head16(resp.Body, 200))
		}
		return nil
	}}, nil
}

// discordDescriptionMax is the longest embed description Discord takes. The
// title (under 256) and it stay well inside the embed's 6000.
const discordDescriptionMax = 4096

// embedDescription is the message in a code block, then the triage. Each
// part has its own cap, and escaping can grow both, so the whole is held to
// discordDescriptionMax (in UTF-16 code units) by cutting the message's
// block, never the triage: Discord refuses a longer one on every retry.
func embedDescription(a cronwatch.Alert) string {
	tail := ""
	if t := triage(a); t != "" {
		tail = "\n**Triage:** " + escapeMarkdown(js.Head16Lone(t, 1000))
	}
	fences := len("```\n") + len("\n```")
	block := js.Cut16Lone(codeBlockSafe(js.Head16Lone(a.Message, 3800)), discordDescriptionMax-fences-js.Length16Lone(tail))
	return "```\n" + block + "\n```" + tail
}

// escapeMarkdown escapes the characters Discord reads as markdown, links
// included.
func escapeMarkdown(text string) string {
	var b strings.Builder
	for i := 0; i < len(text); i++ {
		if strings.IndexByte("\\`*_~|[]()<>", text[i]) >= 0 {
			b.WriteByte('\\')
		}
		b.WriteByte(text[i])
	}
	return b.String()
}
