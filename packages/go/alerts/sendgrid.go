package alerts

// SendGrid. API reference: https://www.twilio.com/docs/sendgrid/api-reference/mail-send/mail-send
// POST https://api.sendgrid.com/v3/mail/send (api.eu.sendgrid.com for EU
// subusers) with a bearer API key. Answers 202.

import (
	"context"
	"errors"
	"net/http"

	cronwatch "cronwatch.dev/go"
	"cronwatch.dev/go/internal/js"
)

// SendgridOptions configure Sendgrid.
type SendgridOptions struct {
	EmailOptions
	// APIKey is an API key with Mail Send access, "SG...".
	APIKey string
	// Region is "eu" for an EU regional subuser. Default "us".
	Region string
	// HTTPClient sends the request; nil for Go's default transport. It is
	// used as a copy that never follows a redirect.
	HTTPClient *http.Client
}

// Sendgrid sends alerts as email through SendGrid.
func Sendgrid(o SendgridOptions) (cronwatch.Channel, error) {
	// A pasted credential often carries a stray space or newline, which a header would refuse or send.
	apiKey := trimmed(o.APIKey)
	if apiKey == "" {
		return nil, errors.New("alerts.Sendgrid needs an APIKey")
	}
	to, err := recipients("Sendgrid", o.EmailOptions)
	if err != nil {
		return nil, err
	}
	url := "https://api.sendgrid.com/v3/mail/send"
	if o.Region == "eu" {
		url = "https://api.eu.sendgrid.com/v3/mail/send"
	}
	return &channel{name: "sendgrid", send: func(ctx context.Context, a cronwatch.Alert, _ cronwatch.ChannelContext) error {
		m := composeEmail(a, o.EmailOptions, to)
		list := make([]any, len(m.to))
		for i, t := range m.to {
			list[i] = parseAddress(t).jsValue()
		}
		body := js.Stringify(js.NewObject(
			"personalizations", []any{js.NewObject("to", list)},
			"from", parseAddress(m.from).jsValue(),
			"subject", m.subject,
			// text/plain must come before text/html.
			"content", []any{
				js.NewObject("type", "text/plain", "value", m.text),
				js.NewObject("type", "text/html", "value", m.html),
			},
			"categories", []any{"cronwatch"},
		))
		return send(ctx, o.HTTPClient, "SendGrid", url, []header{
			{Name: "content-type", Value: "application/json"},
			{Name: "authorization", Value: "Bearer " + apiKey},
		}, body, apiKey)
	}}, nil
}
