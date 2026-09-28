package alerts

// Resend. API reference: https://resend.com/docs/api-reference/emails/send-email
// POST https://api.resend.com/emails with a bearer API key.

import (
	"context"
	"errors"
	"net/http"

	cronwatch "cronwatch.dev/go"
	"cronwatch.dev/go/internal/js"
)

// ResendOptions configure Resend.
type ResendOptions struct {
	EmailOptions
	// APIKey is an API key from resend.com/api-keys, "re_...".
	APIKey string
	// HTTPClient sends the request; nil for Go's default transport. It is
	// used as a copy that never follows a redirect.
	HTTPClient *http.Client
}

const resendEndpoint = "https://api.resend.com/emails"

// Resend sends alerts as email through Resend.
func Resend(o ResendOptions) (cronwatch.Channel, error) {
	// A pasted credential often carries a stray space or newline, which a header would refuse or send.
	apiKey := trimmed(o.APIKey)
	if apiKey == "" {
		return nil, errors.New("alerts.Resend needs an APIKey")
	}
	to, err := recipients("Resend", o.EmailOptions)
	if err != nil {
		return nil, err
	}
	return &channel{name: "resend", send: func(ctx context.Context, a cronwatch.Alert, _ cronwatch.ChannelContext) error {
		m := composeEmail(a, o.EmailOptions, to)
		body := js.Stringify(js.NewObject("from", m.from, "to", m.to, "subject", m.subject, "text", m.text, "html", m.html))
		return send(ctx, o.HTTPClient, "Resend", resendEndpoint, []header{
			{Name: "content-type", Value: "application/json"},
			{Name: "authorization", Value: "Bearer " + apiKey},
			// The same alert sent twice within 24 hours is delivered once.
			{Name: "idempotency-key", Value: "cronwatch-" + alertID(a)},
		}, body, apiKey)
	}}, nil
}
