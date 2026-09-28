package js

import (
	"strings"
	"unicode/utf8"
)

// Whitespace is the character class JavaScript's \s matches, and what
// String.prototype.trim removes: WhiteSpace and LineTerminator, written for
// a Go character class.
const Whitespace = `\t\n\v\f\r \x{a0}\x{1680}\x{2000}-\x{200a}\x{2028}\x{2029}\x{202f}\x{205f}\x{3000}\x{feff}`

// IsSpace reports whether JavaScript's \s matches r.
func IsSpace(r rune) bool {
	switch r {
	case '\t', '\n', '\v', '\f', '\r', ' ', 0xa0, 0x1680, 0x2028, 0x2029, 0x202f, 0x205f, 0x3000, 0xfeff:
		return true
	}
	return r >= 0x2000 && r <= 0x200a
}

// Trim is String.prototype.trim.
func Trim(s string) string {
	return strings.TrimFunc(s, IsSpace)
}

// TrimEnd is String.prototype.trimEnd.
func TrimEnd(s string) string {
	return strings.TrimRightFunc(s, IsSpace)
}

// WellFormed is the text with every byte that is not UTF-8 replaced by
// U+FFFD, as a JavaScript string decoded from those bytes has it.
func WellFormed(s string) string {
	if utf8.ValidString(s) {
		return s
	}
	var b strings.Builder
	for _, r := range s {
		b.WriteRune(r)
	}
	return b.String()
}

// units is how many UTF-16 code units r takes.
func units(r rune) int {
	if r >= 0x10000 {
		return 2
	}
	return 1
}

// Length16 is a string's .length: its UTF-16 code units.
func Length16(s string) int {
	n := 0
	for _, r := range s {
		n += units(r)
	}
	return n
}

// Slice16 is s.slice(start, end) in UTF-16 code units, with JavaScript's
// clamping (a negative index counts from the end). A cut through a
// surrogate pair keeps the lone half, which is written here as U+FFFD, the
// character it becomes once written out as UTF-8, so a stored or hashed
// result is the same bytes.
func Slice16(s string, start, end int) string {
	n := Length16(s)
	clamp := func(i int) int {
		if i < 0 {
			i += n
			if i < 0 {
				i = 0
			}
		}
		if i > n {
			i = n
		}
		return i
	}
	start, end = clamp(start), clamp(end)
	if start >= end {
		return ""
	}
	if start == 0 && end == n {
		return s
	}
	var b strings.Builder
	at := 0
	for _, r := range s {
		w := units(r)
		lo, hi := at, at+w
		at = hi
		if hi <= start {
			continue
		}
		if lo >= end {
			break
		}
		if lo >= start && hi <= end {
			b.WriteRune(r)
		} else {
			b.WriteRune(utf8.RuneError)
		}
	}
	return b.String()
}

// Head16 is s.slice(0, n).
func Head16(s string, n int) string {
	return Slice16(s, 0, n)
}

// Tail16 is s.slice(s.length - n): the last n code units.
func Tail16(s string, n int) string {
	return Slice16(s, Length16(s)-n, Length16(s))
}

// Units is the string as UTF-16 code units, as JavaScript holds it.
func Units(s string) []uint16 {
	out := make([]uint16, 0, len(s))
	for _, r := range s {
		if r >= 0x10000 {
			r -= 0x10000
			out = append(out, uint16(0xd800+(r>>10)), uint16(0xdc00+(r&0x3ff)))
		} else {
			out = append(out, uint16(r))
		}
	}
	return out
}

// FromUnits is the text of UTF-16 code units; a lone surrogate becomes
// U+FFFD, as it does once JavaScript writes it out as UTF-8.
func FromUnits(u []uint16) string {
	var b strings.Builder
	b.Grow(len(u))
	for i := 0; i < len(u); i++ {
		c := rune(u[i])
		switch {
		case c >= 0xd800 && c < 0xdc00 && i+1 < len(u) && u[i+1] >= 0xdc00 && u[i+1] < 0xe000:
			b.WriteRune(0x10000 + (c-0xd800)<<10 + (rune(u[i+1]) - 0xdc00))
			i++
		case c >= 0xd800 && c < 0xe000:
			b.WriteRune(utf8.RuneError)
		default:
			b.WriteRune(c)
		}
	}
	return b.String()
}
