// Package js holds what the port needs of JavaScript's own behaviour, so
// that every value the SDK writes, compares, or counts is written, compared,
// and counted the same way here: numbers as Number.prototype.toString
// prints them, JSON.stringify and JSON.parse (objects keep JavaScript's key
// order), string lengths and cuts in UTF-16 code units, the characters \s
// matches, and Date's calendar arithmetic.
package js

import (
	"math"
	"strconv"
	"strings"
)

// MaxSafeInteger is Number.MAX_SAFE_INTEGER.
const MaxSafeInteger = 1<<53 - 1

// FormatNumber is String(n): the shortest digits that read back as n, in
// plain notation from 1e-7 up to 1e21 and exponential notation outside it,
// as Number.prototype.toString writes them.
func FormatNumber(n float64) string {
	switch {
	case math.IsNaN(n):
		return "NaN"
	case math.IsInf(n, 1):
		return "Infinity"
	case math.IsInf(n, -1):
		return "-Infinity"
	case n == 0:
		return "0"
	}
	sign := ""
	if n < 0 {
		sign = "-"
		n = -n
	}
	// The shortest round-tripping digits and the decimal exponent, as
	// ECMAScript's Number::toString defines them: digits d1...dk with the
	// value d1.d2...dk * 10^(e).
	text := strconv.FormatFloat(n, 'e', -1, 64)
	mantissa, exp, _ := strings.Cut(text, "e")
	digits := strings.Replace(mantissa, ".", "", 1)
	e, _ := strconv.Atoi(exp)
	k := len(digits)
	point := e + 1 // ECMAScript's n: the digits are d1...dk * 10^(n-k)
	var b strings.Builder
	b.WriteString(sign)
	switch {
	case k <= point && point <= 21:
		b.WriteString(digits)
		b.WriteString(strings.Repeat("0", point-k))
	case 0 < point && point <= 21:
		b.WriteString(digits[:point])
		b.WriteByte('.')
		b.WriteString(digits[point:])
	case -6 < point && point <= 0:
		b.WriteString("0.")
		b.WriteString(strings.Repeat("0", -point))
		b.WriteString(digits)
	default:
		b.WriteString(digits[:1])
		if k > 1 {
			b.WriteByte('.')
			b.WriteString(digits[1:])
		}
		b.WriteByte('e')
		if point-1 >= 0 {
			b.WriteByte('+')
		}
		b.WriteString(strconv.Itoa(point - 1))
	}
	return b.String()
}

// IsInteger is Number.isInteger.
func IsInteger(n float64) bool {
	return !math.IsNaN(n) && !math.IsInf(n, 0) && n == math.Trunc(n)
}

// FloorDiv is Math.floor(a / b) for whole numbers, b > 0.
func FloorDiv(a, b int64) int64 {
	q := a / b
	if (a%b != 0) && (a < 0) {
		q--
	}
	return q
}

// Mod is a modulo whose result has the sign of b, as Python's % has it.
func Mod(a, b int64) int64 {
	m := a % b
	if m != 0 && (m < 0) != (b < 0) {
		m += b
	}
	return m
}
