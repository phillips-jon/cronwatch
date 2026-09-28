package alerts

// Rollbar. API reference: https://docs.rollbar.com/reference/create-item
// POST https://api.rollbar.com/api/1/item/ with X-Rollbar-Access-Token.

import (
	"context"
	"errors"
	"net/http"

	cronwatch "cronwatch.dev/go"
	"cronwatch.dev/go/internal/js"
)

// RollbarOptions configure Rollbar.
type RollbarOptions struct {
	// AccessToken is a project access token with the post_server_item scope.
	AccessToken string
	// Environment defaults to "production".
	Environment string
	// SkipRecovered leaves recoveries out. They are sent by default, as
	// info items.
	SkipRecovered bool
	// Link is a link back to the job in your dashboard, sent as custom data.
	Link func(cronwatch.Alert) string
	// HTTPClient sends the request; nil for Go's default transport. It is
	// used as a copy that never follows a redirect.
	HTTPClient *http.Client
}

const rollbarEndpoint = "https://api.rollbar.com/api/1/item/"

// Rollbar reports alerts to Rollbar, one item per job and alert type.
func Rollbar(o RollbarOptions) (cronwatch.Channel, error) {
	// A pasted credential often carries a stray space or newline, which a header would refuse or send.
	token := trimmed(o.AccessToken)
	if token == "" {
		return nil, errors.New("alerts.Rollbar needs an AccessToken")
	}
	environment := o.Environment
	if environment == "" {
		environment = "production"
	}
	return &channel{name: "rollbar", send: func(ctx context.Context, a cronwatch.Alert, _ cronwatch.ChannelContext) error {
		if a.Type == cronwatch.AlertRecovered && o.SkipRecovered {
			return nil
		}
		link := linkFor(o.Link, a)
		custom := js.NewObject("job", a.Job, "type", string(a.Type))
		if t := triage(a); t != "" {
			custom.Set("triage", t)
		}
		if link != "" {
			custom.Set("link", link)
		}
		custom.Set("details", details(a))
		custom.Set("run", runSummary(a))
		item := js.NewObject("data", js.NewObject(
			"environment", cut(js.WellFormed(environment), 255),
			"level", severity(a.Type),
			"timestamp", js.FloorDiv(a.At, 1000),
			"title", cut(js.WellFormed(a.Title), 255),
			// Rollbar hashes a fingerprint longer than 40 characters itself.
			"fingerprint", "cronwatch:"+a.Job+":"+string(a.Type),
			"uuid", asUUID(alertID(a)),
			"body", js.NewObject("message", js.NewObject("body", a.Message)),
			"custom", custom,
			"notifier", js.NewObject("name", "cronwatch"),
		))
		return send(ctx, o.HTTPClient, "Rollbar", rollbarEndpoint, []header{
			{Name: "content-type", Value: "application/json"},
			{Name: "x-rollbar-access-token", Value: token},
		}, js.Stringify(item), token)
	}}, nil
}
