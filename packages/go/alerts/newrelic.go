package alerts

// New Relic Event API. API reference: https://docs.newrelic.com/docs/data-apis/ingest-apis/event-api/introduction-event-api/
// POST https://insights-collector.newrelic.com/v1/accounts/<id>/events
// (insights-collector.eu01.nr-data.net for EU accounts) with Api-Key.
// Each alert is one custom event of type CronWatchAlert, queryable with
// NRQL: SELECT * FROM CronWatchAlert WHERE job = 'nightly'.

import (
	"context"
	"errors"
	"net/http"

	cronwatch "cronwatch.dev/go"
	"cronwatch.dev/go/internal/js"
)

// NewRelicOptions configure NewRelic.
type NewRelicOptions struct {
	// AccountID is the account id, the number in your New Relic URLs.
	AccountID string
	// APIKey is a license key (INGEST - LICENSE).
	APIKey string
	// Region is "eu" for an account in the EU data center. Default "us".
	Region string
	// EventType defaults to "CronWatchAlert".
	EventType string
	// Link is a link back to the job in your dashboard, sent as an attribute.
	Link func(cronwatch.Alert) string
	// HTTPClient sends the request; nil for Go's default transport. It is
	// used as a copy that never follows a redirect.
	HTTPClient *http.Client
}

// NewRelic records alerts as New Relic custom events.
func NewRelic(o NewRelicOptions) (cronwatch.Channel, error) {
	// A pasted credential often carries a stray space or newline, which a header would refuse or send.
	apiKey := trimmed(o.APIKey)
	if apiKey == "" {
		return nil, errors.New("alerts.NewRelic needs an APIKey")
	}
	if !digits.MatchString(o.AccountID) {
		return nil, errors.New("alerts.NewRelic needs a numeric AccountID")
	}
	host := "https://insights-collector.newrelic.com"
	if o.Region == "eu" {
		host = "https://insights-collector.eu01.nr-data.net"
	}
	url := host + "/v1/accounts/" + o.AccountID + "/events"
	eventType := o.EventType
	if eventType == "" {
		eventType = "CronWatchAlert"
	}
	return &channel{name: "newrelic", send: func(ctx context.Context, a cronwatch.Alert, _ cronwatch.ChannelContext) error {
		link := linkFor(o.Link, a)
		// Flat attributes only, strings under 4096 characters.
		event := js.NewObject(
			"eventType", eventType,
			"timestamp", a.At,
			"job", cut(js.WellFormed(a.Job), 4095),
			"alertType", string(a.Type),
			"severity", severity(a.Type),
			"title", cut(js.WellFormed(a.Title), 4095),
			"message", cut(js.WellFormed(a.Message), 4095),
		)
		if t := triage(a); t != "" {
			event.Set("triage", cut(js.WellFormed(t), 4095))
		}
		if link != "" {
			event.Set("link", cut(js.WellFormed(link), 4095))
		}
		if r := a.Run; r != nil {
			event.Set("runId", r.ID)
			event.Set("runStatus", string(r.Status))
			if r.DurationMs != nil {
				event.Set("durationMs", *r.DurationMs)
			}
		}
		return send(ctx, o.HTTPClient, "New Relic", url, []header{
			{Name: "content-type", Value: "application/json"},
			{Name: "api-key", Value: apiKey},
		}, js.Stringify([]any{event}), apiKey)
	}}, nil
}
