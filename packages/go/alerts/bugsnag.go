package alerts

// Bugsnag, Error Reporting API, payload version 5.
// API reference: https://developer.smartbear.com/bugsnag/docs/reporting-events-and-sessions
// POST https://notify.bugsnag.com/ with Bugsnag-Api-Key.

import (
	"context"
	"errors"
	"net/http"
	"time"

	cronwatch "cronwatch.dev/go"
	"cronwatch.dev/go/internal/js"
)

// BugsnagOptions configure Bugsnag.
type BugsnagOptions struct {
	// APIKey is the project's notifier API key.
	APIKey string
	// ReleaseStage defaults to "production".
	ReleaseStage string
	// Endpoint is another notify endpoint, for on-premise installs.
	// Default https://notify.bugsnag.com/.
	Endpoint string
	// Recovered also sends recoveries, as info events. Off by default,
	// since each one is an event on an error.
	Recovered bool
	// Now is the clock for the Bugsnag-Sent-At header, in epoch
	// milliseconds. For tests; nil for the time now.
	Now func() int64
	// Link is a link back to the job in your dashboard, sent as metadata.
	Link func(cronwatch.Alert) string
	// HTTPClient sends the request; nil for Go's default transport. It is
	// used as a copy that never follows a redirect.
	HTTPClient *http.Client
}

// Bugsnag reports alerts to Bugsnag, grouped per job and alert type.
func Bugsnag(o BugsnagOptions) (cronwatch.Channel, error) {
	// A pasted credential often carries a stray space or newline, which a header would refuse or send.
	apiKey := trimmed(o.APIKey)
	if apiKey == "" {
		return nil, errors.New("alerts.Bugsnag needs an APIKey")
	}
	url := o.Endpoint
	if url == "" {
		url = "https://notify.bugsnag.com/"
	}
	stage := o.ReleaseStage
	if stage == "" {
		stage = "production"
	}
	now := o.Now
	if now == nil {
		now = func() int64 { return time.Now().UnixMilli() }
	}
	return &channel{name: "bugsnag", send: func(ctx context.Context, a cronwatch.Alert, _ cronwatch.ChannelContext) error {
		if a.Type == cronwatch.AlertRecovered && !o.Recovered {
			return nil
		}
		link := linkFor(o.Link, a)
		meta := js.NewObject("job", a.Job, "type", string(a.Type))
		if t := triage(a); t != "" {
			meta.Set("triage", t)
		}
		if link != "" {
			meta.Set("link", link)
		}
		meta.Set("details", details(a))
		meta.Set("run", runSummary(a))
		sev := severity(a.Type)
		payload := js.NewObject(
			"apiKey", apiKey,
			"payloadVersion", "5",
			// The notifier's own version, not the SDK's; Bugsnag asks for one.
			"notifier", js.NewObject("name", "cronwatch", "version", "1.0.0", "url", "https://cronwatch.dev"),
			"events", []any{js.NewObject(
				"exceptions", []any{js.NewObject(
					"errorClass", "CronWatch "+string(a.Type),
					"message", cut(js.WellFormed(a.Title+"\n"+a.Message), 8000),
					"stacktrace", []any{},
					"type", "nodejs",
				)},
				"severity", sev,
				"unhandled", false,
				"severityReason", js.NewObject("type", "handledException"),
				"context", a.Job,
				"groupingHash", "cronwatch:"+a.Job+":"+string(a.Type),
				"metaData", js.NewObject("cronwatch", meta),
				"app", js.NewObject("releaseStage", stage),
				"device", js.NewObject("time", js.ISOString(a.At)),
			)},
		)
		return send(ctx, o.HTTPClient, "Bugsnag", url, []header{
			{Name: "content-type", Value: "application/json"},
			{Name: "bugsnag-api-key", Value: apiKey},
			{Name: "bugsnag-payload-version", Value: "5"},
			{Name: "bugsnag-sent-at", Value: js.ISOString(now())},
		}, js.Stringify(payload), apiKey)
	}}, nil
}
