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

// SlackOptions configure Slack.
type SlackOptions struct {
	// WebhookURL is an incoming webhook URL from
	// api.slack.com/messaging/webhooks. It is its own credential: errors
	// never quote it.
	WebhookURL string
	// Link is a link back to the job in your dashboard, "" for none.
	Link func(cronwatch.Alert) string
	// HTTPClient sends the request; nil for Go's default transport. It is
	// used as a copy that never follows a redirect.
	HTTPClient *http.Client
}

var slackEmoji = map[cronwatch.AlertType]string{
	cronwatch.AlertMissed:     ":hourglass_flowing_sand:",
	cronwatch.AlertFailed:     ":x:",
	cronwatch.AlertStuck:      ":no_entry:",
	cronwatch.AlertSlow:       ":turtle:",
	cronwatch.AlertOverBudget: ":moneybag:",
	cronwatch.AlertRecovered:  ":white_check_mark:",
}

// Slack sends alerts to a Slack channel through an incoming webhook.
func Slack(o SlackOptions) (cronwatch.Channel, error) {
	if o.WebhookURL == "" {
		return nil, errors.New("alerts.Slack needs a WebhookURL")
	}
	return &channel{name: "slack", send: func(ctx context.Context, a cronwatch.Alert, _ cronwatch.ChannelContext) error {
		title, message, diagnosis := js.WellFormed(a.Title), js.WellFormed(a.Message), js.WellFormed(triage(a))
		link := js.WellFormed(linkFor(o.Link, a))
		head := slackEmoji[a.Type] + " *" + slackEscape(title) + "*"
		if link != "" {
			head += " (<" + link + "|open>)"
		}
		body := js.Head16Lone(codeBlockSafe(slackEscape(message)), 2900)
		blocks := []any{
			js.NewObject("type", "section", "text", js.NewObject("type", "mrkdwn", "text", head)),
			js.NewObject("type", "section", "text", js.NewObject("type", "mrkdwn", "text", "```"+body+"```")),
		}
		if diagnosis != "" {
			// Its own block, so a long diagnosis cannot push a block past Slack's 3000 character limit.
			blocks = append(blocks, js.NewObject("type", "section", "text", js.NewObject("type", "mrkdwn", "text", js.Head16Lone("_Triage:_ "+slackEscape(diagnosis), 3000))))
		}
		payload := js.StringifyLone(js.NewObject(
			// The notification fallback is parsed as mrkdwn too, so it is escaped like the blocks.
			"text", slackEscape(title+"\n"+message),
			"blocks", blocks,
		))
		// A redirect is refused, not followed: a webhook URL is its own credential.
		resp, err := post.Do(ctx, o.HTTPClient, o.WebhookURL, []header{{Name: "content-type", Value: "application/json"}}, payload)
		if err != nil {
			return err
		}
		if !resp.OK() {
			return fmt.Errorf("%s webhook answered %d: %s", "Slack", resp.Status, js.Head16(resp.Body, 200))
		}
		return nil
	}}, nil
}

// slackEscape escapes Slack's three control characters. Escaping < and >
// also stops <!channel> and <url|links>.
func slackEscape(text string) string {
	return strings.NewReplacer("&", "&amp;", "<", "&lt;", ">", "&gt;").Replace(text)
}

// codeBlockSafe breaks up ``` so text inside a code block cannot close it.
func codeBlockSafe(text string) string {
	return strings.ReplaceAll(text, "```", "`\u200b`\u200b`")
}
