package cronwatch

// An http.Handler (a job's Handler, or the dashboard's Routes) as an AWS
// Lambda function behind API Gateway or a function URL, with no AWS module:
// the event and the proxy result are plain JSON, which aws-lambda-go's
// lambda.Start reads into and writes from any struct.

import (
	"bytes"
	"context"
	"crypto/tls"
	"encoding/base64"
	"io"
	"net/http"
	"net/url"
	"sort"
	"strings"
	"unicode/utf8"
)

// LambdaEvent is the request API Gateway (a REST API's payload format 1.0,
// an HTTP API's 1.0 or 2.0) or a function URL (2.0) hands a function: the
// fields an http.Handler needs of either format.
type LambdaEvent struct {
	Version string `json:"version,omitempty"`
	// 1.0
	HTTPMethod                      string              `json:"httpMethod,omitempty"`
	Path                            string              `json:"path,omitempty"`
	MultiValueHeaders               map[string][]string `json:"multiValueHeaders,omitempty"`
	QueryStringParameters           map[string]string   `json:"queryStringParameters,omitempty"`
	MultiValueQueryStringParameters map[string][]string `json:"multiValueQueryStringParameters,omitempty"`
	// 2.0
	RawPath        string   `json:"rawPath,omitempty"`
	RawQueryString string   `json:"rawQueryString,omitempty"`
	Cookies        []string `json:"cookies,omitempty"`
	// Both
	Headers         map[string]string    `json:"headers,omitempty"`
	RequestContext  LambdaRequestContext `json:"requestContext"`
	Body            string               `json:"body,omitempty"`
	IsBase64Encoded bool                 `json:"isBase64Encoded,omitempty"`
}

// LambdaRequestContext is what a LambdaEvent says of where it came from.
type LambdaRequestContext struct {
	DomainName string `json:"domainName,omitempty"`
	// 1.0's method.
	HTTPMethod string `json:"httpMethod,omitempty"`
	// 2.0's method and path.
	HTTP struct {
		Method string `json:"method,omitempty"`
		Path   string `json:"path,omitempty"`
	} `json:"http"`
}

// LambdaResult is the proxy result a function answers with. Only the keys
// the format knows are written, since a REST API refuses a result with
// others: a header given more than once is in MultiValueHeaders for 1.0,
// and Set-Cookie in Cookies for 2.0.
type LambdaResult struct {
	StatusCode        int                 `json:"statusCode"`
	Headers           map[string]string   `json:"headers,omitempty"`
	MultiValueHeaders map[string][]string `json:"multiValueHeaders,omitempty"`
	Cookies           []string            `json:"cookies,omitempty"`
	Body              string              `json:"body"`
	IsBase64Encoded   bool                `json:"isBase64Encoded"`
}

// Lambda is h as an AWS Lambda function behind API Gateway or a function
// URL, for aws-lambda-go's lambda.Start, which the app imports:
//
//	lambda.Start(cronwatch.Lambda(nightly.Handler(buildReport)))
//
// The event becomes an *http.Request over https (the host from its Host
// header or its domain name, the body decoded when it is base64), and h's
// answer the proxy result, its body as text when it is UTF-8 and base64
// otherwise, without a Content-Length (API Gateway sets its own). A
// directly invoked function (EventBridge Scheduler) has no headers to carry
// a bearer; IAM decides who may invoke it, so such a handler takes
// WithoutSecret.
func Lambda(h http.Handler) func(ctx context.Context, event LambdaEvent) (LambdaResult, error) {
	return func(ctx context.Context, event LambdaEvent) (LambdaResult, error) {
		r, err := event.request(ctx)
		if err != nil {
			return LambdaResult{}, err
		}
		w := &lambdaWriter{header: http.Header{}}
		h.ServeHTTP(w, r)
		return w.result(event.Version == "2.0"), nil
	}
}

func (e LambdaEvent) request(ctx context.Context) (*http.Request, error) {
	method := firstOf(e.HTTPMethod, e.RequestContext.HTTP.Method, e.RequestContext.HTTPMethod, http.MethodGet)
	path := firstOf(e.RawPath, e.Path, e.RequestContext.HTTP.Path, "/")
	query := e.RawQueryString
	if query == "" {
		query = e.v1Query()
	}
	target := path
	if query != "" {
		target += "?" + query
	}
	u, err := url.ParseRequestURI(target)
	if err != nil {
		u = &url.URL{Path: path, RawQuery: query}
	}
	header := http.Header{}
	for k, values := range e.MultiValueHeaders {
		for _, v := range values {
			header.Add(k, v)
		}
	}
	for k, v := range e.Headers {
		if len(header.Values(k)) == 0 {
			header.Set(k, v)
		}
	}
	if len(e.Cookies) > 0 && header.Get("Cookie") == "" {
		header.Set("Cookie", strings.Join(e.Cookies, "; "))
	}
	body := []byte(e.Body)
	if e.IsBase64Encoded {
		if body, err = base64.StdEncoding.DecodeString(e.Body); err != nil {
			return nil, err
		}
	}
	host := firstOf(header.Get("Host"), e.RequestContext.DomainName, "localhost")
	r := &http.Request{
		Method: strings.ToUpper(method), URL: u, RequestURI: target, Host: host, Header: header,
		Proto: "HTTP/1.1", ProtoMajor: 1, ProtoMinor: 1,
		Body: io.NopCloser(bytes.NewReader(body)), ContentLength: int64(len(body)),
		// API Gateway and function URLs are https only.
		TLS: &tls.ConnectionState{},
	}
	return r.WithContext(ctx), nil
}

// v1Query is a 1.0 event's query string, from its parameters (which API
// Gateway hands over decoded), in name order.
func (e LambdaEvent) v1Query() string {
	params := url.Values{}
	for k, values := range e.MultiValueQueryStringParameters {
		params[k] = append(params[k], values...)
	}
	for k, v := range e.QueryStringParameters {
		if _, ok := params[k]; !ok {
			params.Set(k, v)
		}
	}
	return params.Encode()
}

func firstOf(values ...string) string {
	for _, v := range values {
		if v != "" {
			return v
		}
	}
	return ""
}

// lambdaWriter keeps an answer in memory.
type lambdaWriter struct {
	header http.Header
	status int
	body   bytes.Buffer
}

func (w *lambdaWriter) Header() http.Header { return w.header }

func (w *lambdaWriter) WriteHeader(code int) {
	if w.status == 0 && code >= 200 {
		w.status = code
	}
}

func (w *lambdaWriter) Write(p []byte) (int, error) {
	if w.status == 0 {
		w.status = http.StatusOK
	}
	return w.body.Write(p)
}

func (w *lambdaWriter) result(v2 bool) LambdaResult {
	status := w.status
	if status == 0 {
		status = http.StatusOK
	}
	out := LambdaResult{StatusCode: status}
	names := make([]string, 0, len(w.header))
	for k := range w.header {
		names = append(names, k)
	}
	sort.Strings(names)
	for _, k := range names {
		values := w.header[k]
		if strings.EqualFold(k, "Content-Length") || len(values) == 0 {
			continue
		}
		switch {
		case v2 && strings.EqualFold(k, "Set-Cookie"):
			out.Cookies = append(out.Cookies, values...)
		case len(values) == 1 || v2:
			if out.Headers == nil {
				out.Headers = map[string]string{}
			}
			out.Headers[k] = strings.Join(values, ", ")
		default:
			if out.MultiValueHeaders == nil {
				out.MultiValueHeaders = map[string][]string{}
			}
			out.MultiValueHeaders[k] = append([]string(nil), values...)
		}
	}
	data := w.body.Bytes()
	if utf8.Valid(data) {
		out.Body = string(data)
	} else {
		out.Body, out.IsBase64Encoded = base64.StdEncoding.EncodeToString(data), true
	}
	return out
}
