package alerts

import (
	"context"
	"encoding/hex"
	"errors"
	"fmt"
	"net/http"
	"sort"

	cronwatch "cronwatch.dev/go"
	"cronwatch.dev/go/internal/js"
	"cronwatch.dev/go/internal/post"
)

// WebhookOptions configure Webhook.
type WebhookOptions struct {
	// URL is where the alert is posted. Errors name only its origin, since
	// a webhook URL's path or query is often the credential.
	URL string
	// Headers are extra request headers, an Authorization header say.
	// Values are trimmed of the spaces and newlines a paste leaves.
	Headers map[string]string
	// Secret, when set, signs each request: X-CronWatch-Signature:
	// sha256=<hex>, the HMAC-SHA256 of the raw body with this secret, so
	// the receiver can verify it (see Signature).
	Secret string
	// HTTPClient sends the request; nil for Go's default transport. It is
	// used as a copy that never follows a redirect.
	HTTPClient *http.Client
}

// Webhook posts each alert as JSON to any URL. The body is the Alert as
// the SDK writes it: {type, run, details, job, definition, title, message,
// at, triage}. A redirect is an error: point the URL at where the receiver
// really is.
func Webhook(o WebhookOptions) (cronwatch.Channel, error) {
	if o.URL == "" {
		return nil, errors.New("alerts.Webhook needs a URL")
	}
	names := make([]string, 0, len(o.Headers))
	for name := range o.Headers {
		names = append(names, name)
	}
	sort.Strings(names)
	return &channel{name: "webhook", send: func(ctx context.Context, a cronwatch.Alert, _ cronwatch.ChannelContext) error {
		body := js.Stringify(a)
		headers := []header{{Name: "content-type", Value: "application/json"}, {Name: "user-agent", Value: "cronwatch"}}
		for _, name := range names {
			// A pasted Authorization value often carries a stray space or newline, which fetch would refuse.
			headers = assign(headers, name, js.Trim(o.Headers[name]))
		}
		if o.Secret != "" {
			headers = assign(headers, "x-cronwatch-signature", "sha256="+Signature(o.Secret, body))
		}
		// A redirect is refused, not followed: the headers (and the signature) would go with it.
		resp, err := post.Do(ctx, o.HTTPClient, o.URL, headers, body)
		if err != nil {
			return err
		}
		if !resp.OK() {
			// Only the origin: a webhook URL's path or query often is the credential.
			return fmt.Errorf("%s %s answered %d", "Webhook", post.Origin(o.URL), resp.Status)
		}
		return nil
	}}, nil
}

// assign sets a header as a JavaScript object's key is set: an exact name
// already there takes the new value in its place, a new one goes last.
func assign(headers []header, name, value string) []header {
	for i, h := range headers {
		if h.Name == name {
			headers[i].Value = value
			return headers
		}
	}
	return append(headers, header{Name: name, Value: value})
}

// Signature is the webhook's signature of a body: the HMAC-SHA256 of the
// body with the secret, as lowercase hex. The request carries it as
// X-CronWatch-Signature: sha256=<Signature>.
func Signature(secret, body string) string {
	return hex.EncodeToString(hmacSHA256([]byte(js.WellFormed(secret)), js.WellFormed(body)))
}
