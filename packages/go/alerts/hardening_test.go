package alerts

// The channels' hardening, as the SDK's channels-hardening.test.ts and the
// other ports' tests have it, against real HTTP servers where it matters:
// redirects refused, one deadline, bodies capped, only the origin in an
// error, URLs and headers checked, credentials trimmed and cut out of
// quoted answers, TLS verified, Twilio's partial delivery.

import (
	"bytes"
	"compress/gzip"
	"context"
	"encoding/base64"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"net/url"
	"regexp"
	"strings"
	"sync"
	"testing"
	"time"

	cronwatch "cronwatch.dev/go"
	"cronwatch.dev/go/internal/js"
	"cronwatch.dev/go/internal/post"
	"cronwatch.dev/go/storetest"
)

// sample is the channels fixture's first alert, a failure.
func sample(t *testing.T) cronwatch.Alert {
	t.Helper()
	return alertOf(t, field(objects(field(fixture(t, "channels"), "alerts"))[0], "alert"))
}

// rewrite is a transport that sends every request to target instead, as
// the SDK's test points fetch at a local server.
type rewrite struct{ target *url.URL }

func (r rewrite) RoundTrip(req *http.Request) (*http.Response, error) {
	out := req.Clone(req.Context())
	out.URL.Scheme, out.URL.Host, out.Host = r.target.Scheme, r.target.Host, ""
	return http.DefaultTransport.RoundTrip(out)
}

func to(server *httptest.Server) *http.Client {
	u, _ := url.Parse(server.URL)
	return &http.Client{Transport: rewrite{u}}
}

// every is one of each channel, posting through client.
func every(t *testing.T, client *http.Client, webhookURL string) []cronwatch.Channel {
	t.Helper()
	email := EmailOptions{From: "a@b.c", To: []string{"d@e.f"}}
	var out []cronwatch.Channel
	add := func(ch cronwatch.Channel, err error) {
		t.Helper()
		if err != nil {
			t.Fatal(err)
		}
		out = append(out, ch)
	}
	add(Datadog(DatadogOptions{APIKey: "dd-secret-key-123", HTTPClient: client}))
	add(Resend(ResendOptions{EmailOptions: email, APIKey: "re_secret", HTTPClient: client}))
	add(Postmark(PostmarkOptions{EmailOptions: email, ServerToken: "pm-secret", HTTPClient: client}))
	add(Sendgrid(SendgridOptions{EmailOptions: email, APIKey: "SG.secret", HTTPClient: client}))
	add(Mailgun(MailgunOptions{EmailOptions: email, APIKey: "key-secret", Domain: "mg.example.com", HTTPClient: client}))
	add(SES(SESOptions{EmailOptions: email, Region: "us-east-1", AccessKeyID: "AKIDEXAMPLE", SecretAccessKey: "sekret-sekret", HTTPClient: client}))
	add(Twilio(TwilioOptions{AccountSID: "AC1", AuthToken: "tw-secret", From: "+1", To: []string{"+2"}, HTTPClient: client}))
	add(Sentry(SentryOptions{DSN: "https://pubkey@o1.ingest.sentry.io/42", HTTPClient: client}))
	add(Honeybadger(HoneybadgerOptions{APIKey: "hb-secret", HTTPClient: client}))
	add(Rollbar(RollbarOptions{AccessToken: "rb-secret", HTTPClient: client}))
	add(Bugsnag(BugsnagOptions{APIKey: "bs-secret", HTTPClient: client}))
	add(NewRelic(NewRelicOptions{AccountID: "1", APIKey: "nr-secret", HTTPClient: client}))
	add(Webhook(WebhookOptions{URL: webhookURL, Headers: map[string]string{"authorization": "Bearer wh-secret"}, Secret: "s", HTTPClient: client}))
	add(Slack(SlackOptions{WebhookURL: webhookURL, HTTPClient: client}))
	add(Discord(DiscordOptions{WebhookURL: webhookURL, HTTPClient: client}))
	return out
}

func TestEveryChannelRefusesToFollowARedirect(t *testing.T) {
	var mu sync.Mutex
	var seen []string
	evil := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		mu.Lock()
		seen = append(seen, r.Header.Get("Authorization"))
		mu.Unlock()
		w.WriteHeader(202)
	}))
	defer evil.Close()
	provider := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		http.Redirect(w, r, evil.URL+"/steal", http.StatusTemporaryRedirect)
	}))
	defer provider.Close()
	// Even a client that would follow redirects is used as one that does not.
	client := to(provider)
	client.CheckRedirect = func(*http.Request, []*http.Request) error { return nil }
	for _, ch := range every(t, client, provider.URL+"/in") {
		err := ch.Send(bg, sample(t), cronwatch.ChannelContext{})
		if err == nil || !strings.Contains(err.Error(), "answered 307") {
			t.Errorf("%s followed the redirect or failed otherwise: %v", ch.Name(), err)
		}
	}
	mu.Lock()
	defer mu.Unlock()
	if len(seen) > 0 {
		t.Fatalf("the other origin was reached: %v", seen)
	}
}

func TestOneDeadlineForTheWholeRequest(t *testing.T) {
	saved := post.Timeout
	post.Timeout = 300 * time.Millisecond
	defer func() { post.Timeout = saved }()
	release := make(chan struct{})
	hang := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		io.Copy(io.Discard, r.Body)
		select {
		case <-release:
		case <-r.Context().Done():
		}
	}))
	defer hang.Close()
	defer close(release)
	ch, _ := Slack(SlackOptions{WebhookURL: hang.URL + "/T/B/secret"})
	started := time.Now()
	err := ch.Send(bg, sample(t), cronwatch.ChannelContext{})
	if !errors.Is(err, post.ErrTimeout) || err.Error() != "The operation was aborted due to timeout" {
		t.Fatalf("got %v", err)
	}
	// And Go's own: a deadline passed (the audit).
	if !errors.Is(err, context.DeadlineExceeded) {
		t.Fatalf("not a context.DeadlineExceeded: %v", err)
	}
	if took := time.Since(started); took > 3*time.Second {
		t.Fatalf("took %v", took)
	}

	// An answer whose body is still arriving at the deadline is the answer with no body.
	drip := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(500)
		for i := 0; i < 100; i++ {
			if _, err := w.Write([]byte("x")); err != nil {
				return
			}
			w.(http.Flusher).Flush()
			select {
			case <-time.After(50 * time.Millisecond):
			case <-r.Context().Done():
				return
			}
		}
	}))
	defer drip.Close()
	rb, _ := Rollbar(RollbarOptions{AccessToken: "rb-secret", HTTPClient: to(drip)})
	if err := rb.Send(bg, sample(t), cronwatch.ChannelContext{}); err == nil || err.Error() != "Rollbar https://api.rollbar.com answered 500" {
		t.Fatalf("got %v", err)
	}

	// The caller's context ending ends the request too.
	ctx, cancel := context.WithCancel(bg)
	cancel()
	if err := ch.Send(ctx, sample(t), cronwatch.ChannelContext{}); !errors.Is(err, context.Canceled) {
		t.Fatalf("got %v", err)
	}
}

func TestAnAnswerIsReadToOneMebibyteAtMost(t *testing.T) {
	// 64 MiB of zeros, gzipped: the transport decodes it, and only the first MiB is read.
	var zipped bytes.Buffer
	z := gzip.NewWriter(&zipped)
	chunk := make([]byte, 1<<20)
	for i := 0; i < 64; i++ {
		z.Write(chunk)
	}
	z.Close()
	bomb := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Encoding", "gzip")
		w.WriteHeader(500)
		w.Write(zipped.Bytes())
	}))
	defer bomb.Close()
	resp, err := post.Do(bg, nil, bomb.URL, nil, "{}")
	if err != nil || resp.Status != 500 || len(resp.Body) != post.MaxBody {
		t.Fatalf("status %d, %d bytes, %v", resp.Status, len(resp.Body), err)
	}
	rb, _ := Rollbar(RollbarOptions{AccessToken: "rb-secret", HTTPClient: to(bomb)})
	err = rb.Send(bg, sample(t), cronwatch.ChannelContext{})
	if err == nil || js.Length16(err.Error()) > len("Rollbar https://api.rollbar.com answered 500: ")+200 {
		t.Fatalf("got %v", err)
	}
}

func TestAURLThatCannotBePostedToIsRefusedWithoutQuotingIt(t *testing.T) {
	rec := &recorder{}
	client := &http.Client{Transport: rec}
	secretPath := strings.Join([]string{"services", "T0", "B0", "not" + "areal" + "secret"}, "/")
	cases := map[string]string{
		"hooks.example.com/" + secretPath:                 "this URL",
		"ftp://hooks.example.com/" + secretPath:           "ftp:",
		"https://hooks.example.com/" + secretPath + " x":  "this URL",
		"https://user:pw@hooks.example.com/" + secretPath: "this URL",
		"javascript:alert(1)":                             "this URL",
		"":                                                "",
	}
	for raw, shown := range cases {
		if raw == "" {
			continue
		}
		slack, _ := Slack(SlackOptions{WebhookURL: raw, HTTPClient: client})
		discord, _ := Discord(DiscordOptions{WebhookURL: raw, HTTPClient: client})
		webhook, _ := Webhook(WebhookOptions{URL: raw, HTTPClient: client})
		for _, ch := range []cronwatch.Channel{slack, discord, webhook} {
			err := ch.Send(bg, sample(t), cronwatch.ChannelContext{})
			if err == nil || err.Error() != "only http and https URLs can be posted to, not "+shown {
				t.Errorf("%s %q: %v", ch.Name(), raw, err)
			}
		}
	}
	if len(rec.taken()) != 0 {
		t.Fatal("something was sent")
	}
	// A stray newline or space around a pasted URL, or a tab inside it, is dropped, as fetch drops it.
	slack, _ := Slack(SlackOptions{WebhookURL: "  https://hooks.exa\tmple.com/" + secretPath + "\n", HTTPClient: client})
	if err := slack.Send(bg, sample(t), cronwatch.ChannelContext{}); err != nil {
		t.Fatal(err)
	}
	if got := rec.taken()[0].url; got != "https://hooks.example.com/"+secretPath {
		t.Fatalf("posted to %q", got)
	}
	for raw, want := range map[string]string{
		"https://hooks.example.com/" + secretPath + "\n": "https://hooks.example.com",
		"HTTPS://Hooks.Example.com:443/x":                "https://hooks.example.com",
		"http://hooks.example.com:8080/x":                "http://hooks.example.com:8080",
		"not a url":                                      "(invalid URL)",
	} {
		if got := post.Origin(raw); got != want {
			t.Errorf("Origin(%q) = %q, want %q", raw, got, want)
		}
	}
}

func TestAnErrorNamesOnlyTheOrigin(t *testing.T) {
	// Nothing listens on port 1: the transport's own error is kept, the URL's path is not.
	secret := "not" + "areal" + "secret"
	ch, _ := Webhook(WebhookOptions{URL: "http://127.0.0.1:1/hooks/" + secret + "?token=" + secret})
	err := ch.Send(bg, sample(t), cronwatch.ChannelContext{})
	if err == nil || strings.Contains(err.Error(), secret) || !strings.HasPrefix(err.Error(), "http://127.0.0.1:1: ") {
		t.Fatalf("got %v", err)
	}
	refuse := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { w.WriteHeader(403) }))
	defer refuse.Close()
	ch, _ = Webhook(WebhookOptions{URL: refuse.URL + "/services/" + secret + "?key=" + secret})
	if err := ch.Send(bg, sample(t), cronwatch.ChannelContext{}); err == nil || err.Error() != "Webhook "+refuse.URL+" answered 403" {
		t.Fatalf("got %v", err)
	}
}

// quoting is an app's transport that fails the way a wrapper around a
// client of its own does: a *url.Error inside, or its own text with the URL.
type quoting struct{ nested bool }

func (q quoting) RoundTrip(r *http.Request) (*http.Response, error) {
	if q.nested {
		return nil, &url.Error{Op: "Post", URL: r.URL.String(), Err: errors.New("inner")}
	}
	return nil, errors.New("giving up on " + r.URL.String() + " after 3 tries")
}

// The audit: only the outer *url.Error was taken apart, so a transport
// that quoted the URL itself put the webhook's path and query in the error.
func TestAnErrorNamesOnlyTheOriginWhateverTheTransportQuotes(t *testing.T) {
	secret := "not" + "areal" + "secret"
	for _, nested := range []bool{true, false} {
		ch, _ := Webhook(WebhookOptions{URL: "https://hooks.example.com/services/" + secret + "?token=" + secret, HTTPClient: &http.Client{Transport: quoting{nested}}})
		err := ch.Send(bg, sample(t), cronwatch.ChannelContext{})
		if err == nil || strings.Contains(err.Error(), secret) || strings.Contains(err.Error(), "/services") || !strings.HasPrefix(err.Error(), "https://hooks.example.com: ") {
			t.Fatalf("nested %v: %v", nested, err)
		}
	}
}

// panicking is an app's transport that panics.
type panicking struct{}

func (panicking) RoundTrip(*http.Request) (*http.Response, error) { panic("transport broke") }

// The audit: Twilio sends each number in a goroutine of its own, where a
// panic ended the process; it is that number's failure instead.
func TestAPanicWhileTextingIsAFailureNotACrash(t *testing.T) {
	sms, _ := Twilio(TwilioOptions{AccountSID: "AC1", AuthToken: "tok", From: "+15551112222", To: []string{"+15553334444", "+15553335555"}, HTTPClient: &http.Client{Transport: panicking{}}})
	err := sms.Send(bg, sample(t), cronwatch.ChannelContext{})
	if err == nil || !strings.Contains(err.Error(), "panicked: transport broke") {
		t.Fatalf("got %v", err)
	}
}

func TestTLSIsVerified(t *testing.T) {
	server := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {}))
	defer server.Close()
	ch, _ := Slack(SlackOptions{WebhookURL: server.URL + "/T/B/secret"})
	err := ch.Send(bg, sample(t), cronwatch.ChannelContext{})
	if err == nil || !strings.Contains(err.Error(), "certificate") {
		t.Fatalf("a certificate no one trusts was accepted: %v", err)
	}
	// A client that trusts the server's certificate posts to it.
	ch, _ = Slack(SlackOptions{WebhookURL: server.URL + "/T/B/secret", HTTPClient: server.Client()})
	if err := ch.Send(bg, sample(t), cronwatch.ChannelContext{}); err != nil {
		t.Fatal(err)
	}
}

func TestHeadersAreCheckedAndCredentialsTrimmed(t *testing.T) {
	rec := &recorder{}
	client := &http.Client{Transport: rec}
	for _, value := range []string{"Bearer a\r\nX-Evil: 1", "Bearer a\nb", "a\x00b"} {
		ch, _ := Webhook(WebhookOptions{URL: "https://hooks.example.com/in", Headers: map[string]string{"authorization": value}, HTTPClient: client})
		err := ch.Send(bg, sample(t), cronwatch.ChannelContext{})
		if err == nil || err.Error() != "the authorization header's value may not contain a line break" {
			t.Errorf("%q: %v", value, err)
		}
	}
	ch, _ := Webhook(WebhookOptions{URL: "https://hooks.example.com/in", Headers: map[string]string{"bad name": "x"}, HTTPClient: client})
	if err := ch.Send(bg, sample(t), cronwatch.ChannelContext{}); err == nil || !strings.HasPrefix(err.Error(), "a header name must be a token") {
		t.Errorf("got %v", err)
	}
	if len(rec.taken()) != 0 {
		t.Fatal("a request with a bad header was sent")
	}

	email := EmailOptions{From: "a@b.c", To: []string{"d@e.f"}}
	var channels []cronwatch.Channel
	add := func(c cronwatch.Channel, err error) {
		t.Helper()
		if err != nil {
			t.Fatal(err)
		}
		channels = append(channels, c)
	}
	add(Resend(ResendOptions{EmailOptions: email, APIKey: " re_secret\n", HTTPClient: client}))
	add(Postmark(PostmarkOptions{EmailOptions: email, ServerToken: "\tpm-secret ", HTTPClient: client}))
	add(Sendgrid(SendgridOptions{EmailOptions: email, APIKey: "SG.secret\n", HTTPClient: client}))
	add(Mailgun(MailgunOptions{EmailOptions: email, APIKey: " key-secret ", Domain: "mg.example.com", HTTPClient: client}))
	add(Datadog(DatadogOptions{APIKey: "dd-secret\n", HTTPClient: client}))
	add(Honeybadger(HoneybadgerOptions{APIKey: " hb-secret", HTTPClient: client}))
	add(Rollbar(RollbarOptions{AccessToken: "rb-secret \n", HTTPClient: client}))
	add(Bugsnag(BugsnagOptions{APIKey: "bs-secret\n", HTTPClient: client}))
	add(NewRelic(NewRelicOptions{AccountID: "1", APIKey: " nr-secret", HTTPClient: client}))
	add(Sentry(SentryOptions{DSN: " https://pubkey@o1.ingest.sentry.io/42\n", HTTPClient: client}))
	add(Twilio(TwilioOptions{AccountSID: " AC1 ", AuthToken: "tok\n", From: "+1", To: []string{"+2"}, HTTPClient: client}))
	add(SES(SESOptions{EmailOptions: email, Region: "us-east-1", AccessKeyID: " AKIDEXAMPLE", SecretAccessKey: "sekret\n", HTTPClient: client}))
	add(Webhook(WebhookOptions{URL: "https://hooks.example.com/in", Headers: map[string]string{"authorization": " Bearer wh-secret\n"}, HTTPClient: client}))
	rec.reset(200, "{}")
	for _, ch := range channels {
		if err := ch.Send(bg, sample(t), cronwatch.ChannelContext{}); err != nil {
			t.Fatalf("%s: %v", ch.Name(), err)
		}
	}
	got := rec.taken()
	for _, c := range got {
		for name, values := range c.header {
			for _, v := range values {
				if v != strings.TrimSpace(v) {
					t.Errorf("%s has spaces around it: %q", name, v)
				}
			}
		}
	}
	check := func(i int, name, want string) {
		t.Helper()
		if v := got[i].header.Get(name); v != want {
			t.Errorf("request %d %s: %q, want %q", i, name, v, want)
		}
	}
	check(0, "authorization", "Bearer re_secret")
	check(1, "x-postmark-server-token", "pm-secret")
	check(4, "dd-api-key", "dd-secret")
	if !strings.Contains(got[7].body, `"apiKey":"bs-secret"`) {
		t.Error("bugsnag's key is not trimmed in its body")
	}
	if got[10].url != "https://api.twilio.com/2010-04-01/Accounts/AC1/Messages.json" {
		t.Error(got[10].url)
	}
	check(10, "authorization", "Basic "+base64.StdEncoding.EncodeToString([]byte("AC1:tok")))
	if !strings.HasPrefix(got[11].header.Get("authorization"), "AWS4-HMAC-SHA256 Credential=AKIDEXAMPLE/") {
		t.Error(got[11].header.Get("authorization"))
	}
	check(12, "authorization", "Bearer wh-secret")
	if _, err := Resend(ResendOptions{EmailOptions: email, APIKey: "  "}); err == nil || err.Error() != "alerts.Resend needs an APIKey" {
		t.Errorf("got %v", err)
	}
}

func TestASecretThatStraddlesTheCutIsStillCutOut(t *testing.T) {
	key := strings.Join([]string{"key", "0123456789abcdef", "0123456789abcdef"}, "-")[:36]
	rec := &recorder{}
	rec.reset(401, strings.Repeat("x", 180)+"invalid key "+key)
	ch, _ := Mailgun(MailgunOptions{EmailOptions: EmailOptions{From: "a@b.c", To: []string{"d@e.f"}}, APIKey: key, Domain: "mg.example.com", HTTPClient: &http.Client{Transport: rec}})
	err := ch.Send(bg, sample(t), cronwatch.ChannelContext{})
	for i := 0; i+6 <= len(key); i++ {
		if strings.Contains(err.Error(), key[i:i+6]) {
			t.Fatalf("a piece of the key survives: %v", err)
		}
	}
	if !regexp.MustCompile(`: x{180}invalid key \[redacte$`).MatchString(err.Error()) {
		t.Fatalf("got %v", err)
	}
	if got := post.ErrorBody(strings.Repeat("a", 199) + "\U0001F600tail"); got != strings.Repeat("a", 199) {
		t.Fatalf("half a surrogate pair: %q", got)
	}
	if got := post.ErrorBody(strings.Repeat("y", 10)+"sekret"+strings.Repeat("z", 300), "sekret"); !strings.HasPrefix(got, strings.Repeat("y", 10)+"[redacted]") {
		t.Fatal(got)
	}
}

func TestTwilioTextsEveryNumberAtOnceAndReportsTheRefusals(t *testing.T) {
	var mu sync.Mutex
	var sent []string
	rec := &recorder{answer: func(body string) (int, string) {
		values, _ := url.ParseQuery(body)
		if values.Get("To") == "+15550000000" {
			return 400, `{"code":21211,"message":"Invalid To"}`
		}
		mu.Lock()
		sent = append(sent, values.Get("To"))
		mu.Unlock()
		return 201, "{}"
	}}
	sms, _ := Twilio(TwilioOptions{AccountSID: "AC1", AuthToken: "tok", From: "+15551112222", To: []string{"+15553334444", "+15550000000"}, HTTPClient: &http.Client{Transport: rec}})
	clock := storetest.NewClock(time.Date(2026, 1, 1, 0, 0, 0, 0, time.UTC).UnixMilli())
	errs := &storetest.Errors{}
	cw, err := cronwatch.New(cronwatch.WithClock(clock.Now), cronwatch.WithoutCronSecret(), cronwatch.WithErrorHandler(errs.Add), cronwatch.WithAlerts(sms))
	if err != nil {
		t.Fatal(err)
	}
	defer cw.Close()
	if _, err := cw.Job("nightly", cronwatch.Schedule("0 * * * *")); err != nil {
		t.Fatal(err)
	}
	cw.Check(bg)
	for i := 0; i < 6; i++ {
		clock.Advance(70 * 60_000)
		cw.Check(bg)
	}
	if len(sent) != 1 || sent[0] != "+15553334444" {
		t.Fatalf("one SMS for one open missed condition, never resent: %v", sent)
	}
	list := errs.List()
	if len(list) != 1 || !regexp.MustCompile(`^alert channel twilio: Twilio https://api\.twilio\.com answered 400: .*Invalid To.* \(to \*+0000; 1 of 2 numbers took the alert\)$`).MatchString(list[0]) {
		t.Fatalf("got %v", list)
	}
	// Every number refusing it is a failure, retried at the next check.
	rec.reset(500, "no")
	sms, _ = Twilio(TwilioOptions{AccountSID: "AC1", AuthToken: "tok", From: "+1", To: []string{"+2", "+3"}, HTTPClient: &http.Client{Transport: rec}})
	if err := sms.Send(bg, sample(t), cronwatch.ChannelContext{}); err == nil || !strings.HasSuffix(err.Error(), "(2 of 2 numbers failed)") {
		t.Fatalf("got %v", err)
	}
	// Without a client's context, a refusal goes to standard error.
	var buf bytes.Buffer
	saved := cronwatch.Stderr
	cronwatch.Stderr = &buf
	defer func() { cronwatch.Stderr = saved }()
	rec.answer = func(body string) (int, string) {
		values, _ := url.ParseQuery(body)
		if values.Get("To") == "+3" {
			return 400, "no"
		}
		return 201, "{}"
	}
	if err := sms.Send(bg, sample(t), cronwatch.ChannelContext{}); err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(buf.String(), "answered 400: no (to +3; 1 of 2 numbers took the alert)") {
		t.Fatalf("got %q", buf.String())
	}
}

func TestSMSBodiesStayInsideTwilioLimits(t *testing.T) {
	failed := sample(t)
	long := failed
	long.Title, long.Message = "j failed", strings.Repeat("x", 3000)
	if n := js.Length16(smsBody(long, "", 12)); n > 1530 {
		t.Errorf("segments capped at 10: %d", n)
	}
	if n := js.Length16(smsBody(long, "", nan())); n > 459 {
		t.Errorf("not a number is the default 3: %d", n)
	}
	for text, want := range map[string]int{
		strings.Repeat("a", 160): 1, strings.Repeat("a", 161): 2,
		strings.Repeat("a", 152) + "{" + strings.Repeat("a", 152):        3,
		strings.Repeat("\U0001F600", 35):                                 1,
		strings.Repeat("a", 66) + "\U0001F600" + strings.Repeat("a", 66): 3,
	} {
		if got := smsSegments(text); got != want {
			t.Errorf("smsSegments(%d units) = %d, want %d", js.Length16(text), got, want)
		}
	}
	packed := failed
	packed.Title, packed.Message = "t", strings.Repeat(strings.Repeat("a", 152)+"{", 3)
	if n := smsSegments(smsBody(packed, "", 3)); n > 3 {
		t.Errorf("%d segments", n)
	}
	short := failed
	short.Message = "m"
	if n := js.Length16(smsBody(short, "https://example.com/"+strings.Repeat("p", 2000), 10)); n > 1600 {
		t.Errorf("%d units", n)
	}
}

func nan() float64 { var zero float64; return zero / zero }

func TestAJSONBodyCutThroughASurrogatePairKeepsTheLoneHalf(t *testing.T) {
	rec := &recorder{}
	a := sample(t)
	a.Message = strings.Repeat("a", 2899) + "\U0001F600 and on"
	a.Triage = ptr(strings.Repeat("b", 2989) + "\U0001F600")
	ch, _ := Slack(SlackOptions{WebhookURL: "https://hooks.slack.example/T/B/secret", HTTPClient: &http.Client{Transport: rec}})
	if err := ch.Send(bg, a, cronwatch.ChannelContext{}); err != nil {
		t.Fatal(err)
	}
	body := rec.taken()[0].body
	if !strings.Contains(body, strings.Repeat("a", 2899)+"\\ud83d```") || !strings.Contains(body, strings.Repeat("b", 2989)+"\\ud83d\"") {
		t.Fatalf("the lone half is not JSON.stringify's: %s", body[len(body)-80:])
	}
	a.Message, a.Triage = strings.Repeat("c", 3799)+"\U0001F600", ptr(strings.Repeat("d", 999)+"\U0001F600")
	ch, _ = Discord(DiscordOptions{WebhookURL: "https://discord.example/api/webhooks/1/x", HTTPClient: &http.Client{Transport: rec}})
	rec.reset(204, "")
	if err := ch.Send(bg, a, cronwatch.ChannelContext{}); err != nil {
		t.Fatal(err)
	}
	body = rec.taken()[0].body
	if !strings.Contains(body, strings.Repeat("c", 3799)+"\\ud83d\\n```") || !strings.Contains(body, strings.Repeat("d", 999)+"\\ud83d\"") {
		t.Fatalf("the lone half is not JSON.stringify's: %s", body)
	}
}

func ptr[T any](v T) *T { return &v }

func TestChannelsNeedTheirOptions(t *testing.T) {
	email := EmailOptions{From: "a@b.c", To: []string{"d@e.f"}}
	for want, err := range map[string]error{
		"alerts.Slack needs a WebhookURL":                                    second(Slack(SlackOptions{})),
		"alerts.Discord needs a WebhookURL":                                  second(Discord(DiscordOptions{})),
		"alerts.Webhook needs a URL":                                         second(Webhook(WebhookOptions{})),
		"alerts.Postmark needs a From address":                               second(Postmark(PostmarkOptions{ServerToken: "x", EmailOptions: EmailOptions{To: []string{"d@e.f"}}})),
		"alerts.Sendgrid needs at least one To address":                      second(Sendgrid(SendgridOptions{APIKey: "x", EmailOptions: EmailOptions{From: "a@b.c", To: []string{" ", ""}}})),
		"alerts.Mailgun needs a Domain":                                      second(Mailgun(MailgunOptions{APIKey: "x", EmailOptions: email})),
		"alerts.SES needs a Region like us-east-1":                           second(SES(SESOptions{Region: "US East", EmailOptions: email})),
		"alerts.SES needs an AccessKeyID and SecretAccessKey":                second(SES(SESOptions{Region: "us-east-1", AccessKeyID: "x", EmailOptions: email})),
		"alerts.Twilio needs an AuthToken, or an APIKeySID and APIKeySecret": second(Twilio(TwilioOptions{AccountSID: "AC1", APIKeySID: "SK1", AuthToken: "x"})),
		"alerts.Twilio needs a From number or a MessagingServiceSID":         second(Twilio(TwilioOptions{AccountSID: "AC1", AuthToken: "x"})),
		"alerts.Twilio needs at least one To number":                         second(Twilio(TwilioOptions{AccountSID: "AC1", AuthToken: "x", From: "+1"})),
		"alerts.Sentry needs a DSN like https://<key>@<host>/<project>":      second(Sentry(SentryOptions{DSN: "https://o1.ingest.sentry.io/42"})),
		"alerts.Datadog needs a Site like datadoghq.com":                     second(Datadog(DatadogOptions{APIKey: "x", Site: "evil.com/x?"})),
		"alerts.NewRelic needs a numeric AccountID":                          second(NewRelic(NewRelicOptions{APIKey: "x", AccountID: "12a"})),
		"alerts.Honeybadger needs an APIKey":                                 second(Honeybadger(HoneybadgerOptions{APIKey: "\n"})),
	} {
		if err == nil || err.Error() != want {
			t.Errorf("got %v, want %s", err, want)
		}
	}
}

func second[A, B any](_ A, b B) B { return b }

func TestEmailContent(t *testing.T) {
	a := sample(t)
	a.Title = "line one\r\nline two <b>"
	a.Triage = ptr("check the \"db\"")
	m := composeEmail(a, EmailOptions{From: "a@b.c", SubjectPrefix: "[prod]", Link: func(cronwatch.Alert) string { return "javascript:alert(1)" }}, []string{"d@e.f"})
	if m.subject != "[prod] line one line two <b>" {
		t.Errorf("subject %q", m.subject)
	}
	if strings.Contains(m.html, "javascript:") || strings.Contains(m.text, "javascript:") {
		t.Error("a link that is not http or https was put in the mail")
	}
	if !strings.Contains(m.html, "line two &lt;b&gt;") || !strings.Contains(m.html, "check the &quot;db&quot;") {
		t.Error(m.html)
	}
	for text, want := range map[string]string{
		"a@b.c":                   `{"email":"a@b.c"}`,
		" Ops <ops@example.com> ": `{"email":"ops@example.com","name":"Ops"}`,
		`"Ops, Team" <o@x.io>`:    `{"email":"o@x.io","name":"Ops, Team"}`,
		"<o@x.io>":                `{"email":"o@x.io"}`,
		"Ops\nTeam <o@x.io>":      `{"email":"Ops\nTeam <o@x.io>"}`,
	} {
		if got := js.Stringify(parseAddress(text).jsValue()); got != want {
			t.Errorf("parseAddress(%q) = %s, want %s", text, got, want)
		}
	}
}
