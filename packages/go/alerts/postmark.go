package alerts

// Postmark. API reference: https://postmarkapp.com/developer/api/email-api
// POST https://api.postmarkapp.com/email with X-Postmark-Server-Token.

import (
	"context"
	"errors"
	"net/http"
	"strings"

	cronwatch "cronwatch.dev/go"
	"cronwatch.dev/go/internal/js"
)

// PostmarkOptions configure Postmark.
type PostmarkOptions struct {
	EmailOptions
	// ServerToken is a server API token, from the server's API Tokens tab.
	ServerToken string
	// MessageStream is the message stream. Default "outbound", the
	// transactional stream.
	MessageStream string
	// HTTPClient sends the request; nil for Go's default transport. It is
	// used as a copy that never follows a redirect.
	HTTPClient *http.Client
}

const postmarkEndpoint = "https://api.postmarkapp.com/email"

// Postmark sends alerts as email through Postmark.
func Postmark(o PostmarkOptions) (cronwatch.Channel, error) {
	// A pasted credential often carries a stray space or newline, which a header would refuse or send.
	token := trimmed(o.ServerToken)
	if token == "" {
		return nil, errors.New("alerts.Postmark needs a ServerToken")
	}
	to, err := recipients("Postmark", o.EmailOptions)
	if err != nil {
		return nil, err
	}
	stream := o.MessageStream
	if stream == "" {
		stream = "outbound"
	}
	return &channel{name: "postmark", send: func(ctx context.Context, a cronwatch.Alert, _ cronwatch.ChannelContext) error {
		m := composeEmail(a, o.EmailOptions, to)
		body := js.Stringify(js.NewObject(
			"From", m.from, "To", strings.Join(m.to, ", "), "Subject", m.subject, "TextBody", m.text, "HtmlBody", m.html,
			"MessageStream", stream, "Tag", "cronwatch",
		))
		return send(ctx, o.HTTPClient, "Postmark", postmarkEndpoint, []header{
			{Name: "content-type", Value: "application/json"},
			{Name: "accept", Value: "application/json"},
			{Name: "x-postmark-server-token", Value: token},
		}, body, token)
	}}, nil
}
