package js

import (
	"math"
	"math/big"
	"regexp"
	"strconv"
	"strings"
)

var (
	decimalNumber = regexp.MustCompile(`^[+-]?([0-9]+\.?[0-9]*|\.[0-9]+)([eE][+-]?[0-9]+)?$`)
	radixNumber   = regexp.MustCompile(`^0([xXoObB])([0-9a-fA-F]+)$`)
)

// Number is Number(text): trimmed as String.prototype.trim trims, then
// decimal, 0x, 0o or 0b, Infinity, or NaN; "" (or only whitespace) is 0.
func Number(text string) float64 {
	text = Trim(text)
	switch {
	case text == "":
		return 0
	case decimalNumber.MatchString(text):
		n, _ := strconv.ParseFloat(text, 64)
		return n
	case text == "Infinity" || text == "+Infinity":
		return math.Inf(1)
	case text == "-Infinity":
		return math.Inf(-1)
	}
	if m := radixNumber.FindStringSubmatch(text); m != nil {
		base := map[byte]int{'x': 16, 'o': 8, 'b': 2}[strings.ToLower(m[1])[0]]
		n, ok := new(big.Int).SetString(m[2], base)
		if !ok {
			return math.NaN()
		}
		f, _ := new(big.Float).SetInt(n).Float64()
		return f
	}
	return math.NaN()
}
