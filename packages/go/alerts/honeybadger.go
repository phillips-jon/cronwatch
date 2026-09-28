package alerts

// Honeybadger, as error notices (not Check-ins, a separate product).
// API reference: https://docs.honeybadger.io/api/reporting-exceptions/
// POST https://api.honeybadger.io/v1/notices with X-API-Key. Answers 201.

import (
	"context"
	"errors"
	"net/http"
	"strings"

	cronwatch "cronwatch.dev/go"
	"cronwatch.dev/go/internal/js"
)

// HoneybadgerOptions configure Honeybadger.
type HoneybadgerOptions struct {
	// APIKey is the project API key, from Project Settings.
	APIKey string
	// Environment defaults to "production".
	Environment string
	// Endpoint is another API host, "https://eu-api.honeybadger.io" say.
	// Default https://api.honeybadger.io.
	Endpoint string
	// Recovered also sends recoveries. Off by default: Honeybadger has no
	// levels, so a recovery would read as an error.
	Recovered bool
	// Link is a link back to the job in your dashboard, sent as the
	// request's URL.
	Link func(cronwatch.Alert) string
	// HTTPClient sends the request; nil for Go's default transport. It is
	// used as a copy that never follows a redirect.
	HTTPClient *http.Client
}

var honeybadgerClass = map[cronwatch.AlertType]string{
	cronwatch.AlertMissed:     "CronWatch::Missed",
	cronwatch.AlertFailed:     "CronWatch::Failed",
	cronwatch.AlertStuck:      "CronWatch::Stuck",
	cronwatch.AlertSlow:       "CronWatch::Slow",
	cronwatch.AlertOverBudget: "CronWatch::OverBudget",
	cronwatch.AlertRecovered:  "CronWatch::Recovered",
}

// Honeybadger reports alerts to Honeybadger as notices, one error per job
// and alert type.
func Honeybadger(o HoneybadgerOptions) (cronwatch.Channel, error) {
	// A pasted credential often carries a stray space or newline, which a header would refuse or send.
	apiKey := trimmed(o.APIKey)
	if apiKey == "" {
		return nil, errors.New("alerts.Honeybadger needs an APIKey")
	}
	endpoint := o.Endpoint
	if endpoint == "" {
		endpoint = "https://api.honeybadger.io"
	}
	url := strings.TrimRight(endpoint, "/") + "/v1/notices"
	environment := o.Environment
	if environment == "" {
		environment = "production"
	}
	return &channel{name: "honeybadger", send: func(ctx context.Context, a cronwatch.Alert, _ cronwatch.ChannelContext) error {
		if a.Type == cronwatch.AlertRecovered && !o.Recovered {
			return nil
		}
		link := linkFor(o.Link, a)
		request := js.NewObject("component", "cronwatch", "action", a.Job)
		if link != "" {
			request.Set("url", link)
		}
		about := js.NewObject("job", a.Job, "type", string(a.Type))
		if t := triage(a); t != "" {
			about.Set("triage", t)
		}
		about.Set("details", details(a))
		about.Set("run", runSummary(a))
		request.Set("context", about)
		notice := js.NewObject(
			"notifier", js.NewObject("name", "cronwatch", "url", "https://cronwatch.dev"),
			"error", js.NewObject(
				"class", honeybadgerClass[a.Type],
				"message", cut(js.WellFormed(a.Title+"\n"+a.Message), 8000),
				// No code ran here; one frame naming the job keeps the notice well formed.
				"backtrace", []any{js.NewObject("number", "0", "file", "cronwatch/"+a.Job, "method", string(a.Type))},
				"fingerprint", "cronwatch:"+a.Job+":"+string(a.Type),
				"tags", []any{"cronwatch", string(a.Type)},
			),
			"request", request,
			"server", js.NewObject("environment_name", environment),
		)
		return send(ctx, o.HTTPClient, "Honeybadger", url, []header{
			{Name: "content-type", Value: "application/json"},
			{Name: "accept", Value: "application/json"},
			{Name: "x-api-key", Value: apiKey},
		}, js.Stringify(notice), apiKey)
	}}, nil
}
