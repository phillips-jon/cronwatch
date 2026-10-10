package cronwatch_test

// Lambda: REST API, HTTP API, and function URL events, read from their JSON
// as aws-lambda-go's lambda.Start would read them, through a job's handler
// and the dashboard.

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"net/http"
	"strings"
	"testing"

	cronwatch "cronwatch.dev/go"
)

func lambdaEvent(t *testing.T, text string) cronwatch.LambdaEvent {
	t.Helper()
	var e cronwatch.LambdaEvent
	check(t, json.Unmarshal([]byte(text), &e))
	return e
}

func TestLambdaRunsAJobHandlerFromEachKindOfEvent(t *testing.T) {
	secret := "s3" + "cret"
	k := newKit(t, cronwatch.WithCronSecret(secret))
	job := must[*cronwatch.Job](t)(k.cw.Job("lambda"))
	fn := cronwatch.Lambda(job.Handler(func(ctx context.Context, j *cronwatch.JobContext, w http.ResponseWriter, r *http.Request) error {
		j.Log(r.Method, r.URL.Path, r.URL.RawQuery, r.Host)
		return nil
	}))
	events := map[string]string{
		// A REST API: headers as sent, and multiValueHeaders.
		"rest": `{"resource":"/cron","path":"/cron","httpMethod":"POST","headers":{"Authorization":"Bearer ` + secret + `","Host":"abc.execute-api.eu-west-1.amazonaws.com"},
			"multiValueHeaders":{"Authorization":["Bearer ` + secret + `"],"Host":["abc.execute-api.eu-west-1.amazonaws.com"]},
			"queryStringParameters":{"a":"b c"},"multiValueQueryStringParameters":{"a":["b c"]},"requestContext":{"httpMethod":"POST","domainName":"abc.execute-api.eu-west-1.amazonaws.com"},"body":null,"isBase64Encoded":false}`,
		// An HTTP API, payload 2.0: lowercase headers.
		"http": `{"version":"2.0","routeKey":"POST /cron","rawPath":"/cron","rawQueryString":"a=b%20c","headers":{"authorization":"Bearer ` + secret + `","host":"abc.execute-api.eu-west-1.amazonaws.com"},
			"requestContext":{"domainName":"abc.execute-api.eu-west-1.amazonaws.com","http":{"method":"POST","path":"/cron"}},"isBase64Encoded":false}`,
		// A function URL.
		"url": `{"version":"2.0","routeKey":"$default","rawPath":"/cron","rawQueryString":"a=b%20c","headers":{"authorization":"Bearer ` + secret + `"},
			"requestContext":{"domainName":"xyz.lambda-url.eu-west-1.on.aws","http":{"method":"POST","path":"/cron"}},"body":"","isBase64Encoded":true}`,
	}
	for name, text := range events {
		k.c.Advance(1000)
		res, err := fn(bg, lambdaEvent(t, text))
		check(t, err)
		eq(t, name+" status", res.StatusCode, 200)
		eq(t, name+" type", res.Headers["Content-Type"], "application/json; charset=utf-8")
		if _, has := res.Headers["Content-Length"]; has {
			t.Errorf("%s: a Content-Length", name)
		}
		contains(t, name+" body", res.Body, `"ok":true`)
		out := *runs(t, k.cw, "lambda")[0].Output
		if !strings.HasPrefix(out, "POST /cron a=b") || !strings.Contains(out, ".amazonaws.com") && !strings.Contains(out, ".on.aws") {
			t.Errorf("%s: the request read as %q", name, out)
		}
	}
	res, err := fn(bg, lambdaEvent(t, `{"version":"2.0","rawPath":"/cron","headers":{"authorization":"Bearer wrong"},"requestContext":{"http":{"method":"POST"}}}`))
	check(t, err)
	eq(t, "wrong", res.StatusCode, 401)
}

func TestLambdaServesTheDashboard(t *testing.T) {
	w := newWeb(t, []cronwatch.RoutesOption{cronwatch.WithToken("tok")})
	check(t, w.cw.Run(bg, "x", ok))
	fn := cronwatch.Lambda(w.routes)

	signIn, err := fn(bg, lambdaEvent(t, `{"version":"2.0","rawPath":"/cronwatch/","rawQueryString":"token=tok","headers":{"host":"app.example.com"},"requestContext":{"http":{"method":"GET"}}}`))
	check(t, err)
	eq(t, "sign-in", signIn.StatusCode, 303)
	eq(t, "location", signIn.Headers["Location"], "/cronwatch/")
	eq(t, "a cookie, apart", len(signIn.Cookies), 1)
	if !strings.HasSuffix(signIn.Cookies[0], "; Secure") {
		t.Errorf("the cookie over https: %s", signIn.Cookies[0])
	}
	cookie := strings.Split(signIn.Cookies[0], ";")[0]
	page, err := fn(bg, lambdaEvent(t, `{"version":"2.0","rawPath":"/cronwatch/jobs/x","cookies":["`+cookie+`"],"headers":{"host":"app.example.com"},"requestContext":{"http":{"method":"GET"}}}`))
	check(t, err)
	eq(t, "page", page.StatusCode, 200)
	contains(t, "page body", page.Body, `<h1 class="jobname">x</h1>`)

	icon, err := fn(bg, lambdaEvent(t, `{"version":"2.0","rawPath":"/cronwatch/icons/icon-192.png","requestContext":{"http":{"method":"GET"}}}`))
	check(t, err)
	eq(t, "a PNG is base64", icon.IsBase64Encoded, true)
	data, err := base64.StdEncoding.DecodeString(icon.Body)
	check(t, err)
	eq(t, "PNG", string(data[1:4]), "PNG")

	// A REST API's form post, its body base64, its cookie a header.
	silence, err := fn(bg, lambdaEvent(t, `{"path":"/cronwatch/jobs/x/silence","httpMethod":"POST","headers":{"Cookie":"`+cookie+`","Content-Type":"application/x-www-form-urlencoded","Host":"app.example.com"},
		"body":"`+base64.StdEncoding.EncodeToString([]byte("for=2h"))+`","isBase64Encoded":true,"requestContext":{}}`))
	check(t, err)
	eq(t, "silence", silence.StatusCode, 303)
	eq(t, "silenced", *summary(t, w.cw, "x").SilencedUntil, T0+2*HOUR)
	if silence.Cookies != nil {
		t.Error("cookies in a 1.0 result")
	}
	raw, _ := json.Marshal(silence)
	for _, key := range []string{`"cookies"`, `"multiValueHeaders"`} {
		if strings.Contains(string(raw), key) {
			t.Errorf("a 1.0 result with %s: %s", key, raw)
		}
	}
}
