package alerts

// Replays conformance/channels.json, the requests the SDK's channels make
// (scripts/conformance.mjs drives them with a stub fetch): every request's
// URL, headers and body, byte for byte, for thirteen sample alerts and each
// channel's option sets; the error each gives for a refused request;
// Twilio's partial delivery; and the text cuts.

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"io"
	"math"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"testing"

	cronwatch "cronwatch.dev/go"
	"cronwatch.dev/go/internal/js"
	"cronwatch.dev/go/internal/post"
)

var bg = context.Background()

func fixture(t *testing.T, name string) *js.Object {
	t.Helper()
	data, err := os.ReadFile(filepath.Join("..", "..", "..", "conformance", name+".json"))
	if err != nil {
		t.Fatal(err)
	}
	v, err := js.Parse(string(data))
	if err != nil {
		t.Fatal(err)
	}
	return v.(*js.Object)
}

func field(o *js.Object, key string) any {
	if o == nil {
		return nil
	}
	v, _ := o.Get(key)
	return v
}

func text(o *js.Object, key string) string {
	s, _ := field(o, key).(string)
	return s
}

func objects(v any) []*js.Object {
	list, _ := v.([]any)
	out := make([]*js.Object, len(list))
	for i, e := range list {
		out[i], _ = e.(*js.Object)
	}
	return out
}

func strs(v any) []string {
	switch t := v.(type) {
	case string:
		return []string{t}
	case []any:
		out := make([]string, len(t))
		for i, e := range t {
			out[i], _ = e.(string)
		}
		return out
	}
	return nil
}

func alertOf(t *testing.T, v any) cronwatch.Alert {
	t.Helper()
	var a cronwatch.Alert
	if err := a.UnmarshalJSON([]byte(js.Stringify(v))); err != nil {
		t.Fatal(err)
	}
	return a
}

// expand is the fixture's recipe for long text: a string, or
// { parts: [[piece, times], ...] } joined.
func expand(spec any) string {
	if s, ok := spec.(string); ok {
		return s
	}
	var b strings.Builder
	parts, _ := field(spec.(*js.Object), "parts").([]any)
	for _, p := range parts {
		pair := p.([]any)
		b.WriteString(strings.Repeat(pair[0].(string), int(pair[1].(float64))))
	}
	return b.String()
}

// digest is the fixture's form of a text: itself up to 400 UTF-16 code
// units, else its length and the SHA-256 of its UTF-8.
func digest(s string) any {
	if js.Length16(s) <= 400 {
		return js.NewObject("text", s)
	}
	sum := sha256.Sum256([]byte(s))
	return js.NewObject("length", js.Length16(s), "sha256", hex.EncodeToString(sum[:]))
}

// captured is one request a channel made.
type captured struct {
	url    string
	header http.Header
	body   string
}

// recorder is a transport that keeps each request and answers each with
// the status and body answer gives.
type recorder struct {
	mu       sync.Mutex
	requests []captured
	answer   func(body string) (int, string)
}

func (r *recorder) RoundTrip(req *http.Request) (*http.Response, error) {
	data, _ := io.ReadAll(req.Body)
	r.mu.Lock()
	r.requests = append(r.requests, captured{req.URL.String(), req.Header.Clone(), string(data)})
	answer := r.answer
	r.mu.Unlock()
	status, body := 200, ""
	if answer != nil {
		status, body = answer(string(data))
	}
	return &http.Response{StatusCode: status, Body: io.NopCloser(strings.NewReader(body)), Header: http.Header{}, Request: req}, nil
}

func (r *recorder) reset(status int, body string) {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.requests = nil
	r.answer = func(string) (int, string) { return status, body }
}

func (r *recorder) taken() []captured {
	r.mu.Lock()
	defer r.mu.Unlock()
	return append([]captured(nil), r.requests...)
}

func testLink(a cronwatch.Alert) string { return "https://app.example/cronwatch/jobs/" + a.Job }

// build makes a channel from a fixture's options, as the script's
// materialize() does: `link: true` is the usual link, `now` a fixed clock.
func build(t *testing.T, name string, o *js.Object, client *http.Client) cronwatch.Channel {
	t.Helper()
	var link func(cronwatch.Alert) string
	if field(o, "link") == true {
		link = testLink
	}
	var now func() int64
	if n, ok := field(o, "now").(float64); ok {
		now = func() int64 { return int64(n) }
	}
	email := EmailOptions{From: text(o, "from"), To: strs(field(o, "to")), SubjectPrefix: text(o, "subjectPrefix"), Link: link}
	recovered, hasRecovered := field(o, "recovered").(bool)
	var ch cronwatch.Channel
	var err error
	switch name {
	case "slack":
		ch, err = Slack(SlackOptions{WebhookURL: text(o, "webhookUrl"), Link: link, HTTPClient: client})
	case "discord":
		ch, err = Discord(DiscordOptions{WebhookURL: text(o, "webhookUrl"), Link: link, HTTPClient: client})
	case "webhook":
		headers := map[string]string{}
		if h, ok := field(o, "headers").(*js.Object); ok {
			for _, k := range h.Keys() {
				headers[k] = text(h, k)
			}
		}
		ch, err = Webhook(WebhookOptions{URL: text(o, "url"), Secret: text(o, "secret"), Headers: headers, HTTPClient: client})
	case "resend":
		ch, err = Resend(ResendOptions{EmailOptions: email, APIKey: text(o, "apiKey"), HTTPClient: client})
	case "postmark":
		ch, err = Postmark(PostmarkOptions{EmailOptions: email, ServerToken: text(o, "serverToken"), MessageStream: text(o, "messageStream"), HTTPClient: client})
	case "sendgrid":
		ch, err = Sendgrid(SendgridOptions{EmailOptions: email, APIKey: text(o, "apiKey"), Region: text(o, "region"), HTTPClient: client})
	case "mailgun":
		ch, err = Mailgun(MailgunOptions{EmailOptions: email, APIKey: text(o, "apiKey"), Domain: text(o, "domain"), Region: text(o, "region"), HTTPClient: client})
	case "ses":
		ch, err = SES(SESOptions{EmailOptions: email, Region: text(o, "region"), AccessKeyID: text(o, "accessKeyId"), SecretAccessKey: text(o, "secretAccessKey"),
			SessionToken: text(o, "sessionToken"), ConfigurationSetName: text(o, "configurationSetName"), Now: now, HTTPClient: client})
	case "twilio":
		segments := 0
		if n, ok := field(o, "segments").(float64); ok {
			segments = int(n)
		}
		ch, err = Twilio(TwilioOptions{AccountSID: text(o, "accountSid"), AuthToken: text(o, "authToken"), APIKeySID: text(o, "apiKeySid"), APIKeySecret: text(o, "apiKeySecret"),
			From: text(o, "from"), MessagingServiceSID: text(o, "messagingServiceSid"), To: strs(field(o, "to")), Recovered: recovered, Segments: segments, Link: link, HTTPClient: client})
	case "sentry":
		ch, err = Sentry(SentryOptions{DSN: text(o, "dsn"), Environment: text(o, "environment"), Release: text(o, "release"), SkipRecovered: hasRecovered && !recovered, Link: link, HTTPClient: client})
	case "honeybadger":
		ch, err = Honeybadger(HoneybadgerOptions{APIKey: text(o, "apiKey"), Environment: text(o, "environment"), Endpoint: text(o, "endpoint"), Recovered: recovered, Link: link, HTTPClient: client})
	case "datadog":
		ch, err = Datadog(DatadogOptions{APIKey: text(o, "apiKey"), Site: text(o, "site"), Tags: strs(field(o, "tags")), Host: text(o, "host"), Link: link, HTTPClient: client})
	case "rollbar":
		ch, err = Rollbar(RollbarOptions{AccessToken: text(o, "accessToken"), Environment: text(o, "environment"), SkipRecovered: hasRecovered && !recovered, Link: link, HTTPClient: client})
	case "bugsnag":
		ch, err = Bugsnag(BugsnagOptions{APIKey: text(o, "apiKey"), ReleaseStage: text(o, "releaseStage"), Endpoint: text(o, "endpoint"), Recovered: recovered, Now: now, Link: link, HTTPClient: client})
	case "newrelic":
		account := text(o, "accountId")
		if n, ok := field(o, "accountId").(float64); ok {
			account = js.FormatNumber(n)
		}
		ch, err = NewRelic(NewRelicOptions{AccountID: account, APIKey: text(o, "apiKey"), Region: text(o, "region"), EventType: text(o, "eventType"), Link: link, HTTPClient: client})
	default:
		t.Fatalf("no channel %s", name)
	}
	if err != nil {
		t.Fatalf("%s: %v", name, err)
	}
	if ch.Name() != name {
		t.Fatalf("channel %s is named %s", name, ch.Name())
	}
	return ch
}

// sameRequest compares a captured request with the fixture's.
func sameRequest(t *testing.T, what string, got captured, want *js.Object) {
	t.Helper()
	if got.url != text(want, "url") {
		t.Errorf("%s: url %s, want %s", what, got.url, text(want, "url"))
	}
	headers, _ := field(want, "headers").(*js.Object)
	if len(got.header) != headers.Len() {
		t.Errorf("%s: headers %v, want %s", what, got.header, js.Stringify(headers))
	}
	for _, name := range headers.Keys() {
		if values := got.header.Values(name); len(values) != 1 || values[0] != text(headers, name) {
			t.Errorf("%s: header %s is %q, want %q", what, name, values, text(headers, name))
		}
	}
	if g, w := js.Stringify(digest(got.body)), js.Stringify(field(want, "body")); g != w {
		t.Errorf("%s: body %s, want %s\n%s", what, g, w, got.body)
	}
}

// numberOrder sorts a Twilio send's requests by the order of its numbers,
// since they are made at once.
func numberOrder(requests []captured, numbers []string) {
	index := func(c captured) int {
		values, _ := url.ParseQuery(c.body)
		for i, n := range numbers {
			if js.Trim(n) == values.Get("To") {
				return i
			}
		}
		return -1
	}
	sort.SliceStable(requests, func(i, j int) bool { return index(requests[i]) < index(requests[j]) })
}

func TestConformanceChannels(t *testing.T) {
	f := fixture(t, "channels")
	alerts := map[string]cronwatch.Alert{}
	var first cronwatch.Alert
	for i, c := range objects(field(f, "alerts")) {
		alerts[text(c, "name")] = alertOf(t, field(c, "alert"))
		if i == 0 {
			first = alerts[text(c, "name")]
		}
	}
	rec := &recorder{}
	client := &http.Client{Transport: rec}
	count := 0

	t.Run("sends", func(t *testing.T) {
		for _, c := range objects(field(f, "sends")) {
			o, _ := field(c, "options").(*js.Object)
			ch := build(t, text(c, "channel"), o, client)
			rec.reset(200, "")
			what := text(c, "channel") + " " + js.Stringify(o) + " " + text(c, "alert")
			if err := ch.Send(bg, alerts[text(c, "alert")], cronwatch.ChannelContext{}); err != nil {
				t.Fatalf("%s: %v", what, err)
			}
			got := rec.taken()
			if len(got) != 1 {
				t.Fatalf("%s: %d requests", what, len(got))
			}
			sameRequest(t, what, got[0], c)
			count++
		}
	})

	// The webhook's body in full for every alert, "schema":1 first, and its
	// signature.
	t.Run("webhookPayloads", func(t *testing.T) {
		cases := objects(field(f, "webhookPayloads"))
		if len(cases) == 0 {
			t.Fatal("channels.json has no webhookPayloads")
		}
		for _, c := range cases {
			ch, err := Webhook(WebhookOptions{URL: "https://hooks.example.com/x", Secret: text(c, "secret"), HTTPClient: client})
			if err != nil {
				t.Fatal(err)
			}
			rec.reset(200, "")
			what := "webhook " + text(c, "alert")
			if err := ch.Send(bg, alerts[text(c, "alert")], cronwatch.ChannelContext{}); err != nil {
				t.Fatalf("%s: %v", what, err)
			}
			got := rec.taken()
			if len(got) != 1 {
				t.Fatalf("%s: %d requests", what, len(got))
			}
			if got[0].body != text(c, "body") {
				t.Errorf("%s: body\n got %s\nwant %s", what, got[0].body, text(c, "body"))
			}
			if sig := got[0].header.Get("X-Cronwatch-Signature"); sig != text(c, "signature") {
				t.Errorf("%s: signature %q, want %q", what, sig, text(c, "signature"))
			}
			if sig := "sha256=" + Signature(text(c, "secret"), text(c, "body")); sig != text(c, "signature") {
				t.Errorf("%s: Signature gives %q, want %q", what, sig, text(c, "signature"))
			}
		}
	})

	t.Run("providerSends", func(t *testing.T) {
		for _, c := range objects(field(f, "providerSends")) {
			o, _ := field(c, "options").(*js.Object)
			ch := build(t, text(c, "channel"), o, client)
			rec.reset(200, "")
			what := text(c, "channel") + " " + js.Stringify(o) + " " + text(c, "alert")
			if err := ch.Send(bg, alerts[text(c, "alert")], cronwatch.ChannelContext{}); err != nil {
				t.Fatalf("%s: %v", what, err)
			}
			got := rec.taken()
			numberOrder(got, strs(field(o, "to")))
			want := objects(field(c, "requests"))
			if len(got) != len(want) {
				t.Fatalf("%s: %d requests, want %d", what, len(got), len(want))
			}
			for i := range want {
				sameRequest(t, what, got[i], want[i])
			}
			count++
		}
	})

	for _, key := range []string{"failures", "providerFailures"} {
		t.Run(key, func(t *testing.T) {
			for _, c := range objects(field(f, key)) {
				o, _ := field(c, "options").(*js.Object)
				ch := build(t, text(c, "channel"), o, client)
				rec.reset(int(field(c, "status").(float64)), text(c, "body"))
				what := text(c, "channel") + " " + js.Stringify(o)
				err := ch.Send(bg, first, cronwatch.ChannelContext{})
				want, _ := field(c, "error").(string)
				got := ""
				if err != nil {
					got = err.Error()
				}
				if got != want {
					t.Errorf("%s answered %v:\n got %q\nwant %q", what, field(c, "status"), got, want)
				}
				count++
			}
		})
	}

	t.Run("twilioPartial", func(t *testing.T) {
		partial, _ := field(f, "twilioPartial").(*js.Object)
		o, _ := field(partial, "options").(*js.Object)
		numbers := strs(field(o, "to"))
		for _, c := range objects(field(partial, "cases")) {
			statuses, _ := field(c, "statuses").([]any)
			rec.mu.Lock()
			rec.requests = nil
			rec.answer = func(body string) (int, string) {
				values, _ := url.ParseQuery(body)
				to := values.Get("To")
				for i, n := range numbers {
					if n == to {
						status := int(statuses[i].(float64))
						if status < 400 {
							return status, "{}"
						}
						return status, `{"message":"refused ` + to + ` with tw-secret"}`
					}
				}
				return 500, ""
			}
			rec.mu.Unlock()
			var mu sync.Mutex
			reported := []any{}
			ch := build(t, "twilio", o, client)
			err := ch.Send(bg, first, cronwatch.NewChannelContext(func(e error) {
				mu.Lock()
				defer mu.Unlock()
				reported = append(reported, e.Error())
			}))
			var gotErr any
			if err != nil {
				gotErr = err.Error()
			}
			if g, w := js.Stringify(gotErr), js.Stringify(field(c, "error")); g != w {
				t.Errorf("%v: error %s, want %s", statuses, g, w)
			}
			if g, w := js.Stringify(reported), js.Stringify(field(c, "reported")); g != w {
				t.Errorf("%v: reported %s, want %s", statuses, g, w)
			}
			got := rec.taken()
			numberOrder(got, numbers)
			for i, want := range objects(field(c, "requests")) {
				values, _ := url.ParseQuery(got[i].body)
				if got[i].url != text(want, "url") || values.Get("To") != text(want, "to") {
					t.Errorf("%v: request %d to %s %s", statuses, i, got[i].url, values.Get("To"))
				}
			}
			count++
		}
	})

	t.Run("textCuts", func(t *testing.T) {
		cuts, _ := field(f, "textCuts").(*js.Object)
		for _, c := range objects(field(cuts, "errorBodies")) {
			var secrets []string
			for _, s := range field(c, "secrets").([]any) {
				if str, ok := s.(string); ok {
					secrets = append(secrets, str)
				}
			}
			if got := post.ErrorBody(text(c, "text"), secrets...); got != text(c, "body") {
				t.Errorf("errorBody(%q):\n got %q\nwant %q", text(c, "text"), got, text(c, "body"))
			}
			count++
		}
		for _, c := range objects(field(cuts, "subjects")) {
			a := first
			a.Title = text(c, "title")
			m := composeEmail(a, EmailOptions{From: "a@example.com", To: []string{"b@example.com"}, SubjectPrefix: text(c, "subjectPrefix")}, []string{"b@example.com"})
			if m.subject != text(c, "subject") {
				t.Errorf("subject of %q: got %q, want %q", a.Title, m.subject, text(c, "subject"))
			}
			count++
		}
		for _, c := range objects(field(cuts, "smsSegments")) {
			if got, want := smsSegments(text(c, "text")), int(field(c, "segments").(float64)); got != want {
				t.Errorf("smsSegments(%q) = %d, want %d", text(c, "text"), got, want)
			}
			count++
		}
		long := first
		long.Title = "nightly failed"
		long.Message = strings.Repeat(strings.Repeat("a", 152)+"{\n", 12)
		long.Triage = nil
		for _, c := range objects(field(cuts, "smsBodies")) {
			segments := math.NaN()
			if n, ok := field(c, "segments").(float64); ok {
				segments = n
			}
			link := "https://app.example/j"
			if text(c, "link") == "long" {
				link = "https://app.example/" + strings.Repeat("p", 2000)
			}
			if g, w := js.Stringify(digest(smsBody(long, link, segments))), js.Stringify(field(c, "body")); g != w {
				t.Errorf("smsBody with %v segments: %s, want %s", field(c, "segments"), g, w)
			}
			count++
		}
		descriptions := objects(field(cuts, "discordDescriptions"))
		if len(descriptions) == 0 {
			t.Error("no discordDescriptions cases")
		}
		for i, c := range descriptions {
			a := first
			a.Message = expand(field(c, "message"))
			a.Triage, a.TriageTried = nil, false
			switch v := field(c, "triage").(type) {
			case nil:
			case string:
				a.Triage, a.TriageTried = &v, true
			default:
				s := expand(v)
				a.Triage, a.TriageTried = &s, true
			}
			if g, w := js.Stringify(digest(embedDescription(a))), js.Stringify(field(c, "description")); g != w {
				t.Errorf("discordDescriptions %d: %s, want %s", i, g, w)
			}
			count++
		}
	})
	t.Logf("%d cases replayed", count)
}

// The HMAC-SHA256 test vector every port checks its signature helper with.
func TestSignatureKnownVector(t *testing.T) {
	const want = "f7bc83f430538424b13298e6aa6fb143ef4d59a14946175997479dbc2d1a3cd8"
	if got := Signature("key", "The quick brown fox jumps over the lazy dog"); got != want {
		t.Errorf("Signature: %s, want %s", got, want)
	}
}
