package cronwatch

// What the dashboard's pages need to write values the way the SDK's
// templates do (routes/escape.ts and JavaScript itself): escapeHtml,
// escapeName, String(value), toFixed, Math.round and encodeURIComponent.

import (
	"crypto/subtle"
	"encoding/binary"
	"math"
	"math/big"
	"strings"

	"cronwatch.dev/go/internal/js"
)

var htmlEscaper = strings.NewReplacer("&", "&amp;", "<", "&lt;", ">", "&gt;", `"`, "&quot;", "'", "&#39;")

// escapeHTML is escapeHtml for text: & < > " and ' escaped. Every string a
// page shows goes through it.
func escapeHTML(s string) string { return htmlEscaper.Replace(js.WellFormed(s)) }

// escapeValue is escapeHtml(value) for a JSON value: String(value ?? "").
func escapeValue(v any) string {
	if v == nil {
		return ""
	}
	return escapeHTML(jsText(v, true))
}

// escapeName is escapeName: a job name shown as text, with <wbr> after each
// run of _ : . / - that something else follows, so a long name wraps at its
// separators. Only for text, never an attribute, a URL, or a title.
func escapeName(s string) string {
	text := escapeHTML(s)
	isSep := func(c byte) bool { return c == '_' || c == ':' || c == '.' || c == '/' || c == '-' }
	var b strings.Builder
	b.Grow(len(text) + 16)
	for i := 0; i < len(text); i++ {
		b.WriteByte(text[i])
		if isSep(text[i]) && i+1 < len(text) && !isSep(text[i+1]) {
			b.WriteString("<wbr>")
		}
	}
	return b.String()
}

// num is String(n) for a number.
func num[N ~int | ~int64 | ~float64](n N) string { return js.FormatNumber(float64(n)) }

// toFixed is Number.prototype.toFixed: the decimal nearest the exact value
// of the double, a half rounded away from zero (Go's own formatting rounds
// a half to even).
func toFixed(x float64, digits int) string {
	if math.IsNaN(x) || math.IsInf(x, 0) || math.Abs(x) >= 1e21 {
		return js.FormatNumber(x)
	}
	r := new(big.Rat).SetFloat64(math.Abs(x))
	r.Mul(r, new(big.Rat).SetInt(new(big.Int).Exp(big.NewInt(10), big.NewInt(int64(digits)), nil)))
	r.Add(r, big.NewRat(1, 2))
	n := new(big.Int).Quo(r.Num(), r.Denom())
	text := n.String()
	if digits > 0 {
		if len(text) <= digits {
			text = strings.Repeat("0", digits+1-len(text)) + text
		}
		text = text[:len(text)-digits] + "." + text[len(text)-digits:]
	}
	if x < 0 {
		return "-" + text
	}
	return text
}

// jsRound is Math.round: the nearest whole number, a half rounded up.
func jsRound(x float64) float64 {
	if math.IsNaN(x) || math.IsInf(x, 0) {
		return x
	}
	f := math.Floor(x)
	if x-f >= 0.5 {
		return f + 1
	}
	return f
}

// encodeURIComponent is encodeURIComponent for well-formed text.
func encodeURIComponent(s string) string {
	const hex = "0123456789ABCDEF"
	var b strings.Builder
	for _, c := range []byte(js.WellFormed(s)) {
		switch {
		case c >= 'a' && c <= 'z', c >= 'A' && c <= 'Z', c >= '0' && c <= '9', strings.IndexByte("-_.!~*'()", c) >= 0:
			b.WriteByte(c)
		default:
			b.WriteByte('%')
			b.WriteByte(hex[c>>4])
			b.WriteByte(hex[c&15])
		}
	}
	return b.String()
}

// latin1 is text read from the wire as fetch's Headers read it: each byte
// one character.
func latin1(s string) string {
	for i := 0; i < len(s); i++ {
		if s[i] >= 0x80 {
			var b strings.Builder
			for j := 0; j < len(s); j++ {
				b.WriteRune(rune(s[j]))
			}
			return b.String()
		}
	}
	return s
}

// constantTimeEqual compares two secrets without stopping at the first
// character that differs, over UTF-16 code units as the SDK compares them.
func constantTimeEqual(a, b string) bool {
	ua, ub := js.Units(a), js.Units(b)
	if len(ua) != len(ub) {
		return false
	}
	ba, bb := make([]byte, 2*len(ua)), make([]byte, 2*len(ub))
	for i := range ua {
		binary.LittleEndian.PutUint16(ba[2*i:], ua[i])
		binary.LittleEndian.PutUint16(bb[2*i:], ub[i])
	}
	return subtle.ConstantTimeCompare(ba, bb) == 1
}
