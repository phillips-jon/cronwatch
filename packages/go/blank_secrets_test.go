package cronwatch_test

// A token or cron secret of only whitespace counts as unset, as the SDK's
// routes-security and client-hardening tests have it; only a Bearer
// Authorization header is a bearer; the sign-in form posts the token.

import (
	"context"
	"net/http"
	"net/url"
	"strings"
	"testing"

	cronwatch "cronwatch.dev/go"
	"cronwatch.dev/go/storetest"
)

// production is an environment that is not development, with nothing set.
func production(t *testing.T) {
	t.Helper()
	t.Setenv("CRONWATCH_ENV", "production")
	t.Setenv("APP_ENV", "")
	t.Setenv("GO_ENV", "")
	t.Setenv("CRONWATCH_TOKEN", "")
	t.Setenv("CRON_SECRET", "")
}

var blanks = []string{"", " ", "  ", "\t", " \n  \ufeff ", "\u00a0", "\u2003"}

func TestRoutesABlankTokenCountsAsUnset(t *testing.T) {
	production(t)
	cw := must[*cronwatch.Client](t)(cronwatch.New(cronwatch.WithStore(cronwatch.NewMemoryStore()), cronwatch.WithoutCronSecret()))
	locked := func(what string, routes *cronwatch.Routes, value string) {
		t.Helper()
		status(t, what+" api", serve(routes, "GET", "http://app.test/cronwatch/api/jobs", nil, ""), 503)
		page := serve(routes, "GET", "http://app.test/cronwatch/?token="+url.QueryEscape(value), nil, "")
		status(t, what+" ?token=", page, 503)
		eq(t, what+" no cookie", page.Header().Get("Set-Cookie"), "")
		status(t, what+" bearer", serve(routes, "GET", "http://app.test/cronwatch/api/jobs", hdr{"authorization": "Bearer  "}, ""), 503)
	}
	for _, value := range blanks {
		t.Setenv("CRONWATCH_TOKEN", value)
		locked("CRONWATCH_TOKEN="+url.QueryEscape(value), must[*cronwatch.Routes](t)(cw.Routes()), value)
		t.Setenv("CRONWATCH_TOKEN", "")
		locked("WithToken("+url.QueryEscape(value)+")", must[*cronwatch.Routes](t)(cw.Routes(cronwatch.WithToken(value))), value)
	}

	// A blank token in code falls back to the variable.
	t.Setenv("CRONWATCH_TOKEN", "from-env")
	routes := must[*cronwatch.Routes](t)(cw.Routes(cronwatch.WithToken(" \t")))
	status(t, "the variable's token", serve(routes, "GET", "http://app.test/cronwatch/api/jobs", hdr{"authorization": "Bearer from-env"}, ""), 200)

	// A token that is more than whitespace is used untrimmed.
	t.Setenv("CRONWATCH_TOKEN", " padded ")
	routes = must[*cronwatch.Routes](t)(cw.Routes())
	status(t, "padded", serve(routes, "GET", "http://app.test/cronwatch/?token=%20padded%20", nil, ""), 303)
	status(t, "trimmed is not it", serve(routes, "GET", "http://app.test/cronwatch/?token=padded", nil, ""), 401)
}

func TestHandlerABlankCronSecretCountsAsUnset(t *testing.T) {
	handler := func(k *kit, options ...cronwatch.HandlerOption) http.Handler {
		job := must[*cronwatch.Job](t)(k.cw.Job("j"))
		return job.Handler(func(context.Context, *cronwatch.JobContext, http.ResponseWriter, *http.Request) error { return nil }, options...)
	}
	// newKit without its WithoutCronSecret: the client reads CRON_SECRET.
	fromEnv := func() *kit {
		k := &kit{c: storetest.NewClock(T0), alerts: &storetest.Capture{}, errors: &storetest.Errors{}}
		k.cw = must[*cronwatch.Client](t)(cronwatch.New(cronwatch.WithStore(cronwatch.NewMemoryStore()), cronwatch.WithClock(k.c.Now), cronwatch.WithAlerts(k.alerts), cronwatch.WithErrorHandler(k.errors.Add)))
		return k
	}
	closed := func(what string, k *kit, h http.Handler) {
		t.Helper()
		res := serve(h, "POST", "http://x/", nil, "")
		status(t, what, res, 503)
		contains(t, what+" message", decode(t, res)["error"].(string), "CRON_SECRET is not set")
		status(t, what+" blank bearer", serve(h, "POST", "http://x/", hdr{"authorization": "Bearer  "}, ""), 503)
		sameList(t, what+" reported once", k.wheres(), []string{"handler"})
	}
	for _, value := range []string{"", " ", "\t\n", " \ufeff", "\u00a0", "\u2003"} {
		production(t)
		t.Setenv("CRON_SECRET", value)
		k := fromEnv()
		closed("CRON_SECRET="+url.QueryEscape(value), k, handler(k))

		t.Setenv("CRON_SECRET", "from-env")
		k = newKit(t, cronwatch.WithCronSecret(value))
		closed("WithCronSecret("+url.QueryEscape(value)+")", k, handler(k))

		// A blank handler secret falls back to the client's.
		k = newKit(t, cronwatch.WithCronSecret("client-secret"))
		h := handler(k, cronwatch.WithSecret(value))
		status(t, "the client's secret", serve(h, "POST", "http://x/", hdr{"authorization": "Bearer client-secret"}, ""), 200)
		status(t, "not the blank", serve(h, "POST", "http://x/", hdr{"authorization": "Bearer " + value}, ""), 401)

		// With the client opted out, a blank handler secret opts out too.
		k = newKit(t, cronwatch.WithoutCronSecret())
		status(t, "opted out", serve(handler(k, cronwatch.WithSecret(value)), "POST", "http://x/", nil, ""), 200)
	}

	// /api/check with a blank CRON_SECRET takes only the token.
	production(t)
	t.Setenv("CRON_SECRET", "  ")
	k := fromEnv()
	routes := must[*cronwatch.Routes](t)(k.cw.Routes(cronwatch.WithToken("tok")))
	status(t, "a blank bearer is no secret", serve(routes, "POST", "http://app.test/cronwatch/api/check", hdr{"authorization": "Bearer   "}, ""), 401)
	status(t, "the token", serve(routes, "POST", "http://app.test/cronwatch/api/check", auth, ""), 200)
}

func TestRoutesOnlyABearerAuthorizationIsABearer(t *testing.T) {
	w := newWeb(t, nil)
	basic := hdr{"authorization": "Basic dXNlcjpwYXNz"}
	status(t, "basic with the cookie", w.get("/cronwatch/api/jobs", join(basic, cookie)), 200)
	status(t, "basic alone", w.get("/cronwatch/api/jobs", basic), 401)
	check := w.get("/cronwatch/api/check", join(basic, cookie))
	status(t, "a GET check with basic is no bearer", check, 405)
	eq(t, "allow", check.Header().Get("Allow"), "POST")
	signIn := w.get("/cronwatch/jobs/x?token=tok", basic)
	status(t, "?token= with basic", signIn, 303)
	eq(t, "location", signIn.Header().Get("Location"), "/cronwatch/jobs/x")
	contains(t, "cookie", signIn.Header().Get("Set-Cookie"), tokenCookieValue)
	status(t, "lower-case scheme", w.get("/cronwatch/api/jobs", hdr{"authorization": "bearer tok"}), 200)
	for _, value := range []string{"Bearer", "Bearertok", "Token tok", "tok"} {
		status(t, value+" with the cookie", w.get("/cronwatch/api/jobs", join(hdr{"authorization": value}, cookie)), 200)
		status(t, value+" alone", w.get("/cronwatch/api/jobs", hdr{"authorization": value}), 401)
	}
	status(t, "a wrong bearer still beats the cookie", w.get("/cronwatch/api/jobs", join(hdr{"authorization": "Bearer wrong"}, cookie)), 401)
}

func TestRoutesTheSignInFormPostsTheToken(t *testing.T) {
	w := newWeb(t, nil)
	page := w.get("/cronwatch/", nil)
	status(t, "sign-in page", page, 401)
	contains(t, "form", page.Body.String(), `<form class="signin" method="post" action="/cronwatch/signin">`)
	contains(t, "message", page.Body.String(), "Enter your CRONWATCH_TOKEN and this browser stays signed in.")

	post := func(headers hdr, body string) *http.Response {
		return w.send("POST", "/cronwatch/signin", join(form, headers), body).Result()
	}
	signedIn := func(what string, res *http.Response, location string) {
		t.Helper()
		eq(t, what+" status", res.StatusCode, 303)
		eq(t, what+" location", res.Header.Get("Location"), location)
		eq(t, what+" cookie", res.Header.Get("Set-Cookie"), tokenCookieValue+"; Path=/cronwatch; HttpOnly; SameSite=Lax; Max-Age=2592000")
		eq(t, what+" cache", res.Header.Get("Cache-Control"), "no-store")
	}
	from := "http://app.test/cronwatch/jobs/x"
	signedIn("back to the page", post(hdr{"origin": "http://app.test", "referer": from}, "token=tok"), from)
	signedIn("a referer with ?token=", post(hdr{"referer": "http://app.test/cronwatch/?a=1&token="}, "token=tok"), "/cronwatch/")
	signedIn("no referer", post(nil, "token=tok"), "/cronwatch/")
	signedIn("another origin's referer", post(hdr{"referer": "https://evil.example/cronwatch/jobs/x"}, "token=tok"), "/cronwatch/")
	signedIn("json", w.send("POST", "/cronwatch/signin", hdr{"content-type": "application/json"}, `{"token":"tok"}`).Result(), "/cronwatch/")
	for what, body := range map[string]string{"wrong": "token=wrong", "missing": "for=1h", "empty": ""} {
		res := post(nil, body)
		eq(t, what+" status", res.StatusCode, 401)
		eq(t, what+" no cookie", res.Header.Get("Set-Cookie"), "")
	}
	refused := post(hdr{"origin": "https://evil.example"}, "token=tok")
	eq(t, "cross-site", refused.StatusCode, 403)
	eq(t, "cross-site no cookie", refused.Header.Get("Set-Cookie"), "")
	status(t, "GET /signin without credentials", w.get("/cronwatch/signin", nil), 401)
	status(t, "GET /signin with them", w.get("/cronwatch/signin", auth), 404)

	// Over https the cookie is Secure.
	res := serve(w.routes, "POST", "https://app.test/cronwatch/signin", form, "token=tok")
	if !strings.HasSuffix(res.Header().Get("Set-Cookie"), "; Secure") {
		t.Errorf("https cookie: %q", res.Header().Get("Set-Cookie"))
	}

	// Open routes have no /signin.
	open := newWeb(t, []cronwatch.RoutesOption{cronwatch.WithoutToken(), cronwatch.WithBasePath("/cronwatch")})
	status(t, "open", open.send("POST", "/cronwatch/signin", form, "token=tok"), 404)

	// A development token signs in the same way.
	devEnv(t)
	cw := must[*cronwatch.Client](t)(cronwatch.New(cronwatch.WithStore(cronwatch.NewMemoryStore()), cronwatch.WithoutCronSecret()))
	dev := must[*cronwatch.Routes](t)(cw.Routes())
	contains(t, "development message", serve(dev, "GET", "http://localhost/cronwatch/", nil, "").Body.String(), "open it once, or enter the token from it below")
	status(t, "development sign-in", serve(dev, "POST", "http://localhost/cronwatch/signin", form, "token="+url.QueryEscape(dev.Token())), 303)
}
