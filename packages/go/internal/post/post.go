// Package post is the one POST the alert channels and Claude triage make,
// as the SDK makes it with fetch (alerts/shared.ts): the URL cleaned and
// read as fetch reads it, only http and https, headers checked as fetch
// checks them, one ten second deadline for the whole request, a redirect
// refused rather than followed, at most 1 MiB of an answer read, and an
// error that names only the URL's origin, with every secret the caller holds
// cut out of a quoted answer before it is cut to 200 characters.
package post

import (
	"context"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strings"
	"time"

	"cronwatch.dev/go/internal/js"
)

// Timeout is how long one request may take, connecting, sending and reading
// the answer, as the SDK's AbortSignal.timeout(10_000). A variable only
// so tests can wait less.
var Timeout = 10 * time.Second

// MaxBody is how much of an answer is read. A channel quotes 200 characters
// of a refusal, and a compressed answer from a broken or hostile endpoint
// could otherwise decode to far more than a process has.
const MaxBody = 1 << 20

// ErrorBodyMax is how much of an answer's body goes into an error.
const ErrorBodyMax = 200

// ErrTimeout is fetch's error for a request past its deadline.
//
//lint:ignore ST1005 the SDK's message, word for word
var ErrTimeout = errors.New("The operation was aborted due to timeout")

// Header is one request header. The channels keep them in the SDK's order.
type Header struct{ Name, Value string }

// Response is an answer: its status and as much of its body as was read,
// as response.text() reads it (UTF-8, U+FFFD for bytes that are not, no
// byte order mark). A body the deadline cut short is "".
type Response struct {
	Status int
	Body   string
}

// OK is response.ok: a 2xx status.
func (r Response) OK() bool { return r.Status >= 200 && r.Status < 300 }

// Clean is a URL as the URL parser (and so fetch) reads it: characters
// U+0000 to U+0020 around it dropped, and every tab, CR and LF inside it
// removed (a pasted webhook URL often ends in a newline).
func Clean(raw string) string {
	s := strings.TrimFunc(raw, func(r rune) bool { return r <= 0x20 })
	return strings.NewReplacer("\t", "", "\r", "", "\n", "").Replace(s)
}

// parse reads a cleaned URL with a scheme and a host, or nil.
func parse(clean string) *url.URL {
	u, err := url.Parse(clean)
	if err != nil || u.Scheme == "" || u.Host == "" || u.Opaque != "" || u.Hostname() == "" {
		return nil
	}
	return u
}

// Postable is the URL, cleaned, once it is one a channel can post to: http
// or https with a host. Refused without quoting it, since a webhook URL's
// path is its credential: "not ftp:" for another scheme with a host, "not
// this URL" for anything else (no scheme, no host, a space or control
// character left inside it, or a user name and password, which fetch
// refuses to send).
func Postable(raw string) (string, error) {
	clean := Clean(raw)
	var u *url.URL
	if !strings.ContainsFunc(clean, func(r rune) bool { return r <= 0x20 || r == 0x7f }) {
		u = parse(clean)
	}
	if u == nil || u.User != nil {
		return "", errors.New("only http and https URLs can be posted to, not this URL")
	}
	if scheme := strings.ToLower(u.Scheme); scheme != "http" && scheme != "https" {
		return "", fmt.Errorf("only http and https URLs can be posted to, not %s", scheme+":")
	}
	return clean, nil
}

var defaultPorts = map[string]string{"http": "80", "https": "443", "ws": "80", "wss": "443", "ftp": "21"}

// Origin is new URL(url).origin: the scheme, host and port only, a port
// that is the scheme's own left out. A URL's path or query can hold a
// credential, so an error names only this.
func Origin(raw string) string {
	u := parse(Clean(raw))
	if u == nil {
		return "(invalid URL)"
	}
	scheme := strings.ToLower(u.Scheme)
	if _, special := defaultPorts[scheme]; !special {
		return "null"
	}
	host := strings.ToLower(u.Hostname())
	if strings.Contains(host, ":") {
		host = "[" + host + "]"
	}
	if port := strings.TrimLeft(u.Port(), "0"); u.Port() != "" && port != defaultPorts[scheme] {
		if port == "" {
			port = "0"
		}
		host += ":" + port
	}
	return scheme + "://" + host
}

// Cut is at most max UTF-16 code units of text, never half a surrogate
// pair (shared.ts's cut).
func Cut(text string, max int) string {
	if js.Length16(text) <= max {
		return text
	}
	var b strings.Builder
	n := 0
	for _, r := range text {
		w := 1
		if r >= 0x10000 {
			w = 2
		}
		if n+w > max {
			break
		}
		b.WriteRune(r)
		n += w
	}
	return b.String()
}

// ErrorBody is the start of an error body: every secret of four or more
// characters cut out of a prefix long enough to hold one that starts inside
// the first ErrorBodyMax characters, and only then cut to that length, so
// no part of a secret survives at the edge.
func ErrorBody(text string, secrets ...string) string {
	var kept []string
	longest := 0
	for _, s := range secrets {
		if n := js.Length16(s); n >= 4 {
			kept = append(kept, s)
			longest = max(longest, n)
		}
	}
	head := Cut(text, ErrorBodyMax+longest)
	for _, s := range kept {
		head = strings.ReplaceAll(head, s, "[redacted]")
	}
	return Cut(head, ErrorBodyMax)
}

// token reports whether a header name is an HTTP token (RFC 9110).
func token(name string) bool {
	if name == "" {
		return false
	}
	for i := 0; i < len(name); i++ {
		c := name[i]
		if !(c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c >= '0' && c <= '9' || strings.IndexByte("!#$%&'*+.^_`|~-", c) >= 0) {
			return false
		}
	}
	return true
}

// Headers are the headers as a request sends them: each name an HTTP
// token, each value without the spaces, tabs and line breaks around it,
// as fetch sends it. A name that is not a token, or a value with a line
// break or NUL inside, is refused, as fetch refuses them, so no header can
// add another; the error names the header, never its value, which may be
// a credential. Two headers whose names differ only in case are both sent,
// as fetch appends them.
func Headers(list []Header) (http.Header, error) {
	h := http.Header{}
	for _, header := range list {
		if !token(header.Name) {
			return nil, errors.New("a header name must be a token (letters, digits and !#$%&'*+.^_`|~-)")
		}
		value := strings.Trim(header.Value, " \t\r\n")
		if strings.ContainsAny(value, "\r\n\x00") {
			return nil, fmt.Errorf("the %s header's value may not contain a line break", header.Name)
		}
		h.Add(header.Name, value)
	}
	return h, nil
}

// refuse is CheckRedirect for every client: the 3xx comes back as the
// answer, an answer outside 2xx like any other, so credential headers never
// go where it points.
func refuse(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }

var fallback = &http.Client{}

// Do posts body to rawURL through client (nil for the default: Go's
// default transport, which verifies TLS) and returns the answer, whatever
// its status. The client is used as a copy that never follows a redirect.
// An error is a request that could not be made or had no answer: the URL
// refused (Postable), a header refused (Headers), ErrTimeout past the
// deadline, the caller's context ending, or the transport's own error,
// which names no more of the URL than its origin.
func Do(ctx context.Context, client *http.Client, rawURL string, headers []Header, body string) (Response, error) {
	return DoWithin(ctx, Timeout, client, rawURL, headers, body)
}

// DoWithin is Do with a deadline of its own in place of Timeout.
func DoWithin(ctx context.Context, timeout time.Duration, client *http.Client, rawURL string, headers []Header, body string) (Response, error) {
	target, err := Postable(rawURL)
	if err != nil {
		return Response{}, err
	}
	h, err := Headers(headers)
	if err != nil {
		return Response{}, err
	}
	rctx, cancel := context.WithTimeoutCause(ctx, timeout, ErrTimeout)
	defer cancel()
	// UTF-8 as fetch sends a string, U+FFFD for bytes that are not.
	req, err := http.NewRequestWithContext(rctx, http.MethodPost, target, strings.NewReader(js.WellFormed(body)))
	if err != nil {
		return Response{}, fmt.Errorf("cannot post to %s: the URL is not valid", Origin(target))
	}
	req.Header = h
	if client == nil {
		client = fallback
	}
	c := *client
	c.CheckRedirect = refuse
	resp, err := c.Do(req)
	if err != nil {
		if ctx.Err() == nil && errors.Is(context.Cause(rctx), ErrTimeout) {
			return Response{}, ErrTimeout
		}
		if ctx.Err() != nil {
			return Response{}, context.Cause(ctx)
		}
		// *url.Error quotes the whole URL: only what went wrong is kept.
		var ue *url.Error
		if errors.As(err, &ue) {
			err = ue.Err
		}
		return Response{}, fmt.Errorf("%s: %w", Origin(target), err)
	}
	defer resp.Body.Close()
	data, err := io.ReadAll(io.LimitReader(resp.Body, MaxBody))
	if err != nil {
		// A body the deadline cut short, as the SDK treats a body it could not read.
		return Response{Status: resp.StatusCode}, nil
	}
	return Response{Status: resp.StatusCode, Body: Text(data)}, nil
}

// Text is bytes as response.text() reads them: UTF-8, U+FFFD for bytes
// that are not, no byte order mark.
func Text(data []byte) string {
	return strings.TrimPrefix(js.WellFormed(string(data)), "\ufeff")
}

// Post is Do that fails on an answer outside 2xx: "<provider> <origin>
// answered <status>: <body>", the body's secrets cut out (ErrorBody).
func Post(ctx context.Context, client *http.Client, provider, rawURL string, headers []Header, body string, secrets ...string) (Response, error) {
	resp, err := Do(ctx, client, rawURL, headers, body)
	if err != nil {
		return resp, err
	}
	if !resp.OK() {
		return resp, Refused(provider, rawURL, resp, secrets...)
	}
	return resp, nil
}

// Refused is the error for an answer outside 2xx.
func Refused(provider, rawURL string, resp Response, secrets ...string) error {
	text := ""
	if resp.Body != "" {
		text = ": " + ErrorBody(resp.Body, secrets...)
	}
	return fmt.Errorf("%s %s answered %d%s", provider, Origin(rawURL), resp.Status, text)
}
