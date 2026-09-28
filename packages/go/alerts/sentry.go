package alerts

// Sentry, through the envelope endpoint.
// Envelopes: https://develop.sentry.dev/sdk/data-model/envelopes/
// Event payload: https://develop.sentry.dev/sdk/data-model/event-payloads/
// DSN and X-Sentry-Auth: https://develop.sentry.dev/sdk/foundations/transport/authentication/

import (
	"context"
	"errors"
	"net/http"
	"net/url"
	"regexp"
	"strings"

	cronwatch "cronwatch.dev/go"
	"cronwatch.dev/go/internal/js"
)

// SentryOptions configure Sentry.
type SentryOptions struct {
	// DSN is the project's DSN, "https://<key>@o0.ingest.sentry.io/<project>".
	DSN string
	// Environment defaults to "production".
	Environment string
	Release     string
	// SkipRecovered leaves recoveries out. They are sent by default, as
	// info events.
	SkipRecovered bool
	// Link is a link back to the job in your dashboard, sent as extra data.
	Link func(cronwatch.Alert) string
	// HTTPClient sends the request; nil for Go's default transport. It is
	// used as a copy that never follows a redirect.
	HTTPClient *http.Client
}

var digits = regexp.MustCompile(`^\d+$`)

// parseDSN is the envelope endpoint and the public key of a DSN.
func parseDSN(dsn string) (endpoint, publicKey string, err error) {
	u, err := url.Parse(dsn)
	if err != nil || u.Scheme == "" || u.Host == "" || u.Opaque != "" {
		return "", "", errors.New("alerts.Sentry needs a valid DSN")
	}
	var segments []string
	for _, s := range strings.Split(u.EscapedPath(), "/") {
		if s != "" {
			segments = append(segments, s)
		}
	}
	project := ""
	if len(segments) > 0 {
		project, segments = segments[len(segments)-1], segments[:len(segments)-1]
	}
	if u.User == nil || u.User.Username() == "" || !digits.MatchString(project) {
		return "", "", errors.New("alerts.Sentry needs a DSN like https://<key>@<host>/<project>")
	}
	prefix := ""
	if len(segments) > 0 {
		prefix = "/" + strings.Join(segments, "/")
	}
	return u.Scheme + "://" + hostOf(u) + prefix + "/api/" + project + "/envelope/", u.User.Username(), nil
}

// Sentry sends alerts to Sentry as events, one issue per job and alert
// type.
func Sentry(o SentryOptions) (cronwatch.Channel, error) {
	// A pasted credential often carries a stray space or newline, which a header would refuse or send.
	dsn := trimmed(o.DSN)
	if dsn == "" {
		return nil, errors.New("alerts.Sentry needs a DSN")
	}
	endpoint, publicKey, err := parseDSN(dsn)
	if err != nil {
		return nil, err
	}
	environment := o.Environment
	if environment == "" {
		environment = "production"
	}
	return &channel{name: "sentry", send: func(ctx context.Context, a cronwatch.Alert, _ cronwatch.ChannelContext) error {
		if a.Type == cronwatch.AlertRecovered && o.SkipRecovered {
			return nil
		}
		eventID := alertID(a)
		link := linkFor(o.Link, a)
		event := js.NewObject(
			"event_id", eventID,
			"timestamp", float64(a.At)/1000,
			"platform", "other",
			"level", severity(a.Type),
			"logger", "cronwatch",
			"transaction", a.Job,
			"environment", environment,
		)
		if o.Release != "" {
			event.Set("release", o.Release)
		}
		// The first line is the issue title.
		event.Set("logentry", js.NewObject("formatted", cut(js.WellFormed(a.Title+"\n\n"+a.Message), 8192)))
		event.Set("fingerprint", []any{"cronwatch", a.Job, string(a.Type)})
		event.Set("tags", js.NewObject("job", cut(js.WellFormed(a.Job), 199), "type", string(a.Type)))
		extra := &js.Object{}
		if t := triage(a); t != "" {
			extra.Set("triage", t)
		}
		if link != "" {
			extra.Set("link", link)
		}
		extra.Set("details", details(a))
		extra.Set("run", runSummary(a))
		event.Set("extra", extra)
		payload := js.Stringify(event)
		envelope := strings.Join([]string{
			js.Stringify(js.NewObject("event_id", eventID)),
			js.Stringify(js.NewObject("type", "event", "content_type", "application/json", "length", len(payload))),
			payload,
		}, "\n") + "\n"
		return send(ctx, o.HTTPClient, "Sentry", endpoint, []header{
			{Name: "content-type", Value: "application/x-sentry-envelope"},
			{Name: "x-sentry-auth", Value: "Sentry sentry_version=7, sentry_key=" + publicKey + ", sentry_client=cronwatch"},
		}, envelope, publicKey)
	}}, nil
}
