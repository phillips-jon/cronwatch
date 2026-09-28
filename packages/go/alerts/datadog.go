package alerts

// Datadog Events API v1.
// API reference: https://docs.datadoghq.com/api/latest/events/ (Post an event)
// POST https://api.<site>/api/v1/events with DD-API-KEY. Answers 202.

import (
	"context"
	"errors"
	"net/http"
	"regexp"
	"strings"

	cronwatch "cronwatch.dev/go"
	"cronwatch.dev/go/internal/js"
)

// DatadogOptions configure Datadog.
type DatadogOptions struct {
	// APIKey is an API key (not an application key).
	APIKey string
	// Site is your Datadog site: "datadoghq.com" (the default),
	// "datadoghq.eu", "us3.datadoghq.com", "us5.datadoghq.com",
	// "ap1.datadoghq.com", "ddog-gov.com".
	Site string
	// Tags are extra tags, "env:prod" say. Every event also has cronwatch,
	// job:<name> and alert:<type>.
	Tags []string
	// Host associates the event with a host and its tags.
	Host string
	// Link is a link back to the job in your dashboard, put in the text.
	Link func(cronwatch.Alert) string
	// HTTPClient sends the request; nil for Go's default transport. It is
	// used as a copy that never follows a redirect.
	HTTPClient *http.Client
}

var datadogAlertType = map[cronwatch.AlertType]string{
	cronwatch.AlertMissed:     "error",
	cronwatch.AlertFailed:     "error",
	cronwatch.AlertStuck:      "error",
	cronwatch.AlertSlow:       "warning",
	cronwatch.AlertOverBudget: "warning",
	cronwatch.AlertRecovered:  "success",
}

var (
	datadogScheme = regexp.MustCompile(`^https?://`)
	datadogHost   = regexp.MustCompile(`^(api|app)\.`)
	datadogSite   = regexp.MustCompile(`^(?i)[a-z0-9.-]+$`)
)

// Datadog posts alerts to the Datadog event stream, aggregated per job and
// alert type.
func Datadog(o DatadogOptions) (cronwatch.Channel, error) {
	// A pasted credential often carries a stray space or newline, which a header would refuse or send.
	apiKey := trimmed(o.APIKey)
	if apiKey == "" {
		return nil, errors.New("alerts.Datadog needs an APIKey")
	}
	site := o.Site
	if site == "" {
		site = "datadoghq.com"
	}
	site = strings.TrimRight(datadogHost.ReplaceAllString(datadogScheme.ReplaceAllString(site, ""), ""), "/")
	if !datadogSite.MatchString(site) {
		return nil, errors.New("alerts.Datadog needs a Site like datadoghq.com")
	}
	url := "https://api." + site + "/api/v1/events"
	return &channel{name: "datadog", send: func(ctx context.Context, a cronwatch.Alert, _ cronwatch.ChannelContext) error {
		link := linkFor(o.Link, a)
		tags := []any{"cronwatch", "job:" + a.Job, "alert:" + string(a.Type)}
		for _, t := range o.Tags {
			tags = append(tags, t)
		}
		event := js.NewObject(
			"title", cut(js.WellFormed(a.Title), 500),
			"text", cut(js.WellFormed(plainText(a, link)), 4000),
			"alert_type", datadogAlertType[a.Type],
			"aggregation_key", aggregationKey(a),
			"date_happened", js.FloorDiv(a.At, 1000),
			"priority", "normal",
			"tags", tags,
		)
		if o.Host != "" {
			event.Set("host", o.Host)
		}
		return send(ctx, o.HTTPClient, "Datadog", url, []header{
			{Name: "content-type", Value: "application/json"},
			{Name: "accept", Value: "application/json"},
			{Name: "dd-api-key", Value: apiKey},
		}, js.Stringify(event), apiKey)
	}}, nil
}

// aggregationKey is "cronwatch:<job>:<type>", or a hash of it when that
// passes Datadog's 100 characters.
func aggregationKey(a cronwatch.Alert) string {
	key := "cronwatch:" + a.Job + ":" + string(a.Type)
	if js.Length16(key) <= 100 {
		return key
	}
	return "cronwatch:" + sha256Hex(key)[:40]
}
