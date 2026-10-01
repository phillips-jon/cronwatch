package cronwatch_test

// Replays packages/ruby/test/web/golden.json, the SDK routes' answers to a
// fixed seed (written by golden.mjs), against Client.Routes seeded the same
// way, and compares status, headers and body byte for byte: straight into
// the handler, and through a real server with the dashboard mounted by
// http.StripPrefix and by a ServeMux pattern, its base path found from each.
// Run ids are random on both sides, so each becomes <id:N> in order of
// first appearance. The gem, the Python package and the PHP package replay
// the same file.

import (
	"bufio"
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"testing"

	cronwatch "cronwatch.dev/go"
	"cronwatch.dev/go/storetest"
)

type goldenCapture struct {
	Method          string            `json:"method"`
	Path            string            `json:"path"`
	Headers         map[string]string `json:"headers"`
	Body            *string           `json:"body"`
	Status          int               `json:"status"`
	ResponseHeaders map[string]string `json:"responseHeaders"`
	ResponseBody    string            `json:"responseBody"`
}

type goldenFile struct {
	T0       int64           `json:"t0"`
	Captures []goldenCapture `json:"captures"`
}

var (
	uuidRE   = regexp.MustCompile(`[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}`)
	runRefRE = regexp.MustCompile(`\{run:([^:}]+):(\d+)\}`)
)

func readGolden(t *testing.T) goldenFile {
	t.Helper()
	data, err := os.ReadFile(filepath.Join("..", "ruby", "test", "web", "golden.json"))
	if err != nil {
		t.Fatal(err)
	}
	var g goldenFile
	if err := json.Unmarshal(data, &g); err != nil {
		t.Fatal(err)
	}
	if g.T0 != T0 {
		t.Fatalf("golden.json's t0 is %d, not %d", g.T0, T0)
	}
	if len(g.Captures) != 82 {
		t.Fatalf("golden.json has %d captures, not 82", len(g.Captures))
	}
	// GET /api names the library, its language and its version, which the
	// fixture holds as placeholders for each port to fill in with its own.
	about := strings.NewReplacer(
		`{"ok":true,"library":"<library>","language":"<language>","version":"<version>",`,
		`{"ok":true,"library":"cronwatch.dev/go","language":"go","version":"`+cronwatch.Version+`",`,
	)
	for i := range g.Captures {
		g.Captures[i].ResponseBody = about.Replace(g.Captures[i].ResponseBody)
	}
	return g
}

// seedGolden is the seed in golden.mjs, step for step.
func seedGolden(t *testing.T) *cronwatch.Client {
	t.Helper()
	const DAY = 24 * HOUR
	clock := storetest.NewClock(T0)
	cw, err := cronwatch.New(cronwatch.WithClock(clock.Now), cronwatch.WithStore(cronwatch.NewMemoryStore()),
		cronwatch.WithAlerts(cronwatch.ChannelFunc("capture", func(context.Context, cronwatch.Alert) error { return nil })),
		cronwatch.WithoutCronSecret(), cronwatch.WithErrorHandler(func(err error, where string) {
			// Nothing in the seed or the requests may report an error, however
			// far off a run's start is.
			t.Errorf("the client reported an error, %s: %v", where, err)
		}))
	if err != nil {
		t.Fatal(err)
	}
	nightly := must[*cronwatch.Job](t)(cw.Job("nightly-report",
		cronwatch.Schedule("0 2 * * *"), cronwatch.Timezone("UTC"), cronwatch.Grace("15m"), cronwatch.MaxDuration("10m"),
		cronwatch.Budget("cost", 2), cronwatch.Expect("Report written"), cronwatch.FailuresBeforeAlert(2),
		cronwatch.Description("Builds the <b>PDF</b>"), cronwatch.Tags("reports", "<t>")))
	durations := []int64{2000, 2500, 90_000, 3100, 1800}
	for i, d := range durations {
		clock.Set(T0 - int64(5-i)*DAY - 7*HOUR - 30*MIN)
		_ = nightly.Run(bg, func(ctx context.Context, job *cronwatch.JobContext) error {
			if i == 3 {
				job.Log("Wrote nothing", "report-"+strconv.Itoa(i)+".pdf")
			} else {
				job.Log("Report written:", "report-"+strconv.Itoa(i)+".pdf")
			}
			cost := 1.2
			if i == 4 {
				cost = 2.5
			}
			_ = job.Metric("cost", cost)
			_ = job.Metric("rows", float64(40+i))
			_ = job.Metric("2", 0.123456)
			clock.Advance(d)
			return nil
		})
	}
	broken := must[*cronwatch.Job](t)(cw.Job("broken", cronwatch.Expect("done")))
	clock.Set(T0 - 2*HOUR)
	_ = broken.Run(bg, func(ctx context.Context, job *cronwatch.JobContext) error {
		job.Log("half way <script>alert(1)</script>")
		clock.Advance(450)
		return nil
	})
	sync := must[*cronwatch.Job](t)(cw.Job("sync-users", cronwatch.Schedule("*/15 * * * *"), cronwatch.Grace(60_000), cronwatch.Timeout("5m")))
	clock.Set(T0 - 3*HOUR)
	_ = sync.Run(bg, func(context.Context, *cronwatch.JobContext) error {
		clock.Advance(12_345)
		return nil
	})
	must[*cronwatch.Job](t)(cw.Job("never-ran", cronwatch.Schedule("0 * * * *")))
	// A run as a foreign or damaged row could hold it: started before the
	// year 1, so the pages write it in words rather than as a date.
	farBack := must[*cronwatch.Job](t)(cw.Job("far-back", cronwatch.Timeout("5m"), cronwatch.Expect("far")))
	clock.Set(-62_135_596_800_001)
	_ = farBack.Run(bg, func(context.Context, *cronwatch.JobContext) error {
		clock.Advance(1000)
		return nil
	})
	// Cron jobs whose last run is as far off: counted from the first
	// millisecond of the year 1, the first is due then (and is missed at the
	// check); after 9999 the other is never due again.
	for _, far := range []struct {
		name string
		at   int64
	}{{"far-cron-back", -62_135_596_800_001}, {"far-cron-ahead", 253_402_300_800_000}} {
		job := must[*cronwatch.Job](t)(cw.Job(far.name, cronwatch.Schedule("0 2 * * *"), cronwatch.Timezone("UTC"), cronwatch.Grace("10m")))
		clock.Set(far.at)
		if err := job.Run(bg, func(context.Context, *cronwatch.JobContext) error {
			clock.Advance(1000)
			return nil
		}); err != nil {
			t.Fatal(err)
		}
	}
	clock.Set(T0)
	return cw
}

// resolveRuns puts the id of the Nth newest run of a job where the path
// says {run:JOB:N}.
func resolveRuns(t *testing.T, cw *cronwatch.Client, path string) string {
	m := runRefRE.FindStringSubmatch(path)
	if m == nil {
		return path
	}
	n, _ := strconv.Atoi(m[2])
	runs := must[[]cronwatch.Run](t)(cw.Runs(bg, m[1], 50))
	return strings.Replace(path, m[0], runs[n].ID, 1)
}

// goldenRequest is a capture's request as a server hands it over: the
// target as sent in RequestURI (even one Go's own parser would refuse).
func goldenRequest(c goldenCapture, path string) *http.Request {
	u, err := url.ParseRequestURI(path)
	if err != nil {
		p, q, _ := strings.Cut(path, "?")
		u = &url.URL{Path: p, RawQuery: q}
	}
	r := &http.Request{Method: c.Method, URL: u, RequestURI: path, Host: "app.test", Header: http.Header{}, Proto: "HTTP/1.1", ProtoMajor: 1, ProtoMinor: 1}
	for k, v := range c.Headers {
		r.Header.Set(k, v)
	}
	r.Body = http.NoBody
	if c.Body != nil {
		r.Body = io.NopCloser(strings.NewReader(*c.Body))
		r.ContentLength = int64(len(*c.Body))
	}
	return r.WithContext(bg)
}

// ids numbers run ids in order of first appearance, as golden.mjs does.
type ids map[string]string

func (m ids) replace(text string) string {
	return uuidRE.ReplaceAllStringFunc(text, func(id string) string {
		if _, ok := m[id]; !ok {
			m[id] = "<id:" + strconv.Itoa(len(m)) + ">"
		}
		return m[id]
	})
}

// compare checks one answer against its capture. ignored names headers the
// server in front adds (the SDK leaves Content-Length to it).
func compare(t *testing.T, c goldenCapture, status int, header http.Header, body []byte, seen ids, ignored ...string) {
	t.Helper()
	label := c.Method + " " + c.Path
	got := map[string]string{}
	for k, v := range header {
		name := strings.ToLower(k)
		if name == "content-length" || containsString(ignored, name) {
			continue
		}
		got[name] = strings.Join(v, ", ")
	}
	text := ""
	if got["content-type"] == "image/png" {
		text = "base64:" + base64.StdEncoding.EncodeToString(body)
	} else {
		text = seen.replace(string(body))
	}
	if status != c.Status {
		t.Errorf("%s: status %d, want %d", label, status, c.Status)
	}
	if len(got) != len(c.ResponseHeaders) {
		t.Errorf("%s: headers %v, want %v", label, got, c.ResponseHeaders)
	}
	for k, v := range c.ResponseHeaders {
		if got[k] != v {
			t.Errorf("%s: header %s is %q, want %q", label, k, got[k], v)
		}
	}
	if text != c.ResponseBody {
		t.Errorf("%s: body differs at byte %d:\n got %.300q\nwant %.300q", label, firstDiff(text, c.ResponseBody), tail(text, firstDiff(text, c.ResponseBody)), tail(c.ResponseBody, firstDiff(text, c.ResponseBody)))
	}
}

func containsString(list []string, s string) bool {
	for _, v := range list {
		if v == s {
			return true
		}
	}
	return false
}

func firstDiff(a, b string) int {
	for i := 0; i < len(a) && i < len(b); i++ {
		if a[i] != b[i] {
			return i
		}
	}
	return min(len(a), len(b))
}

func tail(s string, from int) string {
	return s[max(0, from-80):]
}

func TestRoutesMatchTheSDKGolden(t *testing.T) {
	g := readGolden(t)
	cw := seedGolden(t)
	routes := must[*cronwatch.Routes](t)(cw.Routes(cronwatch.WithToken("tok"), cronwatch.WithBasePath("/cronwatch")))
	seen := ids{}
	for _, c := range g.Captures {
		rec := httptest.NewRecorder()
		routes.ServeHTTP(rec, goldenRequest(c, resolveRuns(t, cw, c.Path)))
		compare(t, c, rec.Code, rec.Header(), rec.Body.Bytes(), seen)
	}
}

// replayServer replays the fixture through a real server, with the
// dashboard mounted by mount (its base path never given).
func replayServer(t *testing.T, mount func(mux *http.ServeMux, routes *cronwatch.Routes)) {
	g := readGolden(t)
	cw := seedGolden(t)
	routes := must[*cronwatch.Routes](t)(cw.Routes(cronwatch.WithToken("tok")))
	mux := http.NewServeMux()
	mount(mux, routes)
	server := httptest.NewServer(mux)
	defer server.Close()
	client := &http.Client{CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }}
	seen := ids{}
	for _, c := range g.Captures {
		path := resolveRuns(t, cw, c.Path)
		var body io.Reader
		if c.Body != nil {
			body = strings.NewReader(*c.Body)
		}
		req, err := http.NewRequest(c.Method, server.URL+path, body)
		if err != nil {
			// A malformed escape (%zz): Go's server answers it 400 itself,
			// before any handler; see TestRoutesMalformedEscapeThroughAServer.
			var urlErr *url.Error
			if !errors.As(err, &urlErr) || c.Status != http.StatusBadRequest {
				t.Fatalf("%s: %v", c.Path, err)
			}
			continue
		}
		req.Host = "app.test"
		for k, v := range c.Headers {
			req.Header.Set(k, v)
		}
		res, err := client.Do(req)
		if err != nil {
			t.Fatal(err)
		}
		data, _ := io.ReadAll(res.Body)
		res.Body.Close()
		compare(t, c, res.StatusCode, res.Header, data, seen, "date")
	}
}

func TestRoutesMatchTheSDKGoldenUnderStripPrefix(t *testing.T) {
	replayServer(t, func(mux *http.ServeMux, routes *cronwatch.Routes) {
		mux.Handle("/cronwatch/", http.StripPrefix("/cronwatch", routes))
	})
}

func TestRoutesMatchTheSDKGoldenUnderAPattern(t *testing.T) {
	replayServer(t, func(mux *http.ServeMux, routes *cronwatch.Routes) {
		mux.Handle("/cronwatch/{path...}", routes)
	})
}

// TestRoutesMalformedEscapeThroughAServer: Go's server answers a target
// with an escape that is not one itself, before the dashboard sees it.
func TestRoutesMalformedEscapeThroughAServer(t *testing.T) {
	cw := seedGolden(t)
	routes := must[*cronwatch.Routes](t)(cw.Routes(cronwatch.WithToken("tok")))
	server := httptest.NewServer(routes)
	defer server.Close()
	conn, err := net.Dial("tcp", server.Listener.Addr().String())
	check(t, err)
	defer conn.Close()
	_, err = io.WriteString(conn, "GET /cronwatch/jobs/%zz HTTP/1.1\r\nHost: app.test\r\nAuthorization: Bearer tok\r\nConnection: close\r\n\r\n")
	check(t, err)
	res, err := http.ReadResponse(bufio.NewReader(conn), nil)
	check(t, err)
	res.Body.Close()
	eq(t, "status", res.StatusCode, http.StatusBadRequest)
}
