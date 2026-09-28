package alerts

// AWS Signature Version 4, for the SES channel (alerts/sigv4.ts), so no
// AWS SDK is needed.
// Spec: https://docs.aws.amazon.com/IAM/latest/UserGuide/reference_sigv-create-signed-request.html
// Checked against the AWS SigV4 test suite (sigv4_test.go).

import (
	"encoding/hex"
	"fmt"
	"net/url"
	"sort"
	"strings"

	"cronwatch.dev/go/internal/js"
)

// sigV4Credentials sign a request. The session token is for temporary
// credentials (STS, an IAM role), sent and signed as X-Amz-Security-Token.
type sigV4Credentials struct {
	accessKeyID, secretAccessKey, sessionToken string
}

// sigV4Request is what is signed. Host is taken from the URL, and
// X-Amz-Date from now (epoch milliseconds).
type sigV4Request struct {
	method, url     string
	headers         []header
	body            string
	region, service string
	now             int64
}

// signV4 returns the headers to send: the given ones (names lowercased)
// plus x-amz-date, the session token when there is one, and authorization.
// Host is signed but not returned, because the HTTP client sets it.
func signV4(r sigV4Request, c sigV4Credentials) ([]header, error) {
	u, err := url.Parse(r.url)
	if err != nil {
		return nil, fmt.Errorf("cannot sign a request to an invalid URL")
	}
	iso := js.ISOString(r.now)
	amzDate := strings.NewReplacer("-", "", ":", "").Replace(iso[:19]) + "Z"
	day := amzDate[:8]
	var headers []header
	set := func(name, value string) {
		for i := range headers {
			if headers[i].Name == name {
				headers[i].Value = value
				return
			}
		}
		headers = append(headers, header{Name: name, Value: value})
	}
	for _, h := range r.headers {
		set(strings.ToLower(h.Name), h.Value)
	}
	set("x-amz-date", amzDate)
	if c.sessionToken != "" {
		set("x-amz-security-token", c.sessionToken)
	}

	signed := map[string]string{}
	for _, h := range headers {
		signed[h.Name] = h.Value
	}
	signed["host"] = hostOf(u)
	names := make([]string, 0, len(signed))
	for name := range signed {
		names = append(names, name)
	}
	sort.Strings(names)
	var canonicalHeaders strings.Builder
	for _, n := range names {
		canonicalHeaders.WriteString(n + ":" + collapse(js.Trim(signed[n])) + "\n")
	}
	signedHeaders := strings.Join(names, ";")
	canonicalRequest := strings.Join([]string{
		strings.ToUpper(r.method),
		canonicalURI(u.EscapedPath()),
		canonicalQuery(u.RawQuery),
		canonicalHeaders.String(),
		signedHeaders,
		sha256Hex(r.body),
	}, "\n")
	scope := day + "/" + r.region + "/" + r.service + "/aws4_request"
	stringToSign := strings.Join([]string{"AWS4-HMAC-SHA256", amzDate, scope, sha256Hex(canonicalRequest)}, "\n")

	key := hmacSHA256([]byte(js.WellFormed("AWS4"+c.secretAccessKey)), day)
	key = hmacSHA256(key, r.region)
	key = hmacSHA256(key, r.service)
	key = hmacSHA256(key, "aws4_request")
	signature := hex.EncodeToString(hmacSHA256(key, stringToSign))

	set("authorization", "AWS4-HMAC-SHA256 Credential="+c.accessKeyID+"/"+scope+", SignedHeaders="+signedHeaders+", Signature="+signature)
	return headers, nil
}

// hostOf is URL#host: the hostname, lowercased, and the port when it is not
// the scheme's own.
func hostOf(u *url.URL) string {
	host := strings.ToLower(u.Hostname())
	if strings.Contains(host, ":") {
		host = "[" + host + "]"
	}
	port := u.Port()
	if port != "" && !(u.Scheme == "https" && port == "443") && !(u.Scheme == "http" && port == "80") {
		host += ":" + port
	}
	return host
}

// collapse is .replace(/\s+/g, " ") with JavaScript's \s.
func collapse(text string) string {
	var b strings.Builder
	space := false
	for _, r := range text {
		if js.IsSpace(r) {
			space = true
			continue
		}
		if space {
			b.WriteByte(' ')
			space = false
		}
		b.WriteRune(r)
	}
	if space {
		b.WriteByte(' ')
	}
	return b.String()
}

// uriEncode is RFC 3986 encoding of every byte but the unreserved
// characters.
func uriEncode(text string) string {
	return percent(text, "-_.~", false)
}

// canonicalURI encodes each segment of the path, which is already encoded
// once, again: every AWS service but S3 expects that.
func canonicalURI(path string) string {
	if path == "" {
		return "/"
	}
	segments := strings.Split(path, "/")
	for i, s := range segments {
		segments[i] = uriEncode(s)
	}
	return strings.Join(segments, "/")
}

// canonicalQuery is the query read as URLSearchParams reads it, each name
// and value encoded, sorted by name and then value.
func canonicalQuery(raw string) string {
	var pairs [][2]string
	for _, part := range strings.Split(raw, "&") {
		if part == "" {
			continue
		}
		name, value, _ := strings.Cut(part, "=")
		pairs = append(pairs, [2]string{uriEncode(formDecode(name)), uriEncode(formDecode(value))})
	}
	sort.SliceStable(pairs, func(i, j int) bool {
		if pairs[i][0] != pairs[j][0] {
			return pairs[i][0] < pairs[j][0]
		}
		return pairs[i][1] < pairs[j][1]
	})
	out := make([]string, len(pairs))
	for i, p := range pairs {
		out[i] = p[0] + "=" + p[1]
	}
	return strings.Join(out, "&")
}

// formDecode is application/x-www-form-urlencoded decoding: + is a space,
// and a % not followed by two hex digits is kept as it is.
func formDecode(text string) string {
	text = strings.ReplaceAll(text, "+", " ")
	var b []byte
	for i := 0; i < len(text); i++ {
		if text[i] == '%' && i+2 < len(text) && isHex(text[i+1]) && isHex(text[i+2]) {
			v, _ := hex.DecodeString(text[i+1 : i+3])
			b = append(b, v[0])
			i += 2
			continue
		}
		b = append(b, text[i])
	}
	return js.WellFormed(string(b))
}

func isHex(c byte) bool {
	return c >= '0' && c <= '9' || c >= 'a' && c <= 'f' || c >= 'A' && c <= 'F'
}
