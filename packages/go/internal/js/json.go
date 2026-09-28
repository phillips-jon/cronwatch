package js

import (
	"errors"
	"fmt"
	"math"
	"sort"
	"strconv"
	"strings"
	"unicode/utf16"
	"unicode/utf8"
)

// A JSON value is nil (null), a bool, a float64, a string, a []any or an
// *Object. Stringify also takes whole numbers of Go's integer types and
// anything with a JSValue method.

// Valuer is a type that writes itself as a JSON value.
type Valuer interface {
	JSValue() any
}

// Object is a JavaScript object: keys in JavaScript's order, which is every
// key that is an array index (a canonical whole number below 2^32 - 1) in
// ascending order, then every other key in the order it was first set.
// The zero value is an empty object.
type Object struct {
	keys []string
	vals map[string]any
}

// NewObject is an object holding these key and value pairs, in turn.
func NewObject(pairs ...any) *Object {
	o := &Object{}
	for i := 0; i+1 < len(pairs); i += 2 {
		o.Set(pairs[i].(string), pairs[i+1])
	}
	return o
}

// ArrayIndex reports whether a key is an array index, which JavaScript
// orders before every other key.
func ArrayIndex(key string) (uint32, bool) {
	if key == "" || len(key) > 10 || (len(key) > 1 && key[0] == '0') {
		return 0, false
	}
	n, err := strconv.ParseUint(key, 10, 64)
	if err != nil || n >= 1<<32-1 {
		return 0, false
	}
	return uint32(n), true
}

// Set gives key the value: a new key takes its place in JavaScript's order,
// a key already there keeps its place.
func (o *Object) Set(key string, value any) {
	if o.vals == nil {
		o.vals = map[string]any{}
	}
	if _, ok := o.vals[key]; ok {
		o.vals[key] = value
		return
	}
	o.vals[key] = value
	if n, ok := ArrayIndex(key); ok {
		// Before the first key that is not an index or is a larger index.
		at := sort.Search(len(o.keys), func(i int) bool {
			m, isIndex := ArrayIndex(o.keys[i])
			return !isIndex || m > n
		})
		o.keys = append(o.keys, "")
		copy(o.keys[at+1:], o.keys[at:])
		o.keys[at] = key
		return
	}
	o.keys = append(o.keys, key)
}

// Get is the value at key, and whether the key is there.
func (o *Object) Get(key string) (any, bool) {
	if o == nil {
		return nil, false
	}
	v, ok := o.vals[key]
	return v, ok
}

// Has reports whether the key is there.
func (o *Object) Has(key string) bool {
	_, ok := o.Get(key)
	return ok
}

// Delete removes key.
func (o *Object) Delete(key string) {
	if o == nil {
		return
	}
	if _, ok := o.vals[key]; !ok {
		return
	}
	delete(o.vals, key)
	for i, k := range o.keys {
		if k == key {
			o.keys = append(o.keys[:i], o.keys[i+1:]...)
			break
		}
	}
}

// Keys is Object.keys: the keys in JavaScript's order.
func (o *Object) Keys() []string {
	if o == nil {
		return nil
	}
	return append([]string(nil), o.keys...)
}

// Len is how many keys there are.
func (o *Object) Len() int {
	if o == nil {
		return 0
	}
	return len(o.keys)
}

// Clone is a deep copy, as JSON.parse(JSON.stringify(o)) makes one.
func (o *Object) Clone() *Object {
	if o == nil {
		return nil
	}
	c := &Object{keys: append([]string(nil), o.keys...), vals: make(map[string]any, len(o.vals))}
	for k, v := range o.vals {
		c.vals[k] = CloneValue(v)
	}
	return c
}

// CloneValue is a deep copy of a JSON value.
func CloneValue(v any) any {
	switch t := v.(type) {
	case *Object:
		return t.Clone()
	case []any:
		out := make([]any, len(t))
		for i, e := range t {
			out[i] = CloneValue(e)
		}
		return out
	}
	return v
}

// Stringify is JSON.stringify: the same bytes for the same value. A number
// that is not finite is null, as JavaScript writes it.
func Stringify(v any) string {
	var b strings.Builder
	write(&b, v, false)
	return b.String()
}

// StringifyLone is Stringify for a value whose strings may hold a lone
// surrogate kept by Slice16Lone: each is written as JSON.stringify writes
// one (\ud83d), so a body cut through a surrogate pair is the SDK's bytes.
// Its strings must otherwise be UTF-8 (WellFormed), since the three bytes
// that hold a lone surrogate are not.
func StringifyLone(v any) string {
	var b strings.Builder
	write(&b, v, true)
	return b.String()
}

func write(b *strings.Builder, v any, lone bool) {
	switch t := v.(type) {
	case nil:
		b.WriteString("null")
	case bool:
		if t {
			b.WriteString("true")
		} else {
			b.WriteString("false")
		}
	case float64:
		if math.IsNaN(t) || math.IsInf(t, 0) {
			b.WriteString("null")
		} else {
			b.WriteString(FormatNumber(t))
		}
	case int:
		b.WriteString(FormatNumber(float64(t)))
	case int64:
		b.WriteString(FormatNumber(float64(t)))
	case int32:
		b.WriteString(FormatNumber(float64(t)))
	case string:
		quote(b, t, lone)
	case []any:
		b.WriteByte('[')
		for i, e := range t {
			if i > 0 {
				b.WriteByte(',')
			}
			write(b, e, lone)
		}
		b.WriteByte(']')
	case []string:
		b.WriteByte('[')
		for i, e := range t {
			if i > 0 {
				b.WriteByte(',')
			}
			quote(b, e, lone)
		}
		b.WriteByte(']')
	case *Object:
		if t == nil {
			b.WriteString("null")
			return
		}
		b.WriteByte('{')
		for i, k := range t.keys {
			if i > 0 {
				b.WriteByte(',')
			}
			quote(b, k, lone)
			b.WriteByte(':')
			write(b, t.vals[k], lone)
		}
		b.WriteByte('}')
	case Valuer:
		write(b, t.JSValue(), lone)
	default:
		panic(fmt.Sprintf("js.Stringify: %T is not a JSON value", v))
	}
}

// Quote is JSON.stringify of a string.
func Quote(s string) string {
	var b strings.Builder
	quote(&b, s, false)
	return b.String()
}

const hex = "0123456789abcdef"

func quote(b *strings.Builder, s string, lone bool) {
	b.WriteByte('"')
	start := 0
	for i := 0; i < len(s); {
		c := s[i]
		if c >= 0x20 && c != '"' && c != '\\' && c < utf8.RuneSelf {
			i++
			continue
		}
		if c >= utf8.RuneSelf {
			r, size := utf8.DecodeRuneInString(s[i:])
			if r == utf8.RuneError && size == 1 && lone {
				if u, ok := loneAt(s, i); ok {
					b.WriteString(s[start:i])
					b.WriteString(`\u`)
					for shift := 12; shift >= 0; shift -= 4 {
						b.WriteByte(hex[u>>shift&0xf])
					}
					i += 3
					start = i
					continue
				}
			}
			if r == utf8.RuneError && size == 1 {
				b.WriteString(s[start:i])
				b.WriteString("�")
				i++
				start = i
				continue
			}
			i += size
			continue
		}
		b.WriteString(s[start:i])
		switch c {
		case '"':
			b.WriteString(`\"`)
		case '\\':
			b.WriteString(`\\`)
		case '\b':
			b.WriteString(`\b`)
		case '\f':
			b.WriteString(`\f`)
		case '\n':
			b.WriteString(`\n`)
		case '\r':
			b.WriteString(`\r`)
		case '\t':
			b.WriteString(`\t`)
		default:
			b.WriteString(`\u00`)
			b.WriteByte(hex[c>>4])
			b.WriteByte(hex[c&0xf])
		}
		i++
		start = i
	}
	b.WriteString(s[start:])
	b.WriteByte('"')
}

// Parse is JSON.parse: objects as *Object in JavaScript's key order (a key
// given twice keeps its first place and its last value), numbers as
// float64. A lone surrogate escape (\ud800) becomes U+FFFD.
func Parse(text string) (any, error) {
	p := &parser{s: text}
	p.space()
	v, err := p.value(0)
	if err != nil {
		return nil, err
	}
	p.space()
	if p.i < len(p.s) {
		return nil, p.fail("Unexpected non-whitespace character after JSON")
	}
	return v, nil
}

type parser struct {
	s string
	i int
}

func (p *parser) fail(what string) error {
	return fmt.Errorf("%s at position %d", what, p.i)
}

func (p *parser) space() {
	for p.i < len(p.s) {
		switch p.s[p.i] {
		case ' ', '\t', '\n', '\r':
			p.i++
		default:
			return
		}
	}
}

func (p *parser) value(depth int) (any, error) {
	if depth > 10000 {
		return nil, errors.New("JSON nested too deeply")
	}
	if p.i >= len(p.s) {
		return nil, p.fail("Unexpected end of JSON input")
	}
	switch c := p.s[p.i]; {
	case c == '{':
		p.i++
		o := &Object{}
		p.space()
		if p.i < len(p.s) && p.s[p.i] == '}' {
			p.i++
			return o, nil
		}
		for {
			p.space()
			if p.i >= len(p.s) || p.s[p.i] != '"' {
				return nil, p.fail("Expected property name")
			}
			k, err := p.str()
			if err != nil {
				return nil, err
			}
			p.space()
			if p.i >= len(p.s) || p.s[p.i] != ':' {
				return nil, p.fail("Expected ':' after property name")
			}
			p.i++
			p.space()
			v, err := p.value(depth + 1)
			if err != nil {
				return nil, err
			}
			o.Set(k, v)
			p.space()
			if p.i < len(p.s) && p.s[p.i] == ',' {
				p.i++
				continue
			}
			if p.i < len(p.s) && p.s[p.i] == '}' {
				p.i++
				return o, nil
			}
			return nil, p.fail("Expected ',' or '}' after property value")
		}
	case c == '[':
		p.i++
		out := []any{}
		p.space()
		if p.i < len(p.s) && p.s[p.i] == ']' {
			p.i++
			return out, nil
		}
		for {
			p.space()
			v, err := p.value(depth + 1)
			if err != nil {
				return nil, err
			}
			out = append(out, v)
			p.space()
			if p.i < len(p.s) && p.s[p.i] == ',' {
				p.i++
				continue
			}
			if p.i < len(p.s) && p.s[p.i] == ']' {
				p.i++
				return out, nil
			}
			return nil, p.fail("Expected ',' or ']' after array element")
		}
	case c == '"':
		return p.str()
	case c == 't' && strings.HasPrefix(p.s[p.i:], "true"):
		p.i += 4
		return true, nil
	case c == 'f' && strings.HasPrefix(p.s[p.i:], "false"):
		p.i += 5
		return false, nil
	case c == 'n' && strings.HasPrefix(p.s[p.i:], "null"):
		p.i += 4
		return nil, nil
	case c == '-' || (c >= '0' && c <= '9'):
		return p.number()
	}
	return nil, p.fail("Unexpected token")
}

func (p *parser) number() (any, error) {
	start := p.i
	if p.s[p.i] == '-' {
		p.i++
	}
	digits := func() int {
		n := 0
		for p.i < len(p.s) && p.s[p.i] >= '0' && p.s[p.i] <= '9' {
			p.i++
			n++
		}
		return n
	}
	if p.i < len(p.s) && p.s[p.i] == '0' {
		p.i++
	} else if digits() == 0 {
		return nil, p.fail("No number after minus sign")
	}
	if p.i < len(p.s) && p.s[p.i] == '.' {
		p.i++
		if digits() == 0 {
			return nil, p.fail("Unterminated fractional number")
		}
	}
	if p.i < len(p.s) && (p.s[p.i] == 'e' || p.s[p.i] == 'E') {
		p.i++
		if p.i < len(p.s) && (p.s[p.i] == '+' || p.s[p.i] == '-') {
			p.i++
		}
		if digits() == 0 {
			return nil, p.fail("Exponent part is missing a number")
		}
	}
	f, err := strconv.ParseFloat(p.s[start:p.i], 64)
	if err != nil {
		// Out of range reads as JavaScript reads it: Infinity or 0.
		var ne *strconv.NumError
		if errors.As(err, &ne) && ne.Err == strconv.ErrRange {
			return f, nil
		}
		return nil, err
	}
	return f, nil
}

func (p *parser) str() (string, error) {
	p.i++ // the opening quote
	var b strings.Builder
	start := p.i
	for p.i < len(p.s) {
		c := p.s[p.i]
		switch {
		case c == '"':
			b.WriteString(p.s[start:p.i])
			p.i++
			return b.String(), nil
		case c < 0x20:
			return "", p.fail("Bad control character in string literal")
		case c == '\\':
			b.WriteString(p.s[start:p.i])
			p.i++
			if p.i >= len(p.s) {
				return "", p.fail("Unterminated string")
			}
			e := p.s[p.i]
			p.i++
			switch e {
			case '"', '\\', '/':
				b.WriteByte(e)
			case 'b':
				b.WriteByte('\b')
			case 'f':
				b.WriteByte('\f')
			case 'n':
				b.WriteByte('\n')
			case 'r':
				b.WriteByte('\r')
			case 't':
				b.WriteByte('\t')
			case 'u':
				u, ok := p.hex4()
				if !ok {
					return "", p.fail("Bad Unicode escape")
				}
				r := rune(u)
				if utf16.IsSurrogate(r) {
					if r < 0xdc00 && strings.HasPrefix(p.s[p.i:], `\u`) {
						save := p.i
						p.i += 2
						if lo, ok := p.hex4(); ok && lo >= 0xdc00 && lo < 0xe000 {
							b.WriteRune(utf16.DecodeRune(r, rune(lo)))
							break
						}
						p.i = save
					}
					b.WriteRune(utf8.RuneError)
					break
				}
				b.WriteRune(r)
			default:
				return "", p.fail("Bad escaped character")
			}
			start = p.i
		default:
			p.i++
		}
	}
	return "", p.fail("Unterminated string")
}

func (p *parser) hex4() (uint16, bool) {
	if p.i+4 > len(p.s) {
		return 0, false
	}
	n, err := strconv.ParseUint(p.s[p.i:p.i+4], 16, 16)
	if err != nil {
		return 0, false
	}
	p.i += 4
	return uint16(n), true
}
