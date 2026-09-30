// Package output is the SDK's output.ts and the recorder of job.ts: the
// output cap, error text, secret redaction, and the lines and metrics a
// run collects. Lengths and cuts are in UTF-16 code units, as JavaScript
// counts them, so the same output is capped at the same character here
// and in every other port.
package output

import (
	"bytes"
	"encoding/json"
	"fmt"
	"math"
	"reflect"
	"runtime"
	"strings"
	"unicode"
	"unicode/utf8"

	"cronwatch.dev/go/internal/js"
	"cronwatch.dev/go/internal/jsre"
)

// OutputCap is how much output a run keeps: 16 KB of UTF-16 code units,
// the tail. A chatty job cannot fill the store.
const OutputCap = 16 * 1024

// StripNul removes every U+0000. Postgres refuses NUL in TEXT and JSONB, and
// the whole run row would be lost with it.
func StripNul(s string) string {
	if !strings.Contains(s, "\x00") {
		return s
	}
	return strings.ReplaceAll(s, "\x00", "")
}

// StripJSONNul removes every U+0000 from JSON text, keys and strings alike,
// by dropping each \u0000 escape (a NUL can appear in JSON no other way).
// Escapes are read left to right in pairs, so an escaped backslash followed
// by "u0000" is left as it is.
func StripJSONNul(text string) string {
	if !strings.Contains(text, `\u0000`) {
		return text
	}
	var b strings.Builder
	b.Grow(len(text))
	for i := 0; i < len(text); i++ {
		if text[i] != '\\' || i+1 >= len(text) {
			b.WriteByte(text[i])
			continue
		}
		if strings.HasPrefix(text[i+1:], "u0000") {
			i += 5
			continue
		}
		b.WriteByte(text[i])
		b.WriteByte(text[i+1])
		i++
	}
	return b.String()
}

// CapOutput removes NULs, then keeps the last OutputCap code units behind
// a line saying the rest was trimmed. A cut through a surrogate pair
// leaves U+FFFD, the character JavaScript's lone half becomes once written
// out as UTF-8, so the stored bytes are the same.
func CapOutput(s string) string {
	clean := StripNul(s)
	// Each byte is at most one code unit, so a short text needs no count.
	if len(clean) <= OutputCap || js.Length16(clean) <= OutputCap {
		return clean
	}
	return "[earlier output trimmed]\n" + js.Tail16(clean, OutputCap)
}

// Describe is an error as a JavaScript stack reads: "Name: message", then
// up to five frames, each "    at <frame>".
func Describe(name, message string, frames []string) string {
	var b strings.Builder
	b.WriteString(name)
	b.WriteString(": ")
	b.WriteString(message)
	for i, f := range frames {
		if i == 5 {
			break
		}
		b.WriteString("\n    at ")
		b.WriteString(f)
	}
	return b.String()
}

// DescribeError is describeError for a Go value: an error as "Name:
// message" (see ErrorName), a string as it is, and anything else as its
// JSON, as the SDK writes a thrown value that is not an Error. Go errors
// carry no stack, so an error has no frames; a panic's frames are read
// where it is recovered (PanicMessage).
func DescribeError(v any) string {
	switch t := v.(type) {
	case string:
		return js.WellFormed(t)
	case error:
		return ErrorName(t) + ": " + js.WellFormed(errorText(t))
	}
	return jsonText(v)
}

// errorText is err.Error(), or what fmt prints for err when that panics
// (a nil *MyErr returned as an error, whose method reads its receiver):
// "<nil>", or fmt's "%!v(PANIC=...)", never a panic out of CronWatch.
func errorText(err error) (text string) {
	defer func() {
		if recover() != nil {
			text = fmt.Sprint(err)
		}
	}()
	return err.Error()
}

// ErrorMessage is errorMessage: the error described, capped like output.
func ErrorMessage(v any) string {
	return CapOutput(DescribeError(v))
}

// ErrorName is the name an error goes by in "Name: message": its type's
// name, without the pointer or the package, when the type is exported
// (*fs.PathError is "PathError"). Errors made by errors.New and fmt.Errorf,
// joined errors and unexported types are "Error", as a plain JavaScript
// Error is, since their type names say nothing to a reader.
func ErrorName(err error) string {
	t := reflect.TypeOf(err)
	for t != nil && t.Kind() == reflect.Pointer {
		t = t.Elem()
	}
	if t == nil {
		return "Error"
	}
	name := t.Name()
	if r, _ := utf8.DecodeRuneInString(name); name == "" || !unicode.IsUpper(r) {
		return "Error"
	}
	return name
}

// PanicMessage is a recovered panic as a failed run's error: "panic:
// <value>" and up to five frames of the goroutine that panicked, innermost
// first, as "function (file:line)", capped like output. Call it from the
// deferred function that recovered the value, so the panicking frames are
// still on the stack.
func PanicMessage(value any) string {
	return CapOutput(Describe("panic", js.WellFormed(fmt.Sprint(value)), panicFrames()))
}

// panicFrames reads the stack of the deferred call: the frames below
// runtime.gopanic are the ones that panicked. Runtime frames (the panic
// machinery, a nil dereference's sigpanic) are left out.
func panicFrames() []string {
	pcs := make([]uintptr, 64)
	n := runtime.Callers(1, pcs)
	frames := runtime.CallersFrames(pcs[:n])
	var out []string
	var all []string
	panicking := false
	for {
		f, more := frames.Next()
		if f.Function == "runtime.gopanic" {
			panicking = true
			out = out[:0]
		} else if !strings.HasPrefix(f.Function, "runtime.") {
			line := fmt.Sprintf("%s (%s:%d)", f.Function, f.File, f.Line)
			all = append(all, line)
			if panicking {
				out = append(out, line)
			}
		}
		if !more || (panicking && len(out) == 5) {
			break
		}
	}
	if !panicking {
		// Not called during a panic: the caller's frames, after this package's.
		out = out[:0]
		for _, f := range all {
			if !strings.Contains(f, "cronwatch.dev/go/internal/output.") {
				out = append(out, f)
			}
		}
	}
	if len(out) > 5 {
		out = out[:5]
	}
	return out
}

// LogText is one part of a logged line, as job.ts's stringify writes it:
// a string as it is, an error as "Name: message", anything else as JSON.
func LogText(part any) string {
	switch t := part.(type) {
	case string:
		return js.WellFormed(t)
	case error:
		return ErrorName(t) + ": " + js.WellFormed(errorText(t))
	}
	return jsonText(part)
}

// jsonText is JSON.stringify(v) for a Go value. The package's own JSON
// values (and js.Valuer) write exactly what JavaScript writes; Go numbers
// print as JavaScript prints them (NaN and infinities as null); anything
// else goes through encoding/json without HTML escaping, and failing that,
// fmt.Sprint.
func jsonText(v any) string {
	switch t := v.(type) {
	case nil:
		return "null"
	case bool, float64, int, int64, int32, string, []any, *js.Object, js.Valuer:
		return js.Stringify(t)
	case int8, int16, uint, uint8, uint16, uint32, uint64, uintptr, float32:
		f := reflect.ValueOf(t).Convert(reflect.TypeOf(float64(0))).Float()
		if math.IsNaN(f) || math.IsInf(f, 0) {
			return "null"
		}
		return js.FormatNumber(f)
	}
	var buf bytes.Buffer
	enc := json.NewEncoder(&buf)
	enc.SetEscapeHTML(false)
	if err := enc.Encode(v); err != nil {
		return js.WellFormed(fmt.Sprint(v))
	}
	return js.WellFormed(strings.TrimSuffix(buf.String(), "\n"))
}

// Redacted replaces a secret.
const Redacted = "[redacted]"

// pattern is one of the SDK's secret patterns and what replaces a match.
type pattern struct {
	re      *jsre.Regexp
	replace func(*jsre.Match) []uint16
}

// template replaces a match with a replacement string in which "$1"
// stands for group 1 (the only group the SDK's replacements name). The
// group goes in as code units, so a surrogate pair is never split and put
// back together.
func template(re *jsre.Regexp, text string) pattern {
	pieces := strings.Split(text, "$1")
	units := make([][]uint16, len(pieces))
	for i, p := range pieces {
		units[i] = js.Units(p)
	}
	return pattern{re, func(m *jsre.Match) []uint16 {
		group, _ := m.Group(1)
		out := append([]uint16{}, units[0]...)
		for _, p := range units[1:] {
			out = append(append(out, group...), p...)
		}
		return out
	}}
}

// The SDK's patterns (packages/sdk/src/output.ts, SECRET_PATTERNS), as
// JavaScript source, character for character, compiled by jsre so they
// match what they match in JavaScript. Bounded quantifiers throughout, so
// a long line cannot make these backtrack. They apply in this order, each
// to the text the ones before it left.
var patterns = []pattern{
	// A PEM private key, header to footer. Without a footer (the output was
	// trimmed) it runs to the end of the base64 body. A "-" that starts five
	// dashes ends the body, so the footer is never swallowed into it.
	template(jsre.MustCompile(`-----BEGIN (?:[A-Z0-9]{1,20} ){0,3}PRIVATE KEY-----(?:[A-Za-z0-9+/=\s,:]|-(?!----)){0,16384}(?:-----END (?:[A-Z0-9]{1,20} ){0,3}PRIVATE KEY-----)?`, "g"), Redacted),
	// password=..., API_KEY: ..., "client_secret": "...", TOKEN='...', token=...,
	// :password=>"..." (but not max_tokens: 800). A quoted value is blanked to
	// its closing quote, spaces and all, and keeps its quotes.
	{
		jsre.MustCompile(`\b([A-Za-z0-9_-]{0,40}(?:secret|token|passw(?:or)?d|pwd|api[_-]?key|access[_-]?key|private[_-]?key|credential)[A-Za-z0-9_-]{0,40}(?<![Tt][Oo][Kk][Ee][Nn][Ss])"?\s{0,3}(?:=>|[=:])\s{0,3})(?:(")[^"\n]{1,4096}"|(')[^'\n]{1,4096}'|["']?[^\s"',;&]{1,4096})`, "gi"),
		func(m *jsre.Match) []uint16 {
			quote, ok := m.Group(2)
			if !ok {
				quote, _ = m.Group(3)
			}
			name, _ := m.Group(1)
			out := append(append([]uint16{}, name...), quote...)
			out = append(out, js.Units(Redacted)...)
			return append(out, quote...)
		},
	},
	// Authorization: Basic <base64> and Authorization: Token <token>, also as a JSON or hash entry.
	template(jsre.MustCompile(`\b((?:proxy-)?authorization["']?\s{0,3}(?:=>|[=:])\s{0,3}["']?\s{0,3}(?:basic|token)\s{1,3})[A-Za-z0-9._~+/=:-]{1,4096}`, "gi"), "$1"+Redacted),
	// Credentials inside a URL: postgres://user:password@host. The password
	// runs to the last "@" before a "/" or a space, so one that contains "@"
	// is blanked whole.
	template(jsre.MustCompile(`(\b[a-z][a-z0-9+.-]{0,30}:\/\/[^\s/:@]{0,256}:)[^\s/]{1,256}@`, "gi"), "$1"+Redacted+"@"),
	// Authorization: Bearer <token>
	template(jsre.MustCompile(`\b(Bearer\s{1,3})[A-Za-z0-9._~+/=-]{8,4096}`, "g"), "$1"+Redacted),
	// A bare JWT: three base64url segments, the first starting eyJ.
	template(jsre.MustCompile(`\beyJ[A-Za-z0-9_-]{4,4096}\.[A-Za-z0-9_-]{4,4096}\.[A-Za-z0-9_-]{0,4096}`, "g"), Redacted),
	// Incoming webhook URLs carry their secret in the path.
	template(jsre.MustCompile(`(\bhooks\.slack\.com\/(?:services|workflows|triggers)\/)[A-Za-z0-9/_-]{1,255}`, "gi"), "$1"+Redacted),
	template(jsre.MustCompile(`(\bdiscord(?:app)?\.com\/api\/(?:v\d{1,2}\/)?webhooks\/)[A-Za-z0-9/_-]{1,255}`, "gi"), "$1"+Redacted),
	// Well-known token shapes: AWS, GitHub, Slack, Stripe, Anthropic, OpenAI and Google style keys.
	template(jsre.MustCompile(`\b(?:AKIA|ASIA)[0-9A-Z]{16}\b`, "g"), Redacted),
	template(jsre.MustCompile(`\b(?:gh[pousr]_[A-Za-z0-9]{30,255}|github_pat_[A-Za-z0-9_]{20,255})\b`, "g"), Redacted),
	template(jsre.MustCompile(`\bxox[abposr]-[A-Za-z0-9-]{10,255}`, "g"), Redacted),
	template(jsre.MustCompile(`\b[rsp]k_(?:live|test)_[A-Za-z0-9]{10,255}\b`, "g"), Redacted),
	template(jsre.MustCompile(`\bwhsec_[A-Za-z0-9+/=]{16,255}`, "g"), Redacted),
	template(jsre.MustCompile(`\bsk-[A-Za-z0-9_-]{20,255}`, "g"), Redacted),
	template(jsre.MustCompile(`\bAIza[0-9A-Za-z_-]{35}(?![0-9A-Za-z_-])`, "g"), Redacted),
}

// RedactSecrets is the default redact: it blanks values that look like
// secrets (key=value pairs with secret-ish names, Authorization headers,
// URL credentials, bearer tokens, JWTs, PEM private keys, webhook URLs and
// well-known token formats) before output or an error is stored, shown or
// sent anywhere. The text is matched as UTF-16 code units, as JavaScript
// holds it, and turned back into UTF-8 once at the end, so a match that
// cut a character outside the BMP in two leaves U+FFFD where JavaScript
// leaves the lone surrogate that becomes U+FFFD when it is written out.
func RedactSecrets(text string) string {
	units := js.Units(text)
	for _, p := range patterns {
		units = p.re.ReplaceUnits(units, p.replace)
	}
	return js.FromUnits(units)
}
