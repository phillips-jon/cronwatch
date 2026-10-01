package cronwatch

// Reading an *http.Request the way the SDK's routes read a fetch Request:
// the path as the URL parser leaves it, the query as URLSearchParams parses
// it, the body as request.json() and request.formData() read it, and the
// origin as URL#origin writes it.

import (
	"errors"
	"io"
	"mime"
	"mime/multipart"
	"net/http"
	"strconv"
	"strings"
	"unicode/utf8"

	"cronwatch.dev/go/internal/js"
)

// maxBody is the most of a request body the dashboard reads: its forms and
// JSON are a few bytes. A body past it is answered 413; the SDK leaves this
// to the server in front of it.
const maxBody = 1 << 20

// MaxBody is the most of a request body the dashboard reads (1 MiB); a body
// past it is answered 413.
//
// Deprecated: MaxBody is internal, and goes in 1.0. The limit is documented
// on the dashboard's page and does not change.
const MaxBody = maxBody

// errBodyTooLarge is a request body over maxBody.
var errBodyTooLarge = errors.New("the request body is larger than 1048576 bytes")

// header is a request header as fetch's Headers.get gives it: every value
// joined with ", " (a cookie's with "; "), or false when there is none.
func header(r *http.Request, name string) (string, bool) {
	values := r.Header.Values(name)
	if len(values) == 0 {
		return "", false
	}
	sep := ", "
	if strings.EqualFold(name, "cookie") {
		sep = "; "
	}
	return strings.Join(values, sep), true
}

// requestTarget is the path and query the client sent: the request line's
// target when the server kept it (RequestURI), else the URL's own.
func requestTarget(r *http.Request) (path, query string) {
	target := r.RequestURI
	if target == "" || target == "*" {
		return r.URL.EscapedPath(), r.URL.RawQuery
	}
	if i := strings.Index(target, "://"); i >= 0 && !strings.HasPrefix(target, "/") {
		// The absolute form a proxy is sent: the path starts after the host.
		rest := target[i+3:]
		if j := strings.IndexAny(rest, "/?"); j >= 0 {
			target = rest[j:]
		} else {
			target = "/"
		}
	}
	path, query, _ = strings.Cut(target, "?")
	path, _, _ = strings.Cut(path, "#")
	if path == "" {
		path = "/"
	}
	return path, query
}

// pathSafe is whether the URL parser leaves c in a path as it is: the
// path percent-encode set is C0 controls, space, " # < > ? ` { } and
// everything past ~.
func pathSafe(c byte) bool {
	return c > 0x20 && c < 0x7f && strings.IndexByte("\"#<>?`{}", c) < 0
}

// normalizePath is a path as new URL() leaves it for an http URL:
// backslashes read as slashes, characters outside the path set escaped,
// and "." and ".." segments (written plainly or as %2e) resolved.
func normalizePath(raw string) string {
	var b strings.Builder
	for i := 0; i < len(raw); i++ {
		c := raw[i]
		switch {
		case c == '\\':
			b.WriteByte('/')
		case pathSafe(c) || c == '%':
			b.WriteByte(c)
		default:
			b.WriteString("%" + strings.ToUpper(strconv.FormatUint(uint64(c)>>4, 16)+strconv.FormatUint(uint64(c)&15, 16)))
		}
	}
	segments := strings.Split(strings.TrimPrefix(b.String(), "/"), "/")
	var out []string
	for i, s := range segments {
		last := i == len(segments)-1
		switch strings.ToLower(s) {
		case ".", "%2e":
			if last {
				out = append(out, "")
			}
		case "..", ".%2e", "%2e.", "%2e%2e":
			if len(out) > 0 {
				out = out[:len(out)-1]
			}
			if last {
				out = append(out, "")
			}
		default:
			out = append(out, s)
		}
	}
	return "/" + strings.Join(out, "/")
}

// stripBase is the path under the base, without a trailing slash.
func stripBase(pathname, base string) string {
	path := strings.TrimPrefix(pathname, base)
	if path == "" {
		path = "/"
	}
	if len(path) > 1 && strings.HasSuffix(path, "/") {
		path = path[:len(path)-1]
	}
	return path
}

// safeDecode is decodeURIComponent, or false where it would throw: an
// escape that is not one, or bytes that are not UTF-8.
func safeDecode(s string) (string, bool) {
	for i := 0; i < len(s); i++ {
		if s[i] == '%' && (i+2 >= len(s) || !isHex(s[i+1]) || !isHex(s[i+2])) {
			return "", false
		}
	}
	out := percentDecode(s)
	if !utf8.ValidString(out) {
		return "", false
	}
	return out, true
}

// percentDecode decodes every %XX, leaving anything else as it is.
func percentDecode(s string) string {
	if !strings.Contains(s, "%") {
		return s
	}
	var b strings.Builder
	for i := 0; i < len(s); i++ {
		if s[i] == '%' && i+2 < len(s) && isHex(s[i+1]) && isHex(s[i+2]) {
			v, _ := strconv.ParseUint(s[i+1:i+3], 16, 8)
			b.WriteByte(byte(v))
			i += 2
			continue
		}
		b.WriteByte(s[i])
	}
	return b.String()
}

func isHex(c byte) bool {
	return c >= '0' && c <= '9' || c >= 'a' && c <= 'f' || c >= 'A' && c <= 'F'
}

// formPair is one name and value of a query or a form.
type formPair struct{ name, value string }

// parseForm is application/x-www-form-urlencoded parsing as URLSearchParams
// does it: "+" is a space, an escape that is not one is kept as written,
// and bytes that are not UTF-8 become U+FFFD.
func parseForm(text string) []formPair {
	var out []formPair
	for _, part := range strings.Split(text, "&") {
		if part == "" {
			continue
		}
		name, value, _ := strings.Cut(part, "=")
		out = append(out, formPair{formDecode(name), formDecode(value)})
	}
	return out
}

func formDecode(s string) string {
	return js.WellFormed(percentDecode(strings.ReplaceAll(s, "+", " ")))
}

// formEncode is the application/x-www-form-urlencoded serializer
// URLSearchParams writes with.
func formEncode(s string) string {
	const hex = "0123456789ABCDEF"
	var b strings.Builder
	for _, c := range []byte(js.WellFormed(s)) {
		switch {
		case c >= 'a' && c <= 'z', c >= 'A' && c <= 'Z', c >= '0' && c <= '9', c == '*', c == '-', c == '.', c == '_':
			b.WriteByte(c)
		case c == ' ':
			b.WriteByte('+')
		default:
			b.WriteByte('%')
			b.WriteByte(hex[c>>4])
			b.WriteByte(hex[c&15])
		}
	}
	return b.String()
}

// param is URLSearchParams#get: the first value, or false.
func param(pairs []formPair, name string) (string, bool) {
	for _, p := range pairs {
		if p.name == name {
			return p.value, true
		}
	}
	return "", false
}

// readLimited reads a body up to maxBody, or errBodyTooLarge past it (by
// its Content-Length, or once more than that has arrived). A body that
// could not be read to its end (the client went away, a read deadline) is
// none, as the SDK's readBody has it, never the part that arrived:
// "for=7d" cut short is "for=7", a silence of 7 ms.
func readLimited(r *http.Request) ([]byte, error) {
	if r.Body == nil || r.Body == http.NoBody {
		return nil, nil
	}
	if r.ContentLength > maxBody {
		return nil, errBodyTooLarge
	}
	data, err := io.ReadAll(io.LimitReader(r.Body, maxBody+1))
	if len(data) > maxBody {
		return nil, errBodyTooLarge
	}
	if err != nil {
		return nil, err
	}
	return data, nil
}

// readBody is the form fields or JSON object of a request, each value as
// String(value) gives it in JavaScript; empty for anything else, or a body
// that cannot be read as its type says.
func readBody(r *http.Request, data []byte) map[string]string {
	kind, _ := header(r, "content-type")
	out := map[string]string{}
	switch {
	case strings.Contains(kind, "application/json"):
		text := js.WellFormed(string(data))
		text = strings.TrimPrefix(text, "\ufeff")
		v, err := js.Parse(text)
		if err != nil {
			return out
		}
		switch t := v.(type) {
		case *js.Object:
			for _, k := range t.Keys() {
				value, _ := t.Get(k)
				out[k] = jsText(value, true)
			}
		case []any:
			for i, value := range t {
				out[strconv.Itoa(i)] = jsText(value, true)
			}
		}
	case strings.Contains(kind, "multipart/form-data"):
		_, params, err := mime.ParseMediaType(kind)
		if err != nil || params["boundary"] == "" {
			return out
		}
		reader := multipart.NewReader(strings.NewReader(string(data)), params["boundary"])
		fields := map[string]string{}
		for {
			part, err := reader.NextPart()
			if err == io.EOF {
				break
			}
			if err != nil {
				return out
			}
			name := part.FormName()
			if name == "" {
				continue
			}
			if part.FileName() != "" {
				fields[name] = "[object File]"
				continue
			}
			value, err := io.ReadAll(part)
			if err != nil {
				return out
			}
			fields[name] = js.WellFormed(string(value))
		}
		return fields
	case strings.Contains(kind, "application/x-www-form-urlencoded"):
		for _, p := range parseForm(string(data)) {
			out[p.name] = p.value
		}
	}
	return out
}
