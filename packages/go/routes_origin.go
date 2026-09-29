package cronwatch

// Origins read as the SDK's `new URL(value).origin` reads them: spaces and
// control characters around the value and tabs or line breaks in it are
// dropped, slashes after the scheme may be missing or backslashes,
// credentials are ignored, the host is lowercased (percent escapes decoded,
// IPv4 numbers written out, IPv6 compressed, a host outside ASCII written
// in punycode) and a default port is left out.

import (
	"errors"
	"fmt"
	"math"
	"net/http"
	"net/netip"
	"regexp"
	"strconv"
	"strings"
	"unicode/utf8"

	"cronwatch.dev/go/internal/js"
)

var (
	errNotURL  = errors.New("not a URL")
	errNotHTTP = errors.New("not http or https")

	schemeRE       = regexp.MustCompile(`(?s)^([A-Za-z][A-Za-z0-9+.\-]*):(.*)$`)
	forbiddenHost  = regexp.MustCompile(`[\x00-\x20#%/:<>?@\[\\\]^|\x7f]`)
	decimalLabel   = regexp.MustCompile(`^[0-9]+$`)
	hexLabel       = regexp.MustCompile(`^0[xX][0-9A-Fa-f]*$`)
	octalLabel     = regexp.MustCompile(`^0[0-7]+$`)
	defaultPortFor = map[string]int{"http": 80, "https": 443}
)

// configuredOrigin is the origin option as scheme://host[:port], "" for "",
// or the SDK's error for anything that is not an http or https URL, so a
// typo fails when the routes are made.
func configuredOrigin(value string) (string, error) {
	if value == "" {
		return "", nil
	}
	origin, _, err := readOrigin(value)
	switch {
	case errors.Is(err, errNotHTTP):
		return "", fmt.Errorf("routes: origin must be http or https, got %s", js.Quote(value))
	case err != nil:
		return "", fmt.Errorf("routes: origin must be an absolute URL such as \"https://app.example.com\", got %s", js.Quote(value))
	}
	return origin, nil
}

// bareOrigin is scheme://host[:port] for text that is a scheme and a bare
// host, or false when it carries a path, credentials, a query or a
// fragment, or is not an http or https URL.
func bareOrigin(value string) (string, bool) {
	origin, extra, err := readOrigin(value)
	if err != nil || extra {
		return "", false
	}
	return origin, true
}

// readOrigin is the origin of value, and whether anything past the host
// would show in the URL (a path other than "/", credentials, a query or a
// fragment).
func readOrigin(value string) (origin string, extra bool, err error) {
	text := strings.TrimFunc(value, func(r rune) bool { return r <= 0x20 })
	text = strings.NewReplacer("\t", "", "\n", "", "\r", "").Replace(text)
	m := schemeRE.FindStringSubmatch(text)
	if m == nil {
		return "", false, errNotURL
	}
	scheme := strings.ToLower(m[1])
	defaultPort, ok := defaultPortFor[scheme]
	if !ok {
		return "", false, errNotHTTP
	}
	rest := strings.TrimLeft(m[2], `/\`)
	end := len(rest)
	if i := strings.IndexAny(rest, `/\?#`); i >= 0 {
		end = i
	}
	authority, after := rest[:end], rest[end:]
	hostport := authority
	userinfo, hasAt := "", false
	if i := strings.LastIndex(authority, "@"); i >= 0 {
		userinfo, hostport, hasAt = authority[:i], authority[i+1:], true
	}
	host, port, err := splitPort(hostport)
	if err != nil {
		return "", false, err
	}
	host, err = readHost(host)
	if err != nil {
		return "", false, err
	}
	shown := ""
	if port >= 0 && port != defaultPort {
		shown = ":" + strconv.Itoa(port)
	}
	extra = (hasAt && userinfo != "" && userinfo != ":") || pastHost(after)
	return scheme + "://" + host + shown, extra, nil
}

func pastHost(after string) bool {
	path, fragment, hasFragment := strings.Cut(after, "#")
	path, query, _ := strings.Cut(path, "?")
	return (path != "" && path != "/" && path != `\`) || query != "" || (hasFragment && fragment != "")
}

// splitPort is the host and the port (-1 for none) of host[:port].
func splitPort(authority string) (string, int, error) {
	var host, rest string
	if strings.HasPrefix(authority, "[") {
		end := strings.Index(authority, "]")
		if end < 0 {
			return "", 0, errNotURL
		}
		host, rest = authority[:end+1], authority[end+1:]
	} else if i := strings.LastIndex(authority, ":"); i >= 0 {
		host, rest = authority[:i], authority[i:]
	} else {
		host = authority
	}
	if rest == "" || rest == ":" {
		return host, -1, nil
	}
	if !strings.HasPrefix(rest, ":") || !decimalLabel.MatchString(rest[1:]) {
		return "", 0, errNotURL
	}
	digits := strings.TrimLeft(rest[1:], "0")
	if len(digits) > 5 {
		return "", 0, errNotURL
	}
	port, _ := strconv.Atoi("0" + digits)
	if port > 65535 {
		return "", 0, errNotURL
	}
	return host, port, nil
}

func readHost(host string) (string, error) {
	if host == "" {
		return "", errNotURL
	}
	if strings.HasPrefix(host, "[") {
		if !strings.HasSuffix(host, "]") || strings.Contains(host, "%") {
			return "", errNotURL
		}
		addr, err := netip.ParseAddr(host[1 : len(host)-1])
		if err != nil || !addr.Is6() {
			return "", errNotURL
		}
		return "[" + ipv6Text(addr) + "]", nil
	}
	decoded := percentDecode(host)
	if !utf8.ValidString(decoded) {
		return "", errNotURL
	}
	decoded = strings.ToLower(decoded)
	if !isASCII(decoded) {
		// Punycode takes time in the label's length times its distinct
		// characters, and a Host header is anyone's to send: a name no
		// DNS could hold (253 bytes) is refused well past that bound.
		if len(decoded) > maxIDNHost {
			return "", errNotURL
		}
		labels := strings.Split(decoded, ".")
		for i, label := range labels {
			if !isASCII(label) {
				encoded, ok := punycode(label)
				if !ok {
					return "", errNotURL
				}
				labels[i] = "xn--" + encoded
			}
		}
		decoded = strings.Join(labels, ".")
	}
	if decoded == "" || forbiddenHost.MatchString(decoded) {
		return "", errNotURL
	}
	if v4, isV4, err := ipv4(decoded); err != nil {
		return "", err
	} else if isV4 {
		return v4, nil
	}
	return decoded, nil
}

// maxIDNHost is the longest host outside ASCII read, in bytes.
const maxIDNHost = 1024

func isASCII(s string) bool {
	for i := 0; i < len(s); i++ {
		if s[i] >= 0x80 {
			return false
		}
	}
	return true
}

// ipv6Text is an IPv6 address as the URL serializer writes it: groups in
// lowercase hex, the first longest run of two or more zero groups as "::",
// and never the dotted form.
func ipv6Text(addr netip.Addr) string {
	b := addr.As16()
	var groups [8]uint16
	for i := range groups {
		groups[i] = uint16(b[2*i])<<8 | uint16(b[2*i+1])
	}
	start, length := -1, 0
	for i := 0; i < 8; {
		if groups[i] != 0 {
			i++
			continue
		}
		j := i
		for j < 8 && groups[j] == 0 {
			j++
		}
		if j-i > length && j-i > 1 {
			start, length = i, j-i
		}
		i = j
	}
	var out strings.Builder
	for i := 0; i < 8; i++ {
		if i == start {
			if i == 0 {
				out.WriteString("::")
			} else {
				out.WriteString(":")
			}
			i += length - 1
			continue
		}
		out.WriteString(strconv.FormatUint(uint64(groups[i]), 16))
		if i < 7 {
			out.WriteString(":")
		}
	}
	return out.String()
}

// ipv4 is WHATWG's IPv4 parser, for a host whose last label is a number:
// "127.1" and "0x7f.1" are 127.0.0.1. False for a host that is a name.
func ipv4(host string) (string, bool, error) {
	parts := strings.Split(host, ".")
	if len(parts) > 1 && parts[len(parts)-1] == "" {
		parts = parts[:len(parts)-1]
	}
	last := parts[len(parts)-1]
	if !decimalLabel.MatchString(last) && !hexLabel.MatchString(last) {
		return "", false, nil
	}
	if len(parts) > 4 {
		return "", false, errNotURL
	}
	numbers := make([]float64, len(parts))
	for i, p := range parts {
		n, err := ipv4Number(p)
		if err != nil {
			return "", false, err
		}
		numbers[i] = n
	}
	for _, n := range numbers[:len(numbers)-1] {
		if n > 255 {
			return "", false, errNotURL
		}
	}
	lastN := numbers[len(numbers)-1]
	if lastN >= math.Pow(256, float64(5-len(numbers))) {
		return "", false, errNotURL
	}
	address := lastN
	for i, n := range numbers[:len(numbers)-1] {
		address += n * math.Pow(256, float64(3-i))
	}
	a := uint32(address)
	return fmt.Sprintf("%d.%d.%d.%d", a>>24, a>>16&255, a>>8&255, a&255), true, nil
}

func ipv4Number(part string) (float64, error) {
	switch {
	case part == "":
		return 0, errNotURL
	case hexLabel.MatchString(part):
		if len(part) == 2 {
			return 0, nil
		}
		return parseBig(part[2:], 16)
	case octalLabel.MatchString(part):
		return parseBig(part[1:], 8)
	case decimalLabel.MatchString(part) && (part == "0" || !strings.HasPrefix(part, "0")):
		return parseBig(part, 10)
	}
	return 0, errNotURL
}

// parseBig reads digits too long for an integer as the float the checks
// above compare, which is past every limit they test.
func parseBig(digits string, base int) (float64, error) {
	if n, err := strconv.ParseUint(digits, base, 64); err == nil {
		return float64(n), nil
	}
	return math.Inf(1), nil
}

// punycode is RFC 3492's encoding of one label, without the "xn--".
func punycode(label string) (string, bool) {
	const (
		base, tMin, tMax, skew, damp = 36, 1, 26, 38, 700
		initialBias, initialN        = 72, 128
	)
	runes := []rune(label)
	var out []byte
	for _, r := range runes {
		if r < 0x80 {
			out = append(out, byte(r))
		}
	}
	basic := len(out)
	handled := basic
	if basic > 0 {
		out = append(out, '-')
	}
	digit := func(d int) byte {
		if d < 26 {
			return byte('a' + d)
		}
		return byte('0' + d - 26)
	}
	adapt := func(delta, points int, first bool) int {
		if first {
			delta /= damp
		} else {
			delta /= 2
		}
		delta += delta / points
		k := 0
		for delta > ((base-tMin)*tMax)/2 {
			delta /= base - tMin
			k += base
		}
		return k + (base-tMin+1)*delta/(delta+skew)
	}
	n, delta, bias := initialN, 0, initialBias
	for handled < len(runes) {
		m := math.MaxInt32
		for _, r := range runes {
			if int(r) >= n && int(r) < m {
				m = int(r)
			}
		}
		if (m-n)*(handled+1) > math.MaxInt32-delta {
			return "", false
		}
		delta += (m - n) * (handled + 1)
		n = m
		for _, r := range runes {
			if int(r) < n {
				delta++
			}
			if int(r) == n {
				q := delta
				for k := base; ; k += base {
					t := k - bias
					if t < tMin {
						t = tMin
					} else if t > tMax {
						t = tMax
					}
					if q < t {
						break
					}
					out = append(out, digit(t+(q-t)%(base-t)))
					q = (q - t) / (base - t)
				}
				out = append(out, digit(q))
				bias = adapt(delta, handled+1, handled == basic)
				delta = 0
				handled++
			}
		}
		delta++
		n++
	}
	return string(out), true
}

// requestOrigin is the origin of the request's own URL: its scheme (https
// when it came over TLS) and Host, lowercased and without a default port.
func requestOrigin(r *http.Request) string {
	scheme := "http"
	if r.TLS != nil {
		scheme = "https"
	}
	host := r.Host
	if host == "" && r.URL != nil {
		host = r.URL.Host
	}
	if origin, ok := bareOrigin(scheme + "://" + host); ok {
		return origin
	}
	return scheme + "://" + strings.ToLower(host)
}
