// Package schedule is the SDK's duration.ts and schedule.ts: durations
// ("15m", "1h30m", a number of milliseconds) parsed and written as the SDK
// does, and schedules ("0 2 * * *", "@hourly", "every 5m") with their fire
// times, due times, deadlines, and what a run covers. Cron fire times come
// from the port of croner in the cron package, so a Go process and a Node,
// Ruby, Python, or PHP process sharing one store agree on every due time.
//
// Where it cannot match the SDK, see the cron package: a date no month has
// never fires, and croner's one-time dates are refused.
package schedule

import (
	"errors"
	"fmt"
	"math"
	"strconv"
	"strings"
	"time"

	"cronwatch.dev/go/internal/js"
)

var unitMs = map[string]float64{"ms": 1, "s": 1000, "m": 60_000, "h": 3_600_000, "d": 86_400_000, "w": 604_800_000}

// round is Math.round: halves go up, toward positive infinity.
func round(x float64) float64 {
	r := math.Floor(x)
	if x-r >= 0.5 {
		r++
	}
	return r
}

// ParseDuration is the SDK's parseDuration: "15m" is 900000. It takes a
// string, a number of milliseconds (float64, int, int64), or a
// time.Duration (its exact milliseconds). Compound strings such as "1h30m"
// are summed, with whitespace allowed between the parts. label names the
// value in the error ("grace", "timeout"); "" is "duration". The errors
// are the SDK's, word for word.
func ParseDuration(value any, label string) (float64, error) {
	if label == "" {
		label = "duration"
	}
	negative := errors.New(label + " must be a non-negative number of milliseconds")
	var n float64
	switch v := value.(type) {
	case string:
		return parseText(v, label)
	case time.Duration:
		n = float64(v) / 1e6
	case float64:
		n = v
	case float32:
		n = float64(v)
	case int:
		n = float64(v)
	case int64:
		n = float64(v)
	case int32:
		n = float64(v)
	default:
		return 0, notADuration(label, fmt.Sprint(value))
	}
	if math.IsNaN(n) || math.IsInf(n, 0) || n < 0 {
		return 0, negative
	}
	return n, nil
}

func notADuration(label, value string) error {
	return fmt.Errorf("%s \"%s\" is not a duration like \"15m\", \"1h30m\", or \"90s\"", label, value)
}

// parseText reads a duration string as duration.ts does: the text trimmed
// and lowercased, every /(\d+(?:\.\d+)?)\s*(ms|s|m|h|d|w)/g match summed,
// and the whole refused unless the matches, spaces aside, are all of it.
func parseText(value, label string) (float64, error) {
	if len(value) > maxLength {
		if err := tooLong(value, label); err != nil {
			return 0, err
		}
	}
	text := strings.ToLower(js.Trim(value))
	if text == "" {
		return 0, errors.New(label + " is empty")
	}
	total := 0.0
	var consumed strings.Builder
	for i := 0; i < len(text); {
		n, end, ok := match(text, i)
		if !ok {
			// The global regular expression moves on one character.
			_, size := firstRune(text[i:])
			i += size
			continue
		}
		total += n
		consumed.WriteString(text[i:end])
		i = end
	}
	if stripSpaces(consumed.String()) != stripSpaces(text) {
		return 0, notADuration(label, value)
	}
	return round(total), nil
}

// maxLength is the longest duration string read, in characters (code
// points). No real duration comes near it, and the scan below is quadratic
// on a long run of digits, as the SDK's pattern is, so a longer string is
// refused before it is read. quoted is how much of it the error quotes.
const (
	maxLength = 64
	quoted    = 32
)

// tooLong is the error for value when it is over maxLength characters.
func tooLong(value, label string) error {
	count, head := 0, 0
	for i := range value {
		if count == quoted {
			head = i
		}
		count++
		if count > maxLength {
			return fmt.Errorf("%s \"%s...\" is too long for a duration (more than %d characters)", label, value[:head], maxLength)
		}
	}
	return nil
}

func firstRune(s string) (rune, int) {
	for _, r := range s {
		return r, len(string(r))
	}
	return 0, 1
}

// match tries (\d+(?:\.\d+)?)\s*(ms|s|m|h|d|w) at i: the value in
// milliseconds and where the match ends.
func match(text string, i int) (float64, int, bool) {
	j := i
	for j < len(text) && text[j] >= '0' && text[j] <= '9' {
		j++
	}
	if j == i {
		return 0, 0, false
	}
	end := j
	if j+1 < len(text) && text[j] == '.' && text[j+1] >= '0' && text[j+1] <= '9' {
		end = j + 1
		for end < len(text) && text[end] >= '0' && text[end] <= '9' {
			end++
		}
	}
	number := text[i:end]
	k := end
	for k < len(text) {
		r, size := firstRune(text[k:])
		if !js.IsSpace(r) {
			break
		}
		k += size
	}
	var unit string
	switch {
	case strings.HasPrefix(text[k:], "ms"):
		unit = "ms"
	case k < len(text) && strings.ContainsRune("smhdw", rune(text[k])):
		unit = text[k : k+1]
	default:
		return 0, 0, false
	}
	f, _ := strconv.ParseFloat(number, 64)
	return f * unitMs[unit], k + len(unit), true
}

func stripSpaces(s string) string {
	return strings.Map(func(r rune) rune {
		if js.IsSpace(r) {
			return -1
		}
		return r
	}, s)
}

// FormatDuration is the SDK's formatDuration: 90000 is "1m 30s", at most
// two units, for messages rather than parsing back. "?" when not finite.
func FormatDuration(ms float64) string {
	if math.IsNaN(ms) || math.IsInf(ms, 0) {
		return "?"
	}
	if ms < 1000 {
		return js.FormatNumber(round(ms)) + "ms"
	}
	var parts []string
	rest := round(ms / 1000)
	for _, u := range []struct {
		unit string
		size float64
	}{{"d", 86_400}, {"h", 3_600}, {"m", 60}, {"s", 1}} {
		if rest >= u.size {
			n := math.Floor(rest / u.size)
			rest -= n * u.size
			parts = append(parts, js.FormatNumber(n)+u.unit)
		}
		if len(parts) == 2 {
			break
		}
	}
	if len(parts) == 0 {
		return "0s"
	}
	return strings.Join(parts, " ")
}

// FormatRelative is the SDK's formatRelative: "5m ago", "in 2h", or "now"
// within five seconds of now.
func FormatRelative(at, now int64) string {
	diff := at - now
	abs := diff
	if abs < 0 {
		abs = -abs
	}
	if abs < 5_000 {
		return "now"
	}
	text := FormatDuration(float64(abs))
	if diff < 0 {
		return text + " ago"
	}
	return "in " + text
}
