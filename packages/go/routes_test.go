package cronwatch_test

// The SDK's routes tests (routes.test.ts, routes-security.test.ts,
// routes-origin.test.ts, routes-pwa.test.ts in part), and what only a Go
// handler has: the base path found from http.StripPrefix and ServeMux
// patterns, the body cap, HEAD, and HTTP/2's split cookies.

import (
	"bytes"
	"context"
	"crypto/sha256"
	"crypto/tls"
	"encoding/hex"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"net/url"
	"regexp"
	"strings"
	"testing"
	"time"

	cronwatch "cronwatch.dev/go"
	"cronwatch.dev/go/storetest"
)

// web is a client, its routes, and a way to send them a request.
type web struct {
	cw     *cronwatch.Client
	c      *storetest.Clock
	routes *cronwatch.Routes
	errors *storetest.Errors
}

type hdr map[string]string

// tlsState marks a request as come over TLS.
var tlsState tls.ConnectionState

var (
	tokenCookieValue = func() string {
		sum := sha256.Sum256([]byte("cronwatch-cookie:tok"))
		return "cronwatch_token=" + hex.EncodeToString(sum[:])
	}()
	auth   = hdr{"authorization": "Bearer tok"}
	cookie = hdr{"cookie": tokenCookieValue}
	form   = hdr{"content-type": "application/x-www-form-urlencoded"}
)

func join(maps ...hdr) hdr {
	out := hdr{}
	for _, m := range maps {
		for k, v := range m {
			out[k] = v
		}
	}
	return out
}

func newWeb(t *testing.T, routeOptions []cronwatch.RoutesOption, options ...cronwatch.Option) *web {
	t.Helper()
	w := &web{c: storetest.NewClock(T0), errors: &storetest.Errors{}}
	all := append([]cronwatch.Option{cronwatch.WithClock(w.c.Now), cronwatch.WithAlerts(&storetest.Capture{}), cronwatch.WithoutCronSecret(),
		cronwatch.WithErrorHandler(w.errors.Add)}, options...)
	w.cw = must[*cronwatch.Client](t)(cronwatch.New(all...))
	if routeOptions == nil {
		routeOptions = []cronwatch.RoutesOption{cronwatch.WithToken("tok"), cronwatch.WithBasePath("/cronwatch")}
	}
	w.routes = must[*cronwatch.Routes](t)(w.cw.Routes(routeOptions...))
	return w
}

// request is a request for a full URL, as a server would hand it over:
// the target as sent in RequestURI, even one url.Parse refuses.
func request(method, target string, headers hdr, body string) *http.Request {
	rest := strings.TrimPrefix(strings.TrimPrefix(target, "http://"), "https://")
	host, path, _ := strings.Cut(rest, "/")
	path = "/" + path
	u, err := url.ParseRequestURI(path)
	if err != nil {
		p, q, _ := strings.Cut(path, "?")
		u = &url.URL{Path: p, RawQuery: q}
	}
	r := &http.Request{Method: method, URL: u, RequestURI: path, Host: host, Header: http.Header{}, Body: http.NoBody, Proto: "HTTP/1.1", ProtoMajor: 1, ProtoMinor: 1}
	if strings.HasPrefix(target, "https://") {
		r.TLS = &tlsState
	}
	for k, v := range headers {
		r.Header.Set(k, v)
	}
	if body != "" {
		r.Body = io.NopCloser(strings.NewReader(body))
		r.ContentLength = int64(len(body))
	}
	return r.WithContext(context.Background())
}

func serve(h http.Handler, method, target string, headers hdr, body string) *httptest.ResponseRecorder {
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, request(method, target, headers, body))
	return rec
}

func (w *web) send(method, path string, headers hdr, body string) *httptest.ResponseRecorder {
	return serve(w.routes, method, "http://app.test"+path, headers, body)
}

func (w *web) get(path string, headers hdr) *httptest.ResponseRecorder {
	return w.send("GET", path, headers, "")
}

func decode(t *testing.T, rec *httptest.ResponseRecorder) map[string]any {
	t.Helper()
	var out map[string]any
	if err := json.Unmarshal(rec.Body.Bytes(), &out); err != nil {
		t.Fatalf("not JSON: %v: %s", err, rec.Body.String())
	}
	return out
}

func status(t *testing.T, what string, rec *httptest.ResponseRecorder, want int) {
	t.Helper()
	if rec.Code != want {
		t.Errorf("%s: status %d, want %d (%.200s)", what, rec.Code, want, rec.Body.String())
	}
}

func contains(t *testing.T, what, text, want string) {
	t.Helper()
	if !strings.Contains(text, want) {
		t.Errorf("%s: %q is not in %.400q", what, want, text)
	}
}

func TestRoutesEverythingNeedsTheToken(t *testing.T) {
	w := newWeb(t, nil)
	status(t, "page", w.get("/cronwatch", nil), 401)
	status(t, "api", w.get("/cronwatch/api/jobs", nil), 401)
	status(t, "wrong", w.get("/cronwatch/api/jobs", hdr{"authorization": "Bearer wrong"}), 401)
	status(t, "right", w.get("/cronwatch/api/jobs", auth), 200)
	status(t, "any case and spaces", w.get("/cronwatch/api/jobs", hdr{"authorization": "bEaReR \t tok"}), 200)
}

func TestRoutesCheckAcceptsTheCronSecretAndNothingElseDoes(t *testing.T) {
	secret := "cron-" + "s3cret"
	w := newWeb(t, nil, cronwatch.WithCronSecret(secret))
	with := hdr{"authorization": "Bearer " + secret}
	status(t, "check", w.get("/cronwatch/api/check", with), 200)
	status(t, "jobs", w.get("/cronwatch/api/jobs", with), 401)
	status(t, "only as a bearer", w.get("/cronwatch/api/check?token="+secret, nil), 401)
}

func TestRoutesSignInSetsACookieAndRedirectsToACleanURL(t *testing.T) {
	w := newWeb(t, nil)
	res := w.get("/cronwatch/?token=tok", nil)
	status(t, "sign-in", res, 303)
	eq(t, "location", res.Header().Get("Location"), "/cronwatch/")
	set := res.Header().Get("Set-Cookie")
	eq(t, "a digest, not the token", strings.Split(set, ";")[0], tokenCookieValue)
	contains(t, "cookie", set, "; Path=/cronwatch; HttpOnly; SameSite=Lax")
	page := w.get("/cronwatch/", hdr{"cookie": "other=1; " + tokenCookieValue})
	status(t, "with the cookie", page, 200)
	contains(t, "type", page.Header().Get("Content-Type"), "text/html")
	status(t, "the raw token is not a cookie", w.get("/cronwatch/", hdr{"cookie": "cronwatch_token=tok"}), 401)
	// HTTP/2 may send each cookie as a header of its own.
	r := request("GET", "http://app.test/cronwatch/", nil, "")
	r.Header.Add("Cookie", "other=1")
	r.Header.Add("Cookie", tokenCookieValue)
	rec := httptest.NewRecorder()
	w.routes.ServeHTTP(rec, r)
	status(t, "split cookies", rec, 200)
	other := w.get("/cronwatch/jobs/x?view=all&token=tok&a=b+c", nil)
	eq(t, "the rest of the query is kept", other.Header().Get("Location"), "/cronwatch/jobs/x?view=all&a=b+c")
}

func TestRoutesPagesRenderAndTheAPIAnswers(t *testing.T) {
	w := newWeb(t, nil)
	job := must[*cronwatch.Job](t)(w.cw.Job("nightly-report", cronwatch.Schedule("0 2 * * *"), cronwatch.Description("Builds the PDF")))
	check(t, job.Run(bg, func(ctx context.Context, j *cronwatch.JobContext) error {
		j.Log("built")
		w.c.Advance(2000)
		return nil
	}))
	_ = w.cw.Run(bg, "broken", fails("kaboom <script>"))

	dash := w.get("/cronwatch", auth).Body.String()
	for _, want := range []string{"nightly-report", "Builds the PDF", "healthy", "failing",
		`<p class="headline">2 jobs, <b>1 needing attention</b>.</p>`,
		`<div class="bad"><dt><i class="sq bad" aria-hidden="true"></i>failing</dt><dd>1</dd></div>`,
		`<figure class="timeline day">`, `<table class="board">`,
		`<form class="inline" method="post" action="/cronwatch/check"><button class="primary" type="submit">Run check now</button></form>`} {
		contains(t, "dashboard", dash, want)
	}
	page := w.get("/cronwatch/jobs/broken", auth)
	status(t, "job page", page, 200)
	html := page.Body.String()
	contains(t, "escaped", html, "kaboom &lt;script&gt;")
	if strings.Contains(html, "<script>") {
		t.Error("an unescaped <script>")
	}
	contains(t, "heading", html, `<h1 class="jobname">broken</h1>`)
	contains(t, "week", html, `<figure class="timeline week">`)
	contains(t, "error", html, `<details class="out error" open><summary>error</summary><pre>Error: kaboom &lt;script&gt;`)

	list := decode(t, w.get("/cronwatch/api/jobs", auth))
	eq(t, "jobs", len(list["jobs"].([]any)), 2)
	one := decode(t, w.get("/cronwatch/api/jobs/nightly-report?runs=5", auth))
	eq(t, "health", one["job"].(map[string]any)["health"].(string), "healthy")
	runList := one["runs"].([]any)
	eq(t, "runs", len(runList), 1)
	eq(t, "output", runList[0].(map[string]any)["output"].(string), "built")
	status(t, "api missing", w.get("/cronwatch/api/jobs/missing", auth), 404)
	status(t, "page missing", w.get("/cronwatch/jobs/missing", auth), 404)
	status(t, "nope", w.get("/cronwatch/nope", auth), 404)
}

func TestRoutesNamesBreakAfterTheirSeparatorsOnlyAsText(t *testing.T) {
	w := newWeb(t, nil)
	name := "wp:store_sync.inventory--eu"
	check(t, w.cw.Run(bg, name, ok))
	shown := "wp:<wbr>store_<wbr>sync.<wbr>inventory--<wbr>eu"
	href := "/cronwatch/jobs/wp%3Astore_sync.inventory--eu"
	dash := w.get("/cronwatch", auth).Body.String()
	contains(t, "the lane", dash, `<a class="name" href="`+href+`">`+shown+`</a><span class="sched">`)
	contains(t, "the board", dash, `<td class="job"><a class="name" href="`+href+`">`+shown+`</a></td>`)
	contains(t, "the words", dash, `<li>wp:store_sync.inventory--eu (`)
	page := w.get(href, auth).Body.String()
	contains(t, "crumb", page, `<span class="crumb">`+shown+`</span>`)
	contains(t, "heading", page, `<h1 class="jobname">`+shown+`</h1>`)
	contains(t, "title", page, `<title>wp:store_sync.inventory--eu: CronWatch</title>`)
	contains(t, "marks", page, `<title>wp:store_sync.inventory--eu, `)
	eq(t, "only in the crumb and the heading", strings.Count(page, "<wbr>"), 8)
}

func TestRoutesAPIWrites(t *testing.T) {
	w := newWeb(t, nil)
	check(t, w.cw.Run(bg, "s", ok))
	post := func(path, body string) *httptest.ResponseRecorder {
		return w.send("POST", path, join(auth, hdr{"content-type": "application/json"}), body)
	}
	result := decode(t, post("/cronwatch/api/check", ""))
	eq(t, "ok", result["ok"].(bool), true)
	eq(t, "jobs", len(result["jobs"].([]any)), 1)
	silenced := decode(t, post("/cronwatch/api/jobs/s/silence", `{"for":"2h"}`))
	eq(t, "until", silenced["state"].(map[string]any)["silencedUntil"].(float64), float64(T0+2*HOUR))
	eq(t, "health", summary(t, w.cw, "s").Health, cronwatch.HealthSilenced)
	un := decode(t, post("/cronwatch/api/jobs/s/unsilence", ""))
	eq(t, "unsilenced", un["state"].(map[string]any)["silencedUntil"], any(nil))
	status(t, "ghost", post("/cronwatch/api/jobs/nope/silence", `{"for":"1h"}`), 404)
	status(t, "delete", w.send("DELETE", "/cronwatch/api/jobs/s", auth, ""), 200)
	if summary(t, w.cw, "s") != nil {
		t.Error("the job was not forgotten")
	}
	status(t, "delete again", w.send("DELETE", "/cronwatch/api/jobs/s", auth, ""), 404)
}

func TestRoutesFormsPostAndRedirectBack(t *testing.T) {
	w := newWeb(t, nil)
	check(t, w.cw.Run(bg, "f", ok))
	res := w.send("POST", "/cronwatch/jobs/f/silence", join(auth, form, hdr{"referer": "http://app.test/cronwatch/jobs/f"}), "for=4h")
	status(t, "silence", res, 303)
	eq(t, "back", res.Header().Get("Location"), "http://app.test/cronwatch/jobs/f")
	eq(t, "health", summary(t, w.cw, "f").Health, cronwatch.HealthSilenced)
	elsewhere := w.send("POST", "/cronwatch/jobs/f/unsilence", join(auth, hdr{"referer": "https://evil.example/phish"}), "")
	eq(t, "a foreign referer is not followed", elsewhere.Header().Get("Location"), "/cronwatch/")
	multipart := "--b\r\nContent-Disposition: form-data; name=\"for\"\r\n\r\n2h\r\n--b--\r\n"
	status(t, "multipart", w.send("POST", "/cronwatch/jobs/f/silence", join(auth, hdr{"content-type": "multipart/form-data; boundary=b"}), multipart), 303)
	eq(t, "silenced for two hours", *summary(t, w.cw, "f").SilencedUntil, T0+2*HOUR)
	status(t, "forget", w.send("POST", "/cronwatch/jobs/f/forget", auth, ""), 303)
	if summary(t, w.cw, "f") != nil {
		t.Error("the job was not forgotten")
	}
}

func TestRoutesCrossSiteWritesAreRefused(t *testing.T) {
	w := newWeb(t, nil)
	check(t, w.cw.Run(bg, "x", ok))
	for _, headers := range []hdr{
		{"origin": "https://evil.example"}, {"origin": "null"}, {"sec-fetch-site": "cross-site"},
		{"sec-fetch-site": "same-site"}, {"origin": "http://app.test", "sec-fetch-site": "cross-site"},
	} {
		status(t, "form", w.send("POST", "/cronwatch/jobs/x/silence", join(cookie, form, headers), "for=1h"), 403)
		status(t, "check", w.send("POST", "/cronwatch/api/check", join(auth, headers), ""), 403)
		status(t, "delete", w.send("DELETE", "/cronwatch/api/jobs/x", join(cookie, headers), ""), 403)
	}
	if s := summary(t, w.cw, "x"); s == nil || s.SilencedUntil != nil {
		t.Error("a cross-site write went through")
	}
	same := hdr{"origin": "http://app.test", "sec-fetch-site": "same-origin", "referer": "http://app.test/cronwatch/jobs/x"}
	status(t, "run check now", w.send("POST", "/cronwatch/check", join(cookie, same), ""), 303)
	status(t, "api client", w.send("POST", "/cronwatch/api/jobs/x/unsilence", auth, ""), 200)
	status(t, "none", w.send("POST", "/cronwatch/api/check", join(auth, hdr{"sec-fetch-site": "none"}), ""), 200)
}

func TestRoutesGetCheckNeedsABearerAndQueryTokensOnlySignIn(t *testing.T) {
	w := newWeb(t, nil)
	check(t, w.cw.Run(bg, "x", ok))
	viaCookie := w.get("/cronwatch/api/check", cookie)
	status(t, "cookie GET", viaCookie, 405)
	eq(t, "allow", viaCookie.Header().Get("Allow"), "POST")
	status(t, "cookie POST", w.send("POST", "/cronwatch/api/check", cookie, ""), 200)
	status(t, "bearer GET", w.get("/cronwatch/api/check", auth), 200)
	status(t, "api", w.get("/cronwatch/api/jobs?token=tok", nil), 401)
	status(t, "api job", w.get("/cronwatch/api/jobs/x?token=tok", nil), 401)
	status(t, "api check", w.send("POST", "/cronwatch/api/check?token=tok", nil, ""), 401)
	status(t, "check", w.send("POST", "/cronwatch/check?token=tok", nil, ""), 401)
	status(t, "forget", w.send("POST", "/cronwatch/jobs/x/forget?token=tok", nil, ""), 401)
	if summary(t, w.cw, "x") == nil {
		t.Error("forgotten by a query token")
	}
	status(t, "page", w.get("/cronwatch/jobs/x?token=tok", nil), 303)
}

func TestRoutesMalformedCookiesAndPathsAreAnswered(t *testing.T) {
	w := newWeb(t, nil)
	status(t, "cookie", w.get("/cronwatch/", hdr{"cookie": "cronwatch_token=%E0%A4%A"}), 401)
	status(t, "cookie %", w.get("/cronwatch/api/jobs", hdr{"cookie": "cronwatch_token=%"}), 401)
	status(t, "path", w.get("/cronwatch/jobs/%E0%A4%A", auth), 400)
	api := w.get("/cronwatch/api/jobs/%zz", auth)
	status(t, "api path", api, 400)
	eq(t, "ok", decode(t, api)["ok"].(bool), false)
	status(t, "api silence", w.send("POST", "/cronwatch/api/jobs/%zz/silence", auth, ""), 400)
	status(t, "not UTF-8", w.get("/cronwatch/jobs/%E9", auth), 400)
}

func TestRoutesRunsIsClamped(t *testing.T) {
	w := newWeb(t, nil)
	for range 3 {
		check(t, w.cw.Run(bg, "r", ok))
	}
	for value, want := range map[string]int{"0": 1, "-5": 1, "2.7": 2, "abc": 3, "": 3, "1e9": 3, "Infinity": 3, "0x2": 2, "%202%20": 2} {
		got := len(decode(t, w.get("/cronwatch/api/jobs/r?runs="+value, auth))["runs"].([]any))
		eq(t, "runs="+value, got, want)
	}
}

func TestRoutesAnUnexpectedErrorIsAGeneric500(t *testing.T) {
	store := newTestStore()
	w := newWeb(t, nil, cronwatch.WithStore(store))
	store.breaks("ListJobs")
	api := w.get("/cronwatch/api/jobs", auth)
	status(t, "api", api, 500)
	eq(t, "body", api.Body.String(), `{"ok":false,"error":"Internal error"}`)
	page := w.get("/cronwatch/", auth)
	status(t, "page", page, 500)
	contains(t, "type", page.Header().Get("Content-Type"), "text/html")
	if strings.Contains(page.Body.String(), "store down") {
		t.Error("the error reached the page")
	}
	sameList(t, "reported", w.errors.List(), []string{"routes: store down: ListJobs", "routes: store down: ListJobs"})

	throwing := must[*cronwatch.Client](t)(cronwatch.New(cronwatch.WithStore(store), cronwatch.WithoutCronSecret(),
		cronwatch.WithErrorHandler(func(error, string) { panic("logger down") })))
	routes := must[*cronwatch.Routes](t)(throwing.Routes(cronwatch.WithToken("tok")))
	status(t, "a panicking error handler", serve(routes, "GET", "http://app.test/cronwatch/api/jobs", auth, ""), 500)
}

func TestRoutesSilenceDurations(t *testing.T) {
	w := newWeb(t, nil)
	check(t, w.cw.Run(bg, "s", ok))
	json := join(auth, hdr{"content-type": "application/json"})
	silence := func(body string) *httptest.ResponseRecorder {
		return w.send("POST", "/cronwatch/api/jobs/s/silence", json, body)
	}
	for _, bad := range []string{`"forever"`, `"2 hours"`, `""`, `"-5"`, `"1h then some"`, `true`} {
		res := silence(`{"for":` + bad + `}`)
		status(t, bad, res, 400)
		contains(t, bad, decode(t, res)["error"].(string), "silence duration")
	}
	if summary(t, w.cw, "s").SilencedUntil != nil {
		t.Error("a bad duration silenced the job")
	}
	until := func(body string) int64 {
		return int64(decode(t, silence(body))["state"].(map[string]any)["silencedUntil"].(float64)) - T0
	}
	eq(t, "a number", until(`{"for":7200000}`), 7_200_000)
	eq(t, "a numeric string", until(`{"for":"60000"}`), 60_000)
	eq(t, "text", until(`{"for":"90m"}`), 90*MIN)
	eq(t, "absent", until(`{}`), HOUR)
	eq(t, "a byte order mark", until("\ufeff"+`{"for":"2h"}`), 2*HOUR)
	status(t, "query", w.send("POST", "/cronwatch/api/jobs/s/silence?for=forever", auth, ""), 400)
	eq(t, "the query when the body has none", int64(decode(t, w.send("POST", "/cronwatch/api/jobs/s/silence?for=3h", auth, ""))["state"].(map[string]any)["silencedUntil"].(float64))-T0, 3*HOUR)
}

func TestRoutesTheSilenceFormShowsAnError(t *testing.T) {
	w := newWeb(t, nil)
	check(t, w.cw.Run(bg, "s", ok))
	f := join(cookie, form)
	bad := w.send("POST", "/cronwatch/jobs/s/silence", f, "for=forever")
	status(t, "bad", bad, 400)
	contains(t, "type", bad.Header().Get("Content-Type"), "text/html")
	contains(t, "message", bad.Body.String(), "silence duration &quot;forever&quot;")
	status(t, "ghost", w.send("POST", "/cronwatch/jobs/ghost/silence", f, "for=1h"), 404)
	status(t, "ghost unsilence", w.send("POST", "/cronwatch/jobs/ghost/unsilence", f, ""), 404)
	status(t, "explode", w.send("POST", "/cronwatch/jobs/s/explode", f, ""), 404)
}

func TestRoutesABodyPastTheCapIs413(t *testing.T) {
	w := newWeb(t, nil)
	check(t, w.cw.Run(bg, "s", ok))
	big := `{"for":"2h","pad":"` + strings.Repeat("x", cronwatch.MaxBody) + `"}`
	api := w.send("POST", "/cronwatch/api/jobs/s/silence", join(auth, hdr{"content-type": "application/json"}), big)
	status(t, "api", api, 413)
	eq(t, "api body", api.Body.String(), `{"ok":false,"error":"Request body too large"}`)
	page := w.send("POST", "/cronwatch/jobs/s/silence", join(auth, form), "for=2h&pad="+strings.Repeat("x", cronwatch.MaxBody))
	status(t, "form", page, 413)
	contains(t, "form body", page.Body.String(), "The request was too large.")
	// Without a Content-Length, by reading one byte past the cap.
	r := request("POST", "http://app.test/cronwatch/api/jobs/s/silence", join(auth, hdr{"content-type": "application/json"}), "")
	r.Body = io.NopCloser(io.MultiReader(strings.NewReader(big)))
	r.ContentLength = -1
	rec := httptest.NewRecorder()
	w.routes.ServeHTTP(rec, r)
	status(t, "chunked", rec, 413)
	if summary(t, w.cw, "s").SilencedUntil != nil {
		t.Error("a body past the cap silenced the job")
	}
	// Refused before the body is read: no token, no read.
	counting := &countingReader{r: strings.NewReader(big)}
	r = request("POST", "http://app.test/cronwatch/api/jobs/s/silence", hdr{"content-type": "application/json"}, "")
	r.Body = io.NopCloser(counting)
	w.routes.ServeHTTP(httptest.NewRecorder(), r)
	eq(t, "bytes read without the token", counting.n, 0)
}

type countingReader struct {
	r io.Reader
	n int
}

func (c *countingReader) Read(p []byte) (int, error) {
	n, err := c.r.Read(p)
	c.n += n
	return n, err
}

func TestRoutesSecurityHeaders(t *testing.T) {
	w := newWeb(t, nil)
	check(t, w.cw.Run(bg, "h", ok))
	script := regexp.MustCompile(`(?i)<script[^>]*>[^<]*</script>`)
	for _, path := range []string{"/cronwatch/", "/cronwatch/jobs/h", "/cronwatch/nope"} {
		res := w.get(path, auth)
		eq(t, "csp", res.Header().Get("Content-Security-Policy"), "default-src 'none'; script-src 'self'; style-src 'unsafe-inline'; img-src 'self' data:; manifest-src 'self'; worker-src 'self'; form-action 'self'; frame-ancestors 'none'; base-uri 'none'")
		eq(t, "frame", res.Header().Get("X-Frame-Options"), "DENY")
		eq(t, "nosniff", res.Header().Get("X-Content-Type-Options"), "nosniff")
		eq(t, "referrer", res.Header().Get("Referrer-Policy"), "same-origin")
		eq(t, "cache", res.Header().Get("Cache-Control"), "no-store")
		sameList(t, "one script", script.FindAllString(res.Body.String(), -1), []string{`<script src="/cronwatch/app.js" defer></script>`})
	}
	api := w.get("/cronwatch/api/jobs", auth)
	eq(t, "api nosniff", api.Header().Get("X-Content-Type-Options"), "nosniff")
	eq(t, "api cache", api.Header().Get("Cache-Control"), "no-store")
}

func TestRoutesMarkupStaysEscaped(t *testing.T) {
	w := newWeb(t, nil)
	job := must[*cronwatch.Job](t)(w.cw.Job("m", cronwatch.Schedule("0 2 * * *"), cronwatch.Description("<img src=x>"), cronwatch.Tags("<t>"), cronwatch.Expect("<e>")))
	check(t, job.Run(bg, func(ctx context.Context, j *cronwatch.JobContext) error {
		j.Log("<o>")
		return j.Metric("<k>", 1)
	}))
	bad := regexp.MustCompile(`<img|<t>|<e>|<o>|<k>|<x>`)
	for _, path := range []string{"/cronwatch/", "/cronwatch/jobs/m", "/cronwatch/jobs/%3Cx%3E"} {
		if found := bad.FindString(w.get(path, auth).Body.String()); found != "" {
			t.Errorf("%s: %s unescaped", path, found)
		}
	}
}

// devEnv is a development environment with no token configured.
func devEnv(t *testing.T) *bytes.Buffer {
	t.Helper()
	t.Setenv("CRONWATCH_ENV", "development")
	t.Setenv("CRONWATCH_TOKEN", "")
	out := &bytes.Buffer{}
	before := cronwatch.Stdout
	cronwatch.Stdout = out
	t.Cleanup(func() { cronwatch.Stdout = before })
	return out
}

func TestRoutesLockedWithoutATokenOutsideDevelopment(t *testing.T) {
	for _, env := range []string{"", "production", "staging", "prod"} {
		t.Setenv("CRONWATCH_ENV", env)
		t.Setenv("APP_ENV", "")
		t.Setenv("GO_ENV", "")
		t.Setenv("CRONWATCH_TOKEN", "")
		cw := must[*cronwatch.Client](t)(cronwatch.New(cronwatch.WithoutCronSecret()))
		routes := must[*cronwatch.Routes](t)(cw.Routes())
		status(t, env+" api", serve(routes, "GET", "http://localhost/cronwatch/api/jobs", nil, ""), 503)
		page := serve(routes, "GET", "http://localhost/cronwatch", nil, "")
		status(t, env+" page", page, 503)
		contains(t, "locked", page.Body.String(), "CronWatch routes are locked")
	}
}

func TestRoutesDevelopmentTokenIsPrintedOnceAndRequired(t *testing.T) {
	for _, variable := range []string{"CRONWATCH_ENV", "APP_ENV", "GO_ENV"} {
		out := devEnv(t)
		t.Setenv("CRONWATCH_ENV", "")
		t.Setenv(variable, "test")
		cw := must[*cronwatch.Client](t)(cronwatch.New(cronwatch.WithoutCronSecret()))
		routes := must[*cronwatch.Routes](t)(cw.Routes(cronwatch.WithBasePath("/cronwatch/")))
		for _, c := range []struct {
			url     string
			headers hdr
		}{
			{"http://localhost:3000/cronwatch/api/jobs", nil},
			{"http://localhost:3000/cronwatch/api/jobs", hdr{"x-forwarded-for": "127.0.0.1"}},
			{"http://127.0.0.1:3000/cronwatch/", nil},
			{"http://192.168.1.20:3000/cronwatch/api/jobs", nil},
			{"http://[::1]:3000/cronwatch/api/jobs", hdr{"x-real-ip": "127.0.0.1"}},
		} {
			status(t, c.url, serve(routes, "GET", c.url, c.headers, ""), 401)
		}
		lines := strings.Split(strings.TrimSpace(out.String()), "\n")
		eq(t, variable+": announced once", len(lines), 1)
		m := regexp.MustCompile(`^\[cronwatch\] CRONWATCH_TOKEN is not set, so this development server made a token for the dashboard\. Sign in: http://localhost:3000/cronwatch/\?token=([A-Za-z0-9_-]{43})$`).FindStringSubmatch(lines[0])
		if m == nil {
			t.Fatalf("the sign-in line: %q", lines[0])
		}
		token := m[1]
		eq(t, "Token", routes.Token(), token)
		page := serve(routes, "GET", "http://localhost:3000/cronwatch/", nil, "")
		contains(t, "page", page.Body.String(), "sign-in link is in the server log")
		contains(t, "api", decode(t, serve(routes, "GET", "http://localhost:3000/cronwatch/api/jobs", nil, ""))["error"].(string), "in the server log")
		signIn := serve(routes, "GET", "http://localhost:3000/cronwatch/?token="+token, nil, "")
		status(t, "sign-in", signIn, 303)
		eq(t, "location", signIn.Header().Get("Location"), "/cronwatch/")
		c := strings.Split(signIn.Header().Get("Set-Cookie"), ";")[0]
		status(t, "cookie", serve(routes, "GET", "http://localhost:3000/cronwatch/", hdr{"cookie": c}, ""), 200)
		status(t, "bearer", serve(routes, "GET", "http://localhost:3000/cronwatch/api/jobs", hdr{"authorization": "Bearer " + token}, ""), 200)

		out.Reset()
		other := must[*cronwatch.Routes](t)(cw.Routes(cronwatch.WithBasePath("/")))
		serve(other, "GET", "https://dev.example:8443/api/jobs", nil, "")
		if !regexp.MustCompile(`Sign in: /\?token=[A-Za-z0-9_-]{43} on this server \(the first request's host is not local, so the link leaves it out\)\n$`).MatchString(out.String()) {
			t.Errorf("a root mount's line: %q", out.String())
		}
		if strings.Contains(out.String(), token) {
			t.Error("each routes value makes its own token")
		}
		t.Setenv(variable, "")
	}
}

func TestRoutesAnEmptyTokenIsUnsetAndWithoutTokenOpens(t *testing.T) {
	t.Setenv("CRONWATCH_ENV", "production")
	t.Setenv("CRONWATCH_TOKEN", "")
	cw := must[*cronwatch.Client](t)(cronwatch.New(cronwatch.WithoutCronSecret()))
	jobs := func(options ...cronwatch.RoutesOption) *httptest.ResponseRecorder {
		return serve(must[*cronwatch.Routes](t)(cw.Routes(options...)), "GET", "http://app.test/cronwatch/api/jobs", nil, "")
	}
	status(t, "unset", jobs(), 503)
	status(t, "empty", jobs(cronwatch.WithToken("")), 503)
	status(t, "open", jobs(cronwatch.WithoutToken()), 200)

	out := devEnv(t)
	status(t, "open in development", jobs(cronwatch.WithoutToken()), 200)
	eq(t, "no token made", out.String(), "")
	t.Setenv("CRONWATCH_TOKEN", "envtok")
	status(t, "a configured token in development", jobs(), 401)
	eq(t, "nothing printed", out.String(), "")
	routes := must[*cronwatch.Routes](t)(cw.Routes(cronwatch.WithToken("")))
	status(t, "the environment's token", serve(routes, "GET", "http://app.test/cronwatch/api/jobs", hdr{"authorization": "Bearer envtok"}, ""), 200)
}

func TestRoutesOrigin(t *testing.T) {
	internal := "http://10.0.0.5:8080"
	app := func(options ...cronwatch.RoutesOption) (*web, func(method, path string, headers hdr, body string) *httptest.ResponseRecorder) {
		w := newWeb(t, append([]cronwatch.RoutesOption{cronwatch.WithToken("tok"), cronwatch.WithBasePath("/cronwatch")}, options...))
		check(t, w.cw.Run(bg, "x", ok))
		return w, func(method, path string, headers hdr, body string) *httptest.ResponseRecorder {
			return serve(w.routes, method, internal+path, headers, body)
		}
	}
	silenced := func(w *web) bool { return summary(t, w.cw, "x").SilencedUntil != nil }

	t.Run("the request's own origin by default", func(t *testing.T) {
		w, send := app()
		status(t, "foreign", send("POST", "/cronwatch/jobs/x/silence", join(cookie, form, hdr{"origin": "https://app.example.com"}), "for=1h"), 403)
		eq(t, "silenced", silenced(w), false)
		status(t, "own", send("POST", "/cronwatch/jobs/x/silence", join(cookie, form, hdr{"origin": internal}), "for=1h"), 303)
		if strings.Contains(send("GET", "/cronwatch/?token=tok", nil, "").Header().Get("Set-Cookie"), "Secure") {
			t.Error("Secure over http")
		}
	})
	t.Run("WithOrigin replaces it", func(t *testing.T) {
		w, send := app(cronwatch.WithOrigin("https://app.example.com/ignored/path"))
		status(t, "internal", send("POST", "/cronwatch/jobs/x/silence", join(cookie, form, hdr{"origin": internal}), "for=1h"), 403)
		eq(t, "silenced", silenced(w), false)
		referer := "https://app.example.com/cronwatch/jobs/x"
		res := send("POST", "/cronwatch/jobs/x/silence", join(cookie, form, hdr{"origin": "https://app.example.com", "referer": referer}), "for=2h")
		status(t, "public", res, 303)
		eq(t, "back", res.Header().Get("Location"), referer)
		eq(t, "until", *summary(t, w.cw, "x").SilencedUntil, T0+2*HOUR)
		signIn := send("GET", "/cronwatch/jobs/x?token=tok", nil, "")
		eq(t, "location", signIn.Header().Get("Location"), "/cronwatch/jobs/x")
		if !strings.HasSuffix(signIn.Header().Get("Set-Cookie"), "; Secure") {
			t.Error("not Secure over https")
		}
	})
	t.Run("WithOrigin wins over WithTrustProxy", func(t *testing.T) {
		_, send := app(cronwatch.WithOrigin("https://app.example.com"), cronwatch.WithTrustProxy())
		forwarded := hdr{"x-forwarded-proto": "https", "x-forwarded-host": "other.example"}
		status(t, "forwarded", send("POST", "/cronwatch/check", join(cookie, forwarded, hdr{"origin": "https://other.example"}), ""), 403)
		status(t, "configured", send("POST", "/cronwatch/check", join(cookie, forwarded, hdr{"origin": "https://app.example.com"}), ""), 303)
	})
	t.Run("WithTrustProxy takes the first forwarded values", func(t *testing.T) {
		_, send := app(cronwatch.WithTrustProxy())
		forwarded := hdr{"x-forwarded-proto": "https, http", "x-forwarded-host": "app.example.com, 10.0.0.5:8080"}
		status(t, "internal", send("POST", "/cronwatch/jobs/x/silence", join(cookie, form, forwarded, hdr{"origin": internal}), "for=1h"), 403)
		status(t, "public", send("POST", "/cronwatch/jobs/x/silence", join(cookie, form, forwarded, hdr{"origin": "https://app.example.com"}), "for=1h"), 303)
		if !strings.HasSuffix(send("GET", "/cronwatch/?token=tok", forwarded, "").Header().Get("Set-Cookie"), "; Secure") {
			t.Error("not Secure")
		}
		status(t, "proto only", send("POST", "/cronwatch/check", join(cookie, hdr{"x-forwarded-proto": "https", "origin": "https://10.0.0.5:8080"}), ""), 303)
		status(t, "neither", send("POST", "/cronwatch/check", join(cookie, hdr{"origin": internal}), ""), 303)
		for _, c := range []struct {
			headers hdr
			origin  string
		}{
			{hdr{"x-forwarded-proto": "javascript", "x-forwarded-host": "evil.example"}, "javascript://evil.example"},
			{hdr{"x-forwarded-proto": "https", "x-forwarded-host": "evil.example/path"}, "https://evil.example"},
			{hdr{"x-forwarded-proto": "https", "x-forwarded-host": "user@evil.example"}, "https://evil.example"},
		} {
			status(t, c.origin, send("POST", "/cronwatch/check", join(cookie, c.headers, hdr{"origin": c.origin}), ""), 403)
			status(t, c.origin, send("POST", "/cronwatch/check", join(cookie, c.headers, hdr{"origin": internal}), ""), 303)
		}
	})
	t.Run("without WithTrustProxy forwarded headers change nothing", func(t *testing.T) {
		w := newWeb(t, nil)
		check(t, w.cw.Run(bg, "x", ok))
		spoofed := hdr{"x-forwarded-host": "evil.example", "x-forwarded-proto": "https"}
		status(t, "foreign", w.send("POST", "/cronwatch/jobs/x/silence", join(cookie, form, spoofed, hdr{"origin": "https://evil.example"}), "for=1h"), 403)
		back := w.send("POST", "/cronwatch/check", join(cookie, spoofed, hdr{"origin": "http://app.test", "referer": "https://evil.example/cronwatch/jobs/x"}), "")
		eq(t, "back", back.Header().Get("Location"), "/cronwatch/")
		if strings.Contains(w.get("/cronwatch/?token=tok", spoofed).Header().Get("Set-Cookie"), "Secure") {
			t.Error("Secure from a spoofed header")
		}
	})
	t.Run("a bad origin is an error from Routes", func(t *testing.T) {
		cw := must[*cronwatch.Client](t)(cronwatch.New(cronwatch.WithoutCronSecret()))
		_, err := cw.Routes(cronwatch.WithToken("tok"), cronwatch.WithOrigin("app.example.com"))
		eq(t, "absolute", errText(err), `routes: origin must be an absolute URL such as "https://app.example.com", got "app.example.com"`)
		_, err = cw.Routes(cronwatch.WithToken("tok"), cronwatch.WithOrigin("ftp://app.example.com"))
		eq(t, "http", errText(err), `routes: origin must be http or https, got "ftp://app.example.com"`)
		_, err = cw.Routes(cronwatch.WithToken("tok"), cronwatch.WithOrigin(""))
		eq(t, "empty", err, nil)
	})
	t.Run("origins are read as URL#origin reads them", func(t *testing.T) {
		cw := must[*cronwatch.Client](t)(cronwatch.New(cronwatch.WithoutCronSecret()))
		for given, want := range map[string]string{
			" HTTPS://App.Example.COM:443/x ": "https://app.example.com",
			"http:\\\\example.com:8080":       "http://example.com:8080",
			"http://0x7f.1":                   "http://127.0.0.1",
			"http://[0:0::1]:80":              "http://[::1]",
			"https://bücher.example":          "https://xn--bcher-kva.example",
			"http://user:pw@example.com":      "http://example.com",
		} {
			routes := must[*cronwatch.Routes](t)(cw.Routes(cronwatch.WithToken("tok"), cronwatch.WithOrigin(given)))
			status(t, given, serve(routes, "POST", "http://10.0.0.5/cronwatch/api/check", join(auth, hdr{"origin": want}), ""), 200)
		}
	})
	t.Run("the development sign-in line uses the public origin when set or loopback, and otherwise leaves the host out", func(t *testing.T) {
		out := devEnv(t)
		cw := must[*cronwatch.Client](t)(cronwatch.New(cronwatch.WithoutCronSecret()))
		spoofed := hdr{"x-forwarded-proto": "https", "x-forwarded-host": "attacker.example"}
		for _, c := range []struct {
			options []cronwatch.RoutesOption
			url     string
			headers hdr
		}{
			{[]cronwatch.RoutesOption{cronwatch.WithOrigin("https://app.example.com")}, internal + "/cronwatch/", nil},
			{[]cronwatch.RoutesOption{cronwatch.WithOrigin("https://app.example.com"), cronwatch.WithTrustProxy()}, internal + "/cronwatch/", spoofed},
			{nil, "http://localhost:3000/cronwatch/", nil},
			{nil, "http://app.localhost:3000/cronwatch/", nil},
			{nil, "http://127.0.0.1:3000/cronwatch/", nil},
			{nil, "http://127.8.9.10/cronwatch/", nil},
			{nil, "http://[::1]:3000/cronwatch/", nil},
			{[]cronwatch.RoutesOption{cronwatch.WithTrustProxy()}, internal + "/cronwatch/", hdr{"x-forwarded-host": "localhost:5173"}},
			{nil, internal + "/cronwatch/", nil},
			{nil, "https://app.example.com/cronwatch/", nil},
			{[]cronwatch.RoutesOption{cronwatch.WithTrustProxy()}, "http://localhost:3000/cronwatch/", spoofed},
			{nil, "http://localhost.example/cronwatch/", nil},
			{nil, "http://128.0.0.1/cronwatch/", nil},
			{[]cronwatch.RoutesOption{cronwatch.WithBasePath("/")}, "http://attacker.example/", nil},
		} {
			serve(must[*cronwatch.Routes](t)(cw.Routes(c.options...)), "GET", c.url, c.headers, "")
		}
		const intro = "[cronwatch] CRONWATCH_TOKEN is not set, so this development server made a token for the dashboard. Sign in: "
		const hostless = " on this server (the first request's host is not local, so the link leaves it out)"
		expected := [][2]string{
			{"https://app.example.com/cronwatch", ""},
			{"https://app.example.com/cronwatch", ""},
			{"http://localhost:3000/cronwatch", ""},
			{"http://app.localhost:3000/cronwatch", ""},
			{"http://127.0.0.1:3000/cronwatch", ""},
			{"http://127.8.9.10/cronwatch", ""},
			{"http://[::1]:3000/cronwatch", ""},
			{"http://localhost:5173/cronwatch", ""},
			{"/cronwatch", hostless},
			{"/cronwatch", hostless},
			{"/cronwatch", hostless},
			{"/cronwatch", hostless},
			{"/cronwatch", hostless},
			{"", hostless},
		}
		lines := strings.Split(strings.TrimSpace(out.String()), "\n")
		eq(t, "lines", len(lines), len(expected))
		tokenOf := regexp.MustCompile(`token=([A-Za-z0-9_-]{43})`)
		for i, want := range expected {
			m := tokenOf.FindStringSubmatch(lines[i])
			if m == nil {
				t.Fatalf("line %d: %q", i, lines[i])
			}
			eq(t, "line "+want[0]+want[1], lines[i], intro+want[0]+"/?token="+m[1]+want[1])
		}
	})
}

func errText(err error) string {
	if err == nil {
		return "<nil>"
	}
	return err.Error()
}

func TestRoutesAppShellIsPublic(t *testing.T) {
	t.Setenv("CRONWATCH_ENV", "production")
	t.Setenv("CRONWATCH_TOKEN", "")
	for _, options := range [][]cronwatch.RoutesOption{{cronwatch.WithToken("tok")}, {}, {cronwatch.WithoutToken()}} {
		cw := must[*cronwatch.Client](t)(cronwatch.New(cronwatch.WithoutCronSecret()))
		routes := must[*cronwatch.Routes](t)(cw.Routes(options...))
		for _, path := range []string{"/manifest.webmanifest", "/sw.js", "/app.js", "/offline", "/icons/icon.svg", "/icons/icon-192.png"} {
			status(t, path, serve(routes, "GET", "http://app.test/cronwatch"+path, nil, ""), 200)
			status(t, "HEAD "+path, serve(routes, "HEAD", "http://app.test/cronwatch"+path, nil, ""), 200)
		}
	}
	w := newWeb(t, nil)
	status(t, "a write to the shell", w.send("POST", "/cronwatch/sw.js", nil, ""), 401)
	status(t, "HEAD elsewhere", w.send("HEAD", "/cronwatch/", auth, ""), 404)
}

func TestRoutesBasePath(t *testing.T) {
	cw := must[*cronwatch.Client](t)(cronwatch.New(cronwatch.WithoutCronSecret()))
	check(t, cw.Run(bg, "x", ok))
	open := must[*cronwatch.Routes](t)(cw.Routes(cronwatch.WithoutToken()))
	manifestID := func(h http.Handler, target string) string {
		rec := serve(h, "GET", target, nil, "")
		if rec.Code != 200 {
			return rec.Result().Status
		}
		var m map[string]any
		_ = json.Unmarshal(rec.Body.Bytes(), &m)
		id, _ := m["id"].(string)
		return id
	}
	eq(t, "the default", manifestID(open, "http://app.test/cronwatch/manifest.webmanifest"), "/cronwatch/")
	eq(t, "WithBasePath at the root", manifestID(must[*cronwatch.Routes](t)(cw.Routes(cronwatch.WithoutToken(), cronwatch.WithBasePath(""))), "http://app.test/manifest.webmanifest"), "/")
	eq(t, "WithBasePath", manifestID(must[*cronwatch.Routes](t)(cw.Routes(cronwatch.WithoutToken(), cronwatch.WithBasePath("/a/b/"))), "http://app.test/a/b/manifest.webmanifest"), "/a/b/")

	through := func(mount func(*http.ServeMux), target string) string {
		mux := http.NewServeMux()
		mount(mux)
		server := httptest.NewServer(mux)
		defer server.Close()
		res, err := http.Get(server.URL + target)
		if err != nil {
			t.Fatal(err)
		}
		defer res.Body.Close()
		body, _ := io.ReadAll(res.Body)
		var m map[string]any
		if json.Unmarshal(body, &m) != nil {
			return res.Status + " " + string(body)
		}
		id, _ := m["id"].(string)
		return id
	}
	eq(t, "StripPrefix", through(func(m *http.ServeMux) { m.Handle("/ops/cron/", http.StripPrefix("/ops/cron", open)) }, "/ops/cron/manifest.webmanifest"), "/ops/cron/")
	eq(t, "StripPrefix with its slash", through(func(m *http.ServeMux) { m.Handle("/ops/cron/", http.StripPrefix("/ops/cron/", open)) }, "/ops/cron/manifest.webmanifest"), "/ops/cron/")
	eq(t, "a subtree pattern", through(func(m *http.ServeMux) { m.Handle("/admin/cronwatch/", open) }, "/admin/cronwatch/manifest.webmanifest"), "/admin/cronwatch/")
	eq(t, "a method and a wildcard", through(func(m *http.ServeMux) { m.Handle("GET /t/{tenant}/cw/{rest...}", open) }, "/t/acme/cw/manifest.webmanifest"), "/t/acme/cw/")
	eq(t, "the root", through(func(m *http.ServeMux) { m.Handle("/", open) }, "/manifest.webmanifest"), "/")
	eq(t, "StripPrefix inside a pattern", through(func(m *http.ServeMux) {
		m.Handle("/x/", http.StripPrefix("/x/y", open))
	}, "/x/y/manifest.webmanifest"), "/x/y/")

	// The pages link under the base found, and the job links resolve.
	mux := http.NewServeMux()
	mux.Handle("/ops/", http.StripPrefix("/ops", open))
	server := httptest.NewServer(mux)
	defer server.Close()
	res, err := http.Get(server.URL + "/ops/")
	check(t, err)
	body, _ := io.ReadAll(res.Body)
	res.Body.Close()
	contains(t, "link", string(body), `href="/ops/jobs/x"`)
	res, err = http.Get(server.URL + "/ops/jobs/x")
	check(t, err)
	res.Body.Close()
	eq(t, "job page", res.StatusCode, 200)
	res, err = http.Get(server.URL + "/ops")
	check(t, err)
	res.Body.Close()
	eq(t, "the mount itself", res.StatusCode, 200)
}

func TestRoutesPathsAreReadAsTheURLParserLeavesThem(t *testing.T) {
	w := newWeb(t, nil)
	check(t, w.cw.Run(bg, "x", ok))
	for _, path := range []string{"/cronwatch/./jobs/x", "/cronwatch/nope/../jobs/x", "/cronwatch\\jobs\\x", "/cronwatch/%2e/jobs/x", "/cronwatch/jobs/%78"} {
		res := w.get(path, auth)
		status(t, path, res, 200)
		contains(t, path, res.Body.String(), `<h1 class="jobname">x</h1>`)
	}
	status(t, "a slash inside a name", w.get("/cronwatch/api/jobs/a%2Fb", auth), 404)
}

// The audit: an interval past what an int64 of milliseconds holds wrapped
// round, and drawing the board's timeline never ended; a silence for longer
// than that ended at once.
func TestHugeDurationsNeitherHangNorWrap(t *testing.T) {
	w := newWeb(t, nil)
	job := must[*cronwatch.Job](t)(w.cw.Job("rare", cronwatch.Schedule("every 20000000000w")))
	check(t, job.Run(bg, ok))
	w.c.Advance(10 * 24 * HOUR)
	done := make(chan []int)
	go func() {
		var codes []int
		if _, err := w.cw.Check(bg); err == nil {
			for _, path := range []string{"/cronwatch/", "/cronwatch/jobs/rare", "/cronwatch/api/jobs/rare"} {
				codes = append(codes, w.get(path, auth).Code)
			}
		}
		done <- codes
	}()
	select {
	case codes := <-done:
		sameList(t, "answered", codes, []int{200, 200, 200})
	case <-time.After(10 * time.Second):
		t.Fatal("the dashboard never answered")
	}
	silenced := decode(t, w.send("POST", "/cronwatch/api/jobs/rare/silence", join(auth, hdr{"content-type": "application/json"}), `{"for":"99999999999999999999999"}`))
	until := silenced["state"].(map[string]any)["silencedUntil"].(float64)
	if until <= float64(w.c.Now()) {
		t.Fatalf("a long silence ended at once: %v", until)
	}
}
