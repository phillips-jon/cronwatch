package alerts

// What the channels share (alerts/shared.ts): severity, the stable alert
// id, the run summary trackers attach, the plain text every channel reads,
// and the encodings the requests use. The POST itself is internal/post,
// which Claude triage uses too.

import (
	"context"
	"crypto/hmac"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"net/http"
	"strings"

	cronwatch "cronwatch.dev/go"
	"cronwatch.dev/go/internal/js"
	"cronwatch.dev/go/internal/post"
)

// header is one request header, in the SDK's order.
type header = post.Header

// severity is the level for trackers that have levels. Recovered is
// informational.
func severity(t cronwatch.AlertType) string {
	switch t {
	case cronwatch.AlertRecovered:
		return "info"
	case cronwatch.AlertSlow, cronwatch.AlertOverBudget:
		return "warning"
	}
	return "error"
}

func sha256Hex(text string) string {
	sum := sha256.Sum256([]byte(js.WellFormed(text)))
	return hex.EncodeToString(sum[:])
}

func hmacSHA256(key []byte, data string) []byte {
	m := hmac.New(sha256.New, key)
	m.Write([]byte(data))
	return m.Sum(nil)
}

// alertID is a stable 32 hex character id for one alert: the same job,
// type and time always give the same id, so a provider that deduplicates on
// it drops a resend of an alert it already took.
func alertID(a cronwatch.Alert) string {
	return sha256Hex(a.Job + "\n" + string(a.Type) + "\n" + js.FormatNumber(float64(a.At)))[:32]
}

// asUUID is the same id laid out as a UUID, for APIs that ask for one.
func asUUID(id string) string {
	return id[0:8] + "-" + id[8:12] + "-" + id[12:16] + "-" + id[16:20] + "-" + id[20:32]
}

// runSummary is the run fields worth attaching to a tracker event, or nil.
// A start before the year 1 or after 9999 is null.
func runSummary(a cronwatch.Alert) any {
	r := a.Run
	if r == nil {
		return nil
	}
	var duration any
	if r.DurationMs != nil {
		duration = *r.DurationMs
	}
	var started any
	if iso, ok := js.ISOTime(r.StartedAt); ok {
		started = iso
	}
	return js.NewObject("id", r.ID, "status", string(r.Status), "startedAt", started, "durationMs", duration, "trigger", r.Trigger)
}

// details is the alert's details as the SDK writes them.
func details(a cronwatch.Alert) any {
	o, _ := js.ValueOf(a).(*js.Object)
	v, _ := o.Get("details")
	return v
}

// triage is the alert's diagnosis, "" for none (JavaScript reads null and
// "" alike as absent).
func triage(a cronwatch.Alert) string {
	if a.Triage == nil {
		return ""
	}
	return *a.Triage
}

// linkFor is the link option's answer for this alert, "" for none.
func linkFor(link func(cronwatch.Alert) string, a cronwatch.Alert) string {
	if link == nil {
		return ""
	}
	return link(a)
}

// plainText is the title, message, triage and link as one plain text
// block, the way every channel reads.
func plainText(a cronwatch.Alert, link string) string {
	lines := []string{a.Title, "", a.Message}
	if t := triage(a); t != "" {
		lines = append(lines, "", "Triage: "+t)
	}
	if link != "" {
		lines = append(lines, "", "Open: "+link)
	}
	return strings.Join(lines, "\n")
}

// cut is at most max UTF-16 code units, never half a surrogate pair.
func cut(text string, max int) string { return post.Cut(text, max) }

// trimmed is a credential with the spaces and newlines a paste leaves
// around it taken off.
func trimmed(value string) string { return js.Trim(value) }

func basicAuth(user, password string) string {
	return "Basic " + base64.StdEncoding.EncodeToString([]byte(js.WellFormed(user+":"+password)))
}

// encodeURIComponent is JavaScript's encodeURIComponent.
func encodeURIComponent(text string) string {
	return percent(text, "-_.!~*'()", false)
}

// form is URLSearchParams#toString for these pairs:
// application/x-www-form-urlencoded, a space as +.
func form(pairs ...[2]string) string {
	parts := make([]string, len(pairs))
	for i, p := range pairs {
		parts[i] = percent(p[0], "*-._", true) + "=" + percent(p[1], "*-._", true)
	}
	return strings.Join(parts, "&")
}

func percent(text, safe string, plus bool) string {
	const digits = "0123456789ABCDEF"
	var b strings.Builder
	for _, c := range []byte(js.WellFormed(text)) {
		switch {
		case c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c >= '0' && c <= '9' || strings.IndexByte(safe, c) >= 0:
			b.WriteByte(c)
		case c == ' ' && plus:
			b.WriteByte('+')
		default:
			b.WriteByte('%')
			b.WriteByte(digits[c>>4])
			b.WriteByte(digits[c&0xf])
		}
	}
	return b.String()
}

// send posts a JSON or form body and fails on an answer outside 2xx.
func send(ctx context.Context, client *http.Client, provider, url string, headers []header, body string, secrets ...string) error {
	_, err := post.Post(ctx, client, provider, url, headers, body, secrets...)
	return err
}

// channel is a Channel made of a name and a send function.
type channel struct {
	name string
	send func(ctx context.Context, a cronwatch.Alert, cc cronwatch.ChannelContext) error
}

func (c *channel) Name() string { return c.name }

func (c *channel) Send(ctx context.Context, a cronwatch.Alert, cc cronwatch.ChannelContext) error {
	return c.send(ctx, a, cc)
}
