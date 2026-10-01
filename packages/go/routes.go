package cronwatch

// The dashboard and its small JSON API (routes/index.ts), as an
// http.Handler: the same URLs, JSON, status codes, headers, cookie,
// redirects, cross-site rule and token rules as the SDK's routes, so
// @cronwatch/mcp works against a Go app as it does against a Node one.

import (
	"context"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"errors"
	"fmt"
	"log/slog"
	"math"
	"math/big"
	"net/http"
	"os"
	"regexp"
	"strconv"
	"strings"
	"sync"

	"cronwatch.dev/go/internal/js"
	"cronwatch.dev/go/internal/schedule"
)

const (
	tokenCookie = "cronwatch_token"
	// Runs a JSON job read lists by default, and at most.
	defaultRuns = 20
	maxRuns     = 500
	// Runs per job the board reads in one go: the table's sparkline, and most jobs' lanes.
	boardPageRuns = 20
	cookieMaxAge  = 60 * 60 * 24 * 30
	// DefaultBasePath is where the dashboard is taken to be mounted when
	// nothing else says: not WithBasePath, not http.StripPrefix, not a
	// ServeMux pattern.
	DefaultBasePath = "/cronwatch"
)

// 'self' only for what the app shell needs: app.js (which registers the
// service worker and nothing else), the manifest, the worker and the icons.
// No inline script, and the pages work without any.
const (
	pageCSP  = "default-src 'none'; script-src 'self'; style-src 'unsafe-inline'; img-src 'self' data:; manifest-src 'self'; worker-src 'self'; form-action 'self'; frame-ancestors 'none'; base-uri 'none'"
	assetCSP = "default-src 'none'; style-src 'unsafe-inline'; frame-ancestors 'none'"
)

// securityHeaders go on every answer. same-origin rather than no-referrer:
// under no-referrer browsers send `Origin: null` on form posts, which the
// cross-site check would refuse, and the forms redirect back to the page
// named by the same-origin Referer.
var securityHeaders = [][2]string{{"X-Content-Type-Options", "nosniff"}, {"Referrer-Policy", "same-origin"}, {"X-Robots-Tag", "noindex"}}

// RoutesOption configures the dashboard (Client.Routes).
type RoutesOption func(*routesConfig)

type routesConfig struct {
	token      string
	open       bool
	base       *string
	origin     string
	trustProxy bool
}

// WithToken is the token the dashboard asks for. Send it as
// `Authorization: Bearer <token>`, or open the dashboard once with
// ?token=<token> and a cookie is set. The default is CRONWATCH_TOKEN; ""
// counts as unset. With no token in development (CRONWATCH_ENV, APP_ENV or
// GO_ENV naming it), the routes make a random one and print a sign-in link
// to Stdout on their first request; with no token otherwise they answer
// 503. /api/check also takes the client's cron secret as a bearer, so a
// platform cron can run checks without the token.
func WithToken(token string) RoutesOption {
	return func(c *routesConfig) { c.token, c.open = token, false }
}

// WithoutToken serves the dashboard to anyone, everywhere, for one behind
// your own auth (the SDK's `token: null`).
func WithoutToken() RoutesOption { return func(c *routesConfig) { c.token, c.open = "", true } }

// WithBasePath is where the dashboard is mounted ("" for the root), so its
// links resolve. Without it the base is found from the request: what
// http.StripPrefix took off, else the literal part of the ServeMux
// pattern that matched (Go 1.22's "/cronwatch/" or "/cronwatch/{path...}"),
// else DefaultBasePath.
func WithBasePath(path string) RoutesOption {
	return func(c *routesConfig) {
		trimmed := strings.TrimRight(path, "/")
		c.base = &trimmed
	}
}

// WithOrigin is the public origin the dashboard is served from, such as
// "https://app.example.com", for an app behind a proxy whose requests carry
// an internal host or scheme. It stands in for the request's own origin in
// the cross-site check on writes, the sign-in cookie's Secure flag, the
// Referer the redirect back after a form follows, and the development
// sign-in line. Anything that is not an http or https URL is an error from
// Routes. It takes precedence over WithTrustProxy.
func WithOrigin(origin string) RoutesOption { return func(c *routesConfig) { c.origin = origin } }

// WithTrustProxy takes the public origin from X-Forwarded-Proto and
// X-Forwarded-Host (the first value of each, the request's own scheme or
// host for whichever is missing) when a request carries either. Only for an
// app whose proxy sets or overwrites both headers: a client can send them
// too.
func WithTrustProxy() RoutesOption { return func(c *routesConfig) { c.trustProxy = true } }

// Routes is the dashboard and JSON API, an http.Handler made by
// Client.Routes.
type Routes struct {
	c          *Client
	optedOut   bool
	token      string
	generated  bool
	cookie     string
	base       *string
	origin     string
	trustProxy bool
	announce   sync.Once
}

// String names the routes and where they are mounted, and says whether a
// token is set, never the token or its cookie: fmt and loggers print a
// value's fields otherwise.
func (rt *Routes) String() string {
	if rt == nil {
		return "cronwatch.Routes(nil)"
	}
	base := "found from the mount"
	if rt.base != nil {
		base = strconv.Quote(*rt.base)
	}
	return "cronwatch.Routes{base: " + base + ", token: " + secretState(rt.token != "") + "}"
}

// GoString is String, for %#v.
func (rt *Routes) GoString() string { return rt.String() }

// LogValue is what log/slog writes for the routes: String's fields.
func (rt *Routes) LogValue() slog.Value {
	if rt == nil {
		return slog.StringValue("cronwatch.Routes(nil)")
	}
	base := ""
	if rt.base != nil {
		base = *rt.base
	}
	return slog.GroupValue(slog.String("base", base), slog.String("token", secretState(rt.token != "")))
}

// secretState is how a secret is printed: whether it is set.
func secretState(set bool) string {
	if set {
		return "set"
	}
	return "none"
}

// Routes is the dashboard and its JSON API as an http.Handler, the SDK's
// cw.routes(). Mount it under a prefix with http.StripPrefix or a ServeMux
// pattern:
//
//	routes, err := cw.Routes(cronwatch.WithToken(os.Getenv("CRONWATCH_TOKEN")))
//	mux.Handle("/cronwatch/", routes)                              // the base is /cronwatch
//	mux.Handle("/ops/cron/", http.StripPrefix("/ops/cron", routes)) // the base is /ops/cron
//
// The error is for a WithOrigin value that is not an http or https URL.
func (c *Client) Routes(options ...RoutesOption) (*Routes, error) {
	cfg := routesConfig{}
	for _, o := range options {
		o(&cfg)
	}
	origin, err := configuredOrigin(cfg.origin)
	if err != nil {
		return nil, err
	}
	rt := &Routes{c: c, optedOut: cfg.open, base: cfg.base, origin: origin, trustProxy: cfg.trustProxy}
	configured := ""
	if !cfg.open {
		configured = cfg.token
		if configured == "" {
			configured = os.Getenv("CRONWATCH_TOKEN")
		}
	}
	// A handler cannot tell a local caller from a remote one (proxies,
	// tunnels and a server listening on every interface all look alike), so
	// development gets a token too: made here, and shown only in the log.
	rt.generated = configured == "" && !cfg.open && environment() == "development"
	rt.token = configured
	if rt.generated {
		rt.token = developmentToken()
	}
	if rt.token != "" {
		sum := sha256.Sum256([]byte("cronwatch-cookie:" + rt.token))
		rt.cookie = hex.EncodeToString(sum[:])
	}
	return rt, nil
}

// MustRoutes is Routes for a package-level declaration: it panics where
// Routes returns an error.
func (c *Client) MustRoutes(options ...RoutesOption) *Routes {
	rt, err := c.Routes(options...)
	if err != nil {
		panic(err)
	}
	return rt
}

// Token is the token the dashboard asks for (the generated one in
// development), or "" when it is open or locked for want of one.
func (rt *Routes) Token() string { return rt.token }

// developmentToken is 32 random bytes, base64url (43 characters).
func developmentToken() string {
	b := make([]byte, 32)
	_, _ = rand.Read(b)
	return base64.RawURLEncoding.EncodeToString(b)
}

// developmentSignInLine is the line a development token is announced
// with, once, on the routes' first request. origin is the WithOrigin value
// when set, otherwise that request's public origin when its host is
// loopback, and "" for any other host: the request's host is the client's
// to choose, so the line then leaves it out rather than point the link,
// token and all, somewhere else. base is the base path without a trailing
// slash.
func developmentSignInLine(origin, base, token string) string {
	const intro = "[cronwatch] CRONWATCH_TOKEN is not set, so this development server made a token for the dashboard. Sign in: "
	if origin == "" {
		return intro + base + "/?token=" + token + " on this server (the first request's host is not local, so the link leaves it out)"
	}
	return intro + origin + base + "/?token=" + token
}

var loopbackV4 = regexp.MustCompile(`^127\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$`)

// isLoopbackOrigin reports whether an origin's host is loopback:
// "localhost", a name ending in ".localhost", an IPv4 address in
// 127.0.0.0/8, or the IPv6 address ::1. Only an origin that reads as one
// counts: a Host header is anyone's to send, and one such as
// "evil.example/.localhost" or "localhost:1@evil.example" must not put the
// development token in a link to another host, whether or not the server
// in front refuses such a header first.
func isLoopbackOrigin(origin string) bool {
	origin, ok := bareOrigin(origin)
	if !ok {
		return false
	}
	authority := origin
	if i := strings.Index(origin, "://"); i >= 0 {
		authority = origin[i+3:]
	}
	host := authority
	if strings.HasPrefix(authority, "[") {
		if end := strings.Index(authority, "]"); end >= 0 {
			host = authority[:end+1]
		}
	} else if i := strings.Index(authority, ":"); i >= 0 {
		host = authority[:i]
	}
	host = strings.ToLower(host)
	if host == "localhost" || host == "[::1]" || strings.HasSuffix(host, ".localhost") {
		return true
	}
	m := loopbackV4.FindStringSubmatch(host)
	if m == nil {
		return false
	}
	for _, octet := range m[1:] {
		if n, _ := strconv.Atoi(octet); n > 255 {
			return false
		}
	}
	return true
}

// answer is a response the routes built, written once.
type answer struct {
	status  int
	headers [][2]string
	body    []byte
}

func (a answer) write(w http.ResponseWriter) {
	h := w.Header()
	for _, kv := range a.headers {
		h.Set(kv[0], kv[1])
	}
	h.Set("Content-Length", strconv.Itoa(len(a.body)))
	w.WriteHeader(a.status)
	if len(a.body) > 0 {
		_, _ = w.Write(a.body)
	}
}

func apiAnswer(body any, status int, extra ...[2]string) answer {
	headers := append([][2]string{{"Content-Type", "application/json; charset=utf-8"}, {"Cache-Control", "no-store"}}, securityHeaders...)
	return answer{status, append(headers, extra...), []byte(js.Stringify(body))}
}

func redirectAnswer(location string, extra ...[2]string) answer {
	headers := append([][2]string{{"Location", location}, {"Cache-Control", "no-store"}}, securityHeaders...)
	return answer{status: http.StatusSeeOther, headers: append(headers, extra...)}
}

func htmlAnswer(body string, status int, cache string) answer {
	headers := append([][2]string{
		{"Content-Type", "text/html; charset=utf-8"}, {"Cache-Control", cache},
		{"Content-Security-Policy", pageCSP}, {"X-Frame-Options", "DENY"},
	}, securityHeaders...)
	return answer{status, headers, []byte(body)}
}

func page(body string, status int) answer { return htmlAnswer(body, status, "no-store") }

// shellAnswer is an app shell file. The worker may be scoped to the base
// (it is served from there anyway); the SVGs get a CSP of their own.
func shellAnswer(asset shellAsset, base string) answer {
	headers := append([][2]string{{"Content-Type", asset.typ}, {"Cache-Control", asset.cache}}, securityHeaders...)
	if asset.typ == "image/svg+xml" {
		headers = append(headers, [2]string{"Content-Security-Policy", assetCSP})
	}
	if asset.worker {
		headers = append(headers, [2]string{"Service-Worker-Allowed", base + "/"})
	}
	return answer{http.StatusOK, headers, asset.body}
}

func tooLarge(wantsHTML bool, base string) answer {
	if wantsHTML {
		return page(messagePage("Not silenced", "The request was too large.", base, false), http.StatusRequestEntityTooLarge)
	}
	return apiAnswer(js.NewObject("ok", false, "error", "Request body too large"), http.StatusRequestEntityTooLarge)
}

// basePath is where the dashboard is mounted, for a request whose full
// path (as sent) is full. See WithBasePath.
func (rt *Routes) basePath(r *http.Request, full string) string {
	if rt.base != nil {
		return *rt.base
	}
	// http.StripPrefix leaves in r.URL the path under the mount.
	if rest := r.URL.EscapedPath(); rest != full && strings.HasSuffix(full, rest) {
		return strings.TrimRight(full[:len(full)-len(rest)], "/")
	}
	// A ServeMux pattern: "/cronwatch/", "/cronwatch/{path...}",
	// "GET example.com/ops/{tenant}/cron/" are mounted at as many segments of
	// the request's path as the pattern has before its end.
	if pattern := r.Pattern; pattern != "" {
		if i := strings.LastIndexAny(pattern, " \t"); i >= 0 {
			pattern = pattern[i+1:]
		}
		if i := strings.IndexByte(pattern, '/'); i >= 0 {
			segments := strings.Split(pattern[i:], "/")
			last := segments[len(segments)-1]
			n := len(segments)
			if last == "" || last == "{$}" || (strings.HasPrefix(last, "{") && strings.HasSuffix(last, "...}")) {
				n--
			}
			parts := strings.Split(full, "/")
			if len(parts) >= n {
				return strings.TrimRight(strings.Join(parts[:n], "/"), "/")
			}
		}
	}
	return DefaultBasePath
}

// cookiePath is the sign-in cookie's Path: the base, or "/" when the base is
// the root or holds a character that has no place in a cookie attribute
// (";", ",", a space or control, anything past ASCII). A base found from a
// ServeMux wildcard is the request's own text, so a crafted link could
// otherwise add attributes (Domain=...) to a cookie that is as good as the
// token.
func cookiePath(base string) string {
	if base == "" {
		return "/"
	}
	for i := 0; i < len(base); i++ {
		if c := base[i]; c <= ' ' || c >= 0x7f || c == ';' || c == ',' {
			return "/"
		}
	}
	return base
}

// ServeHTTP answers one request as the SDK's routes answer it. A store
// failure (or a panic) is reported to the client's error handler as
// "routes" and answered 500.
func (rt *Routes) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	raw, query := requestTarget(r)
	base := rt.basePath(r, raw)
	pathname := normalizePath(raw)
	path := stripBase(pathname, base)
	wantsHTML := !strings.HasPrefix(path, "/api")
	failed := func(err error) answer {
		// A request that ended first (the caller gave up, its deadline
		// passed) failed for that alone, and nobody reads the answer:
		// reporting each would only be noise.
		ended := r.Context().Err()
		if ended == nil || !(errors.Is(err, ended) || errors.Is(err, context.Cause(r.Context()))) {
			rt.c.report(err, "routes")
		}
		if wantsHTML {
			return page(messagePage("Something went wrong", "The request failed and the error was reported.", base, false), http.StatusInternalServerError)
		}
		return apiAnswer(js.NewObject("ok", false, "error", "Internal error"), http.StatusInternalServerError)
	}
	a := func() (a answer) {
		defer func() {
			if p := recover(); p != nil {
				if p == http.ErrAbortHandler {
					panic(p)
				}
				a = failed(fmt.Errorf("panic: %v", p))
			}
		}()
		a, err := rt.serve(r, pathname, path, query, base, wantsHTML)
		if err != nil {
			return failed(err)
		}
		return a
	}()
	a.write(w)
}

// publicOrigin is the origin a browser sees: WithOrigin's, the forwarded
// one under WithTrustProxy, else the request's own.
func (rt *Routes) publicOrigin(r *http.Request) string {
	if rt.origin != "" {
		return rt.origin
	}
	own := requestOrigin(r)
	if !rt.trustProxy {
		return own
	}
	proto, hasProto := firstValue(r, "X-Forwarded-Proto")
	host, hasHost := firstValue(r, "X-Forwarded-Host")
	if !hasProto && !hasHost {
		return own
	}
	proto = strings.ToLower(proto)
	if hasProto && proto != "http" && proto != "https" {
		return own
	}
	ownScheme, ownHost, _ := strings.Cut(own, "://")
	if !hasProto {
		proto = ownScheme
	}
	if !hasHost {
		host = ownHost
	}
	if built, ok := bareOrigin(proto + "://" + host); ok {
		return built
	}
	return own
}

// firstValue is the first entry of a comma-separated header, trimmed, or
// false when there is none.
func firstValue(r *http.Request, name string) (string, bool) {
	value, ok := header(r, name)
	if !ok {
		return "", false
	}
	first, _, _ := strings.Cut(value, ",")
	first = js.Trim(latin1(first))
	return first, first != ""
}

// readCookie is the named cookie, decoded, or false; a malformed escape
// counts as no cookie.
func readCookie(r *http.Request, name string) (string, bool) {
	value, ok := header(r, "Cookie")
	if !ok || value == "" {
		return "", false
	}
	for _, part := range strings.Split(value, ";") {
		pieces := strings.Split(js.Trim(latin1(part)), "=")
		if pieces[0] == name {
			return safeDecode(strings.Join(pieces[1:], "="))
		}
	}
	return "", false
}

// crossSite: a browser attaches Origin or Sec-Fetch-Site to a cross-site
// form post, and a page cannot forge either. Non-browser clients send
// neither.
func crossSite(r *http.Request, publicOrigin string) bool {
	if origin, ok := header(r, "Origin"); ok && origin != publicOrigin {
		return true
	}
	site, ok := header(r, "Sec-Fetch-Site")
	return ok && site != "same-origin" && site != "none"
}

// bearer is the Authorization header without its "Bearer " (in any case,
// with any spaces after it), or false when there is none.
func bearer(r *http.Request) (string, bool) {
	value, ok := header(r, "Authorization")
	if !ok {
		return "", false
	}
	text := latin1(value)
	if len(text) > 6 && strings.EqualFold(text[:6], "bearer") {
		if rest := strings.TrimLeftFunc(text[6:], js.IsSpace); len(rest) < len(text)-6 {
			return rest, true
		}
	}
	return text, true
}

var wholeOrDecimal = regexp.MustCompile(`^[0-9]+(\.[0-9]+)?$`)

// silenceDuration: absent means one hour; a number or numeric string is
// milliseconds. The error is the SDK's for anything else.
func silenceDuration(value string, present bool) (float64, error) {
	var d any = "1h"
	if present {
		text := js.Trim(value)
		d = text
		if wholeOrDecimal.MatchString(text) {
			n, _ := strconv.ParseFloat(text, 64)
			d = n
		}
	}
	return schedule.ParseDuration(d, "silence duration")
}

var (
	decimalNumber = regexp.MustCompile(`^[+-]?([0-9]+\.?[0-9]*|\.[0-9]+)([eE][+-]?[0-9]+)?$`)
	radixNumber   = regexp.MustCompile(`^0([xXoObB])([0-9a-fA-F]+)$`)
)

// numberOf is Number(text): decimal, 0x, 0o or 0b, Infinity, or NaN.
func numberOf(text string) float64 {
	text = js.Trim(text)
	switch {
	case text == "":
		return 0
	case decimalNumber.MatchString(text):
		n, _ := strconv.ParseFloat(text, 64)
		return n
	case text == "Infinity" || text == "+Infinity":
		return math.Inf(1)
	case text == "-Infinity":
		return math.Inf(-1)
	}
	if m := radixNumber.FindStringSubmatch(text); m != nil {
		base := map[byte]int{'x': 16, 'o': 8, 'b': 2}[strings.ToLower(m[1])[0]]
		n, ok := new(big.Int).SetString(m[2], base)
		if !ok {
			return math.NaN()
		}
		f, _ := new(big.Float).SetInt(n).Float64()
		return f
	}
	return math.NaN()
}

func runsLimit(value string, present bool) int {
	n := math.NaN()
	if present && js.Trim(value) != "" {
		n = math.Trunc(numberOf(value))
	}
	if math.IsNaN(n) || math.IsInf(n, 0) {
		return defaultRuns
	}
	return int(math.Min(maxRuns, math.Max(1, n)))
}

// silenceFor silences a job for ms milliseconds, a value the SDK's
// parseDuration read.
func (c *Client) silenceFor(ctx context.Context, name string, ms float64) (JobState, error) {
	return c.patchState(ctx, name, func(s *JobState) { s.SilencedUntil = ptr(silenceEnd(c.now(), ms)) })
}

// boardLanes are the board's timeline lanes, the first boardLanes jobs. The
// runs already read for the table usually cover the last day; only a job
// whose twenty newest runs all fall inside it is read again, deeper.
func (rt *Routes) boardLanes(ctx context.Context, entries []JobWithRuns, now int64) ([]laneInput, error) {
	from := now - boardBehindMs
	lanes := []laneInput{}
	for _, e := range entries[:min(boardLanes, len(entries))] {
		short := len(e.Runs) >= boardPageRuns && e.Runs[len(e.Runs)-1].StartedAt > from
		if !short {
			lanes = append(lanes, laneInput{e.Job, e.Runs, true})
			continue
		}
		deeper, err := rt.c.Runs(ctx, e.Job.Name, boardRuns)
		if err != nil {
			return nil, err
		}
		lanes = append(lanes, laneInput{e.Job, deeper, len(deeper) < boardRuns})
	}
	return lanes, nil
}

func (rt *Routes) serve(r *http.Request, pathname, path, rawQuery, base string, wantsHTML bool) (answer, error) {
	ctx := r.Context()
	cw := rt.c
	method := strings.ToUpper(r.Method)
	publicOrigin := rt.publicOrigin(r)
	query := parseForm(rawQuery)

	if rt.generated {
		rt.announce.Do(func() {
			shown := rt.origin
			if shown == "" && isLoopbackOrigin(publicOrigin) {
				shown = publicOrigin
			}
			fmt.Fprintln(Stdout, developmentSignInLine(shown, base, rt.token))
		})
	}

	// The app shell: the manifest, icons, service worker, app.js and the
	// offline page. Served to anyone, since a browser fetches some of it
	// without cookies and none of it says anything about the jobs.
	if method == http.MethodGet || method == http.MethodHead {
		if path == "/offline" {
			return htmlAnswer(messagePage("You are offline", "CronWatch shows live data from your app, so it needs a connection.", base, false), http.StatusOK, "no-cache"), nil
		}
		if asset, ok := staticAsset(path, base); ok {
			return shellAnswer(asset, base), nil
		}
	}

	// No token outside development: fail closed.
	if rt.token == "" && !rt.optedOut {
		if wantsHTML {
			return page(messagePage("CronWatch routes are locked", "Set CRONWATCH_TOKEN (or pass cronwatch.WithToken to Routes), or pass cronwatch.WithoutToken() to serve them open behind your own auth.", base, false), http.StatusServiceUnavailable), nil
		}
		return apiAnswer(js.NewObject("ok", false, "error", "CRONWATCH_TOKEN is not set"), http.StatusServiceUnavailable), nil
	}

	if method != http.MethodGet && method != http.MethodHead && crossSite(r, publicOrigin) {
		if wantsHTML {
			return page(messagePage("Cross-site request refused", "Changes can only be made from the dashboard itself.", base, false), http.StatusForbidden), nil
		}
		return apiAnswer(js.NewObject("ok", false, "error", "Cross-site request refused"), http.StatusForbidden), nil
	}

	sentBearer, hasBearer := bearer(r)
	if rt.token != "" {
		// ?token= is only the sign-in that moves the token into a cookie.
		queryToken, hasQuery := "", false
		if wantsHTML && method == http.MethodGet {
			queryToken, hasQuery = param(query, "token")
		}
		sent, hasCookie := readCookie(r, tokenCookie)
		cronSecretOK := path == "/api/check" && hasBearer && cw.cronSecret != "" && constantTimeEqual(sentBearer, cw.cronSecret)
		var tokenOK bool
		switch {
		case hasBearer:
			tokenOK = constantTimeEqual(sentBearer, rt.token)
		case hasQuery:
			tokenOK = constantTimeEqual(queryToken, rt.token)
		default:
			tokenOK = hasCookie && constantTimeEqual(sent, rt.cookie)
		}
		if !cronSecretOK && !tokenOK {
			if rt.generated {
				if wantsHTML {
					return page(messagePage("Sign in", "CRONWATCH_TOKEN is not set, so this development server made a token. The sign-in link is in the server log: open it once and this browser stays signed in.", base, true), http.StatusUnauthorized), nil
				}
				return apiAnswer(js.NewObject("ok", false, "error", "Unauthorized: CRONWATCH_TOKEN is not set, so this development server made a token; it is in the server log"), http.StatusUnauthorized), nil
			}
			if wantsHTML {
				return page(messagePage("Sign in", "Open this page with ?token=<your CRONWATCH_TOKEN> once and it will stay signed in.", base, true), http.StatusUnauthorized), nil
			}
			return apiAnswer(js.NewObject("ok", false, "error", "Unauthorized"), http.StatusUnauthorized), nil
		}
		if hasQuery {
			// Move the token from the URL into a cookie so it is not in history or logs.
			var rest []string
			for _, p := range query {
				if p.name != "token" {
					rest = append(rest, formEncode(p.name)+"="+formEncode(p.value))
				}
			}
			search := ""
			if len(rest) > 0 {
				search = "?" + strings.Join(rest, "&")
			}
			secure := ""
			if strings.HasPrefix(publicOrigin, "https:") {
				secure = "; Secure"
			}
			return redirectAnswer(pathname+search, [2]string{"Set-Cookie",
				tokenCookie + "=" + rt.cookie + "; Path=" + cookiePath(base) + "; HttpOnly; SameSite=Lax; Max-Age=" + strconv.Itoa(cookieMaxAge) + secure}), nil
		}
	}

	redirectBack := func() answer {
		referer, _ := header(r, "Referer")
		if strings.HasPrefix(referer, publicOrigin+"/") {
			return redirectAnswer(referer)
		}
		return redirectAnswer(base + "/")
	}
	var parts []string
	for _, part := range strings.Split(path, "/") {
		if part == "" {
			continue
		}
		decoded, ok := safeDecode(part)
		if !ok {
			if wantsHTML {
				return page(messagePage("Bad request", "The path is not valid.", base, false), http.StatusBadRequest), nil
			}
			return apiAnswer(js.NewObject("ok", false, "error", "Bad path"), http.StatusBadRequest), nil
		}
		parts = append(parts, decoded)
	}

	// HTML
	switch {
	case method == http.MethodGet && path == "/":
		entries, err := cw.JobsWithRuns(ctx, boardPageRuns)
		if err != nil {
			return answer{}, err
		}
		now := cw.now()
		runsByJob := map[string][]Run{}
		jobs := make([]JobSummary, len(entries))
		for i, e := range entries {
			runsByJob[e.Job.Name] = e.Runs
			jobs[i] = e.Job
		}
		lanes, err := rt.boardLanes(ctx, entries, now)
		if err != nil {
			return answer{}, err
		}
		return page(dashboardPage(jobs, runsByJob, now, base, nil, lanes), http.StatusOK), nil
	case method == http.MethodGet && len(parts) == 2 && parts[0] == "jobs":
		job, err := cw.JobSummary(ctx, parts[1])
		if err != nil {
			return answer{}, err
		}
		if job == nil {
			return page(messagePage("No such job", parts[1]+" is not in the store.", base, false), http.StatusNotFound), nil
		}
		now := cw.now()
		// Enough runs to draw the job's week; the page lists the newest fifty.
		limit := weekRunsLimit(*job, now)
		runs, err := cw.Runs(ctx, job.Name, limit)
		if err != nil {
			return answer{}, err
		}
		return page(jobPage(*job, runs, now, base, len(runs) < limit), http.StatusOK), nil
	case method == http.MethodPost && path == "/check":
		if _, err := cw.Check(ctx); err != nil {
			return answer{}, err
		}
		return redirectBack(), nil
	case method == http.MethodPost && len(parts) == 3 && parts[0] == "jobs":
		name, action := parts[1], parts[2]
		if action == "forget" {
			if err := cw.Forget(ctx, name); err != nil {
				return answer{}, err
			}
			return redirectAnswer(base + "/"), nil
		}
		if action != "silence" && action != "unsilence" {
			return page(messagePage("Not found", path, base, false), http.StatusNotFound), nil
		}
		job, err := cw.JobSummary(ctx, name)
		if err != nil {
			return answer{}, err
		}
		if job == nil {
			return page(messagePage("No such job", name+" is not in the store.", base, false), http.StatusNotFound), nil
		}
		if action == "silence" {
			data, err := readLimited(r)
			if errors.Is(err, errBodyTooLarge) {
				return tooLarge(true, base), nil
			}
			value, present := readBody(r, data)["for"]
			ms, err := silenceDuration(value, present)
			if err != nil {
				return page(messagePage("Not silenced", err.Error(), base, false), http.StatusBadRequest), nil
			}
			if _, err := cw.silenceFor(ctx, name, ms); err != nil {
				return answer{}, err
			}
		} else if _, err := cw.Unsilence(ctx, name); err != nil {
			return answer{}, err
		}
		return redirectBack(), nil
	}

	// JSON API
	if len(parts) > 0 && parts[0] == "api" {
		return rt.serveAPI(r, method, parts[1:], query, hasBearer)
	}
	return page(messagePage("Not found", path, base, false), http.StatusNotFound), nil
}

// What GET <base>/api says is serving it: the module, as its path names it,
// and the language. apiVersion is the dashboard JSON API's version; it goes
// up only for a change that is not additive (a field removed or retyped, a
// path moved), and such a change waits for a major release.
const (
	apiLibrary  = "cronwatch.dev/go"
	apiLanguage = "go"
	apiVersion  = 1
)

// summaryAnswer is the job's summary after a silence or an unsilence, as
// GET <base>/api/jobs/:name has it. The change was made, so a job forgotten
// since (a DELETE between the two) is ok with a null job, as the SDK has it.
func summaryAnswer(ctx context.Context, cw *Client, name string) (answer, error) {
	job, err := cw.JobSummary(ctx, name)
	if err != nil {
		return answer{}, err
	}
	if job == nil {
		return apiAnswer(js.NewObject("ok", true, "job", nil), http.StatusOK), nil
	}
	return apiAnswer(js.NewObject("ok", true, "job", *job), http.StatusOK), nil
}

func (rt *Routes) serveAPI(r *http.Request, method string, rest []string, query []formPair, hasBearer bool) (answer, error) {
	ctx := r.Context()
	cw := rt.c
	noSuchJob := apiAnswer(js.NewObject("ok", false, "error", "No such job"), http.StatusNotFound)
	exists := func(name string) (bool, error) {
		job, err := cw.JobSummary(ctx, name)
		return job != nil, err
	}
	switch {
	case method == http.MethodGet && len(rest) == 0:
		// What is serving the API, so a client such as @cronwatch/mcp can tell.
		return apiAnswer(js.NewObject("ok", true, "library", apiLibrary, "language", apiLanguage, "version", Version, "api", apiVersion), http.StatusOK), nil
	case method == http.MethodGet && len(rest) == 1 && rest[0] == "jobs":
		jobs, err := cw.Jobs(ctx)
		if err != nil {
			return answer{}, err
		}
		list := make([]any, len(jobs))
		for i, j := range jobs {
			list[i] = j
		}
		return apiAnswer(js.NewObject("ok", true, "jobs", list), http.StatusOK), nil
	case len(rest) == 2 && rest[0] == "jobs" && method == http.MethodGet:
		job, err := cw.JobSummary(ctx, rest[1])
		if err != nil {
			return answer{}, err
		}
		if job == nil {
			return noSuchJob, nil
		}
		value, present := param(query, "runs")
		runs, err := cw.Runs(ctx, rest[1], runsLimit(value, present))
		if err != nil {
			return answer{}, err
		}
		list := make([]any, len(runs))
		for i, run := range runs {
			list[i] = run
		}
		return apiAnswer(js.NewObject("ok", true, "job", *job, "runs", list), http.StatusOK), nil
	case len(rest) == 2 && rest[0] == "jobs" && method == http.MethodDelete:
		found, err := exists(rest[1])
		if err != nil || !found {
			return noSuchJob, err
		}
		if err := cw.Forget(ctx, rest[1]); err != nil {
			return answer{}, err
		}
		return apiAnswer(js.NewObject("ok", true), http.StatusOK), nil
	case method == http.MethodPost && len(rest) == 3 && rest[0] == "jobs":
		name := rest[1]
		found, err := exists(name)
		if err != nil || !found {
			return noSuchJob, err
		}
		switch rest[2] {
		case "silence":
			data, err := readLimited(r)
			if errors.Is(err, errBodyTooLarge) {
				return tooLarge(false, ""), nil
			}
			value, present := readBody(r, data)["for"]
			if !present {
				value, present = param(query, "for")
			}
			ms, err := silenceDuration(value, present)
			if err != nil {
				return apiAnswer(js.NewObject("ok", false, "error", err.Error()), http.StatusBadRequest), nil
			}
			if _, err := cw.silenceFor(ctx, name, ms); err != nil {
				return answer{}, err
			}
			return summaryAnswer(ctx, cw, name)
		case "unsilence":
			if _, err := cw.Unsilence(ctx, name); err != nil {
				return answer{}, err
			}
			return summaryAnswer(ctx, cw, name)
		}
	case len(rest) == 1 && rest[0] == "check":
		// A page cannot send an Authorization header cross-site, so a GET
		// may only run the check when it carries a bearer (token or cron secret).
		if method == http.MethodGet && !hasBearer {
			return apiAnswer(js.NewObject("ok", false, "error", "Use POST, or GET with an Authorization bearer"), http.StatusMethodNotAllowed, [2]string{"Allow", "POST"}), nil
		}
		if method == http.MethodGet || method == http.MethodPost {
			result, err := cw.Check(ctx)
			if err != nil {
				return answer{}, err
			}
			body := js.NewObject("ok", true)
			if o, ok := result.JSValue().(*js.Object); ok {
				for _, k := range o.Keys() {
					v, _ := o.Get(k)
					body.Set(k, v)
				}
			}
			return apiAnswer(body, http.StatusOK), nil
		}
	case method == http.MethodGet && len(rest) == 2 && rest[0] == "runs":
		run, err := cw.GetRun(ctx, rest[1])
		if err != nil {
			return answer{}, err
		}
		if run == nil {
			return apiAnswer(js.NewObject("ok", false, "error", "No such run"), http.StatusNotFound), nil
		}
		return apiAnswer(js.NewObject("ok", true, "run", *run), http.StatusOK), nil
	}
	return apiAnswer(js.NewObject("ok", false, "error", "Not found"), http.StatusNotFound), nil
}
