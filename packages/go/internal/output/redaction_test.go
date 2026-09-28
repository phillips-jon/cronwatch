package output

// The SDK's redaction tests (packages/sdk/test/redaction.test.ts) that
// exercise redactSecrets and the cap directly; the ones that go through a
// client are the client's tests. Fake keys are built from pieces, so no
// string here looks like a real credential to a scanner.

import (
	"errors"
	"fmt"
	"io/fs"
	"math"
	"strings"
	"testing"
	"time"
)

func TestRedactsWhatTheSDKTestsRedact(t *testing.T) {
	cases := [][2]string{
		{"DB_PASSWORD=hunter2 tokens: 1200", "DB_PASSWORD=[redacted] tokens: 1200"},
		{"connect ECONNREFUSED postgres://app:s3cr3t@10.0.0.12:5432/db", "connect ECONNREFUSED postgres://app:[redacted]@10.0.0.12:5432/db"},
		{"key AKIA" + "IOSFODNN7EXAMPLE and ghp_" + strings.Repeat("a", 36), "key [redacted] and [redacted]"},
		{"Authorization: Bearer abcdefgh12345", "Authorization: Bearer [redacted]"},
		{"max_tokens: 800", "max_tokens: 800"},
		{"SLACK_TOKEN='xoxb-123'", "SLACK_TOKEN='[redacted]'"},
		{`PASSWORD = "two words here"`, `PASSWORD = "[redacted]"`},
		{`{"client_secret": "abc def", "other": "x"}`, `{"client_secret": "[redacted]", "other": "x"}`},
		{`password="a" user="b"`, `password="[redacted]" user="b"`},
		{`password="unterminated`, "password=[redacted]"},
		{`:password=>"hunter2"`, `:password=>"[redacted]"`},
		{"{:api_key => 'abc', user: 1}", "{:api_key => '[redacted]', user: 1}"},
		{"Authorization: Basic dXNlcjpwYXNz", "Authorization: Basic [redacted]"},
		{`{"Authorization": "Token abc123", "x": 1}`, `{"Authorization": "Token [redacted]", "x": 1}`},
		{"-----BEGIN RSA PRIVATE KEY-----\nMIIEow\nIBAAK==\n-----END RSA PRIVATE KEY-----\nafter", "[redacted]\nafter"},
		{"-----BEGIN PRIVATE KEY-----\nMIIE\nabc", "[redacted]"},
		{"jwt eyJ" + "hbGciOiJIUzI1NiJ9.eyJzdWIiOiIxIn0.abc_def-123 done", "jwt [redacted] done"},
		{"https://hooks.slack.com/services/T0/B0/xyz ok", "https://hooks.slack.com/services/[redacted] ok"},
		{"https://discord.com/api/webhooks/123/abc-def", "https://discord.com/api/webhooks/[redacted]"},
		{"key AI" + "za" + strings.Repeat("Sy", 17) + "A", "key [redacted]"},
		{"wh" + "sec_" + strings.Repeat("abcd1234", 3), "[redacted]"},
		{"postgres://user:p@ss@host/db", "postgres://user:[redacted]@host/db"},
		// JavaScript's /i folds ASCII only: these are not secret names there.
		{"\u017fecret=x", "\u017fecret=x"},
		{"api_\u212aey=x", "api_\u212aey=x"},
		// An emoji is two code units to the bounded run, as in JavaScript.
		{"token=" + strings.Repeat("\U0001F600", 3000), "token=[redacted]" + strings.Repeat("\U0001F600", 952)},
		{"token=a" + strings.Repeat("\U0001F600", 3000), "token=[redacted]\ufffd" + strings.Repeat("\U0001F600", 952)},
	}
	for _, c := range cases {
		if got := RedactSecrets(c[0]); got != c[1] {
			t.Errorf("RedactSecrets(%.60q)\n got %.200q\nwant %.200q", c[0], got, c[1])
		}
	}
}

func TestAdversarialLinesRedactInLinearTime(t *testing.T) {
	shapes := []string{
		"password", "token-", "secret_", "a-", "password_x-", "-token", "tokens-", `token"  `, "token  =", `password="`, "x=>", "=>",
		"authorization: ", "authorization: basic ", "Authorization-", "a://", "a://x:", "postgres://u:", "a://" + strings.Repeat("b", 250) + ":",
		"a://b:" + strings.Repeat("c", 250), "https://u:@@@", "@", ":", "Bearer ", "eyJ", "eyJa.", "eyJaaaa.aaaa", "eyJ" + strings.Repeat("a", 4090) + ".",
		"-----BEGIN PRIVATE KEY-----", "-----BEGIN PRIVATE KEY-----" + strings.Repeat("a", 100), "-----BEGIN A B C ", "-----BEGIN PRIVATE KEY----------",
		"hooks.slack.com/services/", "x.discord.com/api/webhooks/", "AI" + "za", "wh" + "sec_", "-", " ",
	}
	var worst time.Duration
	slowest := ""
	for _, shape := range shapes {
		line := strings.Repeat(shape, 16384/len(shape)+1)[:16384]
		started := time.Now()
		RedactSecrets(line)
		RedactSecrets(line + "!")
		if took := time.Since(started); took > worst {
			worst, slowest = took, shape
		}
	}
	t.Logf("slowest 16 KB shape %.30q took %v", slowest, worst)
	limit := time.Second
	if raceEnabled {
		limit = 20 * time.Second
	}
	if worst > limit {
		t.Errorf("%.30q took %v", slowest, worst)
	}
}

func TestAMegabyteRedactsInBoundedTime(t *testing.T) {
	var b strings.Builder
	pieces := []string{
		"INFO processed 1200 rows in 3.2s tokens: 1200 max_tokens: 800\n",
		"password=hunter2 user=bob url=postgres://app:pw@db.internal:5432/app\n",
		"Authorization: Bearer abcdefgh12345 and eyJ" + "hbGciOi.eyJzdWIi.sig\n",
		"r\u00e9sum\u00e9 \U0001F680 done, " + strings.Repeat("x", 200) + "\n",
		"-----BEGIN PRIVATE KEY-----\n" + strings.Repeat("QUJD", 100) + "\n-----END PRIVATE KEY-----\n",
	}
	for b.Len() < 1<<20 {
		for _, p := range pieces {
			b.WriteString(p)
		}
	}
	text := b.String()
	started := time.Now()
	out := RedactSecrets(text)
	took := time.Since(started)
	t.Logf("%d bytes redacted in %v", len(text), took)
	if strings.Contains(out, "hunter2") {
		t.Error("a secret survived")
	}
	if took > 3*time.Second && !raceEnabled {
		t.Errorf("a megabyte took %v", took)
	}
}

func TestCapOutput(t *testing.T) {
	if got := CapOutput("a\x00b"); got != "ab" {
		t.Error(got)
	}
	long := strings.Repeat("x", OutputCap+5)
	if got := CapOutput(long); got != "[earlier output trimmed]\n"+strings.Repeat("x", OutputCap) {
		t.Errorf("cap %d", len(got))
	}
}

type ExportedError struct{ why string }

func (e *ExportedError) Error() string { return e.why }

type quietError struct{}

func (quietError) Error() string { return "quiet" }

func TestErrorNames(t *testing.T) {
	cases := []struct {
		err  error
		want string
	}{
		{errors.New("boom"), "Error: boom"},
		{fmt.Errorf("wrapped: %w", errors.New("x")), "Error: wrapped: x"},
		{errors.Join(errors.New("a"), errors.New("b")), "Error: a\nb"},
		{&ExportedError{"why"}, "ExportedError: why"},
		{quietError{}, "Error: quiet"},
		{&fs.PathError{Op: "open", Path: "/x", Err: fs.ErrNotExist}, "PathError: open /x: file does not exist"},
	}
	for _, c := range cases {
		if got := ErrorMessage(c.err); got != c.want {
			t.Errorf("ErrorMessage(%T) = %q, want %q", c.err, got, c.want)
		}
	}
	values := map[string]any{"plain": "plain", "42": 42, "null": nil, `{"a":1}`: map[string]int{"a": 1}, "1.5": 1.5, "null ": math.NaN(), "7": uint8(7), "\"<b>&\"": "\"<b>&\""}
	for want, v := range values {
		want = strings.TrimSpace(want)
		if s, ok := v.(string); ok {
			want = s
		}
		if got := DescribeError(v); got != want {
			t.Errorf("DescribeError(%#v) = %q, want %q", v, got, want)
		}
	}
	if got := LogText(struct {
		A string `json:"a"`
	}{"<x>"}); got != `{"a":"<x>"}` {
		t.Errorf("LogText struct = %s", got)
	}
}

// panics panics in a frame of its own, for PanicMessage's frames.
func panics() {
	var m map[string]int
	//lint:ignore SA5000 the point is the runtime panic
	m["x"] = 1
}

func TestPanicMessage(t *testing.T) {
	var text string
	func() {
		defer func() { text = PanicMessage(recover()) }()
		panics()
	}()
	lines := strings.Split(text, "\n")
	if lines[0] != "panic: assignment to entry in nil map" {
		t.Fatalf("first line %q", lines[0])
	}
	if len(lines) < 2 || !strings.HasPrefix(lines[1], "    at cronwatch.dev/go/internal/output.panics (") || !strings.Contains(lines[1], "redaction_test.go:") {
		t.Fatalf("frames %q", text)
	}
	if len(lines) > 6 {
		t.Errorf("%d frames", len(lines)-1)
	}
}

func TestRecorderMetrics(t *testing.T) {
	r := NewRecorder()
	if err := r.Metric("cost", math.Inf(1)); err == nil || err.Error() != `metric "cost" must be a finite number` {
		t.Errorf("err %v", err)
	}
	for _, name := range []string{"zeta", "200", "10"} {
		if err := r.Metric(name, 2); err != nil {
			t.Fatal(err)
		}
	}
	if got := fmt.Sprint(r.Metrics().Keys()); got != "[10 200 zeta]" {
		t.Errorf("order %s", got)
	}
	if r.Output() != nil || r.ExpectText() != nil {
		t.Error("nothing logged")
	}
	r.Log("a", 1, errors.New("e"), nil, []any{1.0, "x"})
	if got := *r.Output(); got != `a 1 Error: e null [1,"x"]` {
		t.Errorf("log %q", got)
	}
}
