package cronwatch

// Alert titles and messages (format.ts), character for character, and the
// numbers in them as JavaScript's toLocaleString("en-US") writes them.

import (
	"math"
	"math/big"
	"regexp"
	"strconv"
	"strings"

	"cronwatch.dev/go/internal/js"
	"cronwatch.dev/go/internal/schedule"
)

// formatNumber is evaluate.ts formatNumber: a whole number grouped in
// thousands ("1,234"), anything else rounded to at most four decimals
// ("0.0123"), as Intl.NumberFormat("en-US") writes them. ICU starts from
// the shortest decimal digits that read back as the number (as String(n)
// has them, so 1234.56785 is those digits, not the binary value just
// below), rounds half away from zero (0.03125 is "0.0313"), and keeps the
// sign of a negative number that rounds to zero ("-0").
func formatNumber(n float64) string {
	switch {
	case math.IsNaN(n):
		return "NaN"
	case math.IsInf(n, 1):
		return "∞"
	case math.IsInf(n, -1):
		return "-∞"
	}
	sign := ""
	if math.Signbit(n) {
		sign = "-"
	}
	// The shortest digits d1...dk, with the value 0.d1...dk * 10^point.
	mantissa, exp, _ := strings.Cut(strconv.FormatFloat(math.Abs(n), 'e', -1, 64), "e")
	digits := strings.Replace(mantissa, ".", "", 1)
	e, _ := strconv.Atoi(exp)
	point := e + 1
	if digits == "0" {
		point = 1
	}
	// Written out in full: whole digits and fraction digits.
	var whole, frac string
	switch {
	case point <= 0:
		whole, frac = "0", strings.Repeat("0", -point)+digits
	case point >= len(digits):
		whole = digits + strings.Repeat("0", point-len(digits))
	default:
		whole, frac = digits[:point], digits[point:]
	}
	if len(frac) > 4 {
		kept := new(big.Int)
		kept.SetString(whole+frac[:4], 10)
		if frac[4] >= '5' {
			kept.Add(kept, big.NewInt(1))
		}
		s := kept.String()
		for len(s) < 5 {
			s = "0" + s
		}
		whole, frac = s[:len(s)-4], s[len(s)-4:]
	}
	frac = strings.TrimRight(frac, "0")
	out := sign + group(whole)
	if frac != "" {
		out += "." + frac
	}
	return out
}

// group puts a comma between each three digits, from the right.
func group(digits string) string {
	if len(digits) <= 3 {
		return digits
	}
	var b strings.Builder
	head := len(digits) % 3
	if head > 0 {
		b.WriteString(digits[:head])
	}
	for i := head; i < len(digits); i += 3 {
		if b.Len() > 0 {
			b.WriteByte(',')
		}
		b.WriteString(digits[i : i+3])
	}
	return b.String()
}

// when is "2026-01-05 09:30:00 UTC (5m ago)", or "never". A time before the
// year 1 or after 9999 is words, with no relative part.
func when(at *float64, now int64) string {
	if at == nil {
		return "never"
	}
	if !(*at >= float64(js.FirstDateMs) && *at <= float64(js.LastDateMs)) {
		if *at > float64(js.LastDateMs) {
			return js.BeyondDates(js.LastDateMs + 1)
		}
		return js.BeyondDates(js.FirstDateMs - 1)
	}
	iso := js.ISOString(int64(math.Trunc(*at)))
	return strings.Replace(iso, "T", " ", 1)[:19] + " UTC (" + relative(*at, now) + ")"
}

func whenInt(at *int64, now int64) string {
	if at == nil {
		return "never"
	}
	f := float64(*at)
	return when(&f, now)
}

// relative is formatRelative for a time that may carry a fraction of a
// millisecond (a deadline with a fractional grace).
func relative(at float64, now int64) string {
	diff := at - float64(now)
	abs := math.Abs(diff)
	if abs < 5_000 {
		return "now"
	}
	text := schedule.FormatDuration(abs)
	if diff < 0 {
		return text + " ago"
	}
	return "in " + text
}

func firstLines(text string, n int) string {
	if text == "" {
		return ""
	}
	lines := strings.Split(text, "\n")
	if len(lines) > n {
		lines = lines[:n]
	}
	return strings.Join(lines, "\n")
}

func tail(text *string, n int) string {
	if text == nil || *text == "" {
		return ""
	}
	lines := strings.Split(js.TrimEnd(*text), "\n")
	if len(lines) > n {
		lines = lines[len(lines)-n:]
	}
	return strings.Join(lines, "\n")
}

var namedError = regexp.MustCompile(`^[A-Za-z_$][\w$]*: `)

// errorLine is "Error: x" for a bare message, but not "Error: TypeError: x"
// for one that already names itself.
func errorLine(err string) string {
	text := firstLines(err, 4)
	if namedError.MatchString(text) {
		return text
	}
	return "Error: " + text
}

// jsText is a JSON value as a JavaScript template literal writes it, and
// "undefined" for a field that is absent.
func jsText(v any, present bool) string {
	if !present {
		return "undefined"
	}
	switch t := v.(type) {
	case nil:
		return "null"
	case string:
		return t
	case bool:
		if t {
			return "true"
		}
		return "false"
	case float64:
		return js.FormatNumber(t)
	case []any:
		parts := make([]string, len(t))
		for i, e := range t {
			if e != nil {
				parts[i] = jsText(e, true)
			}
		}
		return strings.Join(parts, ",")
	}
	return "[object Object]"
}

func (d Definition) text(key string) string {
	v, ok := d.get(key)
	return jsText(v, ok)
}

// composeAlert turns a draft into the title and message every channel shows.
func composeAlert(draft alertDraft, def Definition, now int64) Alert {
	name := def.text("name")
	run := draft.Run
	var title string
	var lines []string

	switch draft.Type {
	case AlertMissed:
		d := draft.Details.(MissedDetails)
		title = name + " missed its scheduled run"
		due := float64(d.DueAt)
		lines = append(lines, "Due "+when(&due, now)+", and no run had started by "+when(&d.Deadline, now)+" (grace "+schedule.FormatDuration(d.GraceMs)+").")
		zone := ""
		if tz, ok := def.get("timezone"); ok && truthy(tz) {
			zone = " (" + jsText(tz, true) + ")"
		}
		lines = append(lines, "Schedule: "+def.text("schedule")+zone+".")
		last := "never"
		if run != nil {
			last = string(run.Status) + " " + whenInt(&run.StartedAt, now)
		}
		lines = append(lines, "Last run: "+last+".")
	case AlertFailed:
		title = name + " failed"
		if n := draft.Details.(FailureDetails).ConsecutiveFailures; n > 1 {
			lines = append(lines, js.FormatNumber(float64(n))+" consecutive failures.")
		}
		if run != nil {
			ran := ""
			if run.DurationMs != nil {
				ran = ", ran " + schedule.FormatDuration(float64(*run.DurationMs))
			}
			lines = append(lines, "Started "+whenInt(&run.StartedAt, now)+ran+".")
			if run.Error != nil && *run.Error != "" {
				lines = append(lines, errorLine(*run.Error))
			}
			if out := tail(run.Output, 8); out != "" {
				lines = append(lines, "Output (tail):\n"+out)
			}
		}
	case AlertStuck:
		title = name + " is stuck"
		if run != nil {
			ran := elapsedMs(run.StartedAt, now)
			if run.DurationMs != nil {
				ran = float64(*run.DurationMs)
			}
			lines = append(lines, "Started "+whenInt(&run.StartedAt, now)+" and never reported finishing. Marked as timed out after "+schedule.FormatDuration(ran)+".")
			if out := tail(run.Output, 8); out != "" {
				lines = append(lines, "Output so far (tail):\n"+out)
			}
		}
		lines = append(lines, "If the process was killed mid-run (a serverless timeout, a deploy), this is what that looks like.")
	case AlertSlow:
		d := draft.Details.(SlowDetails)
		title = name + " was slow"
		lines = append(lines, "Took "+schedule.FormatDuration(float64(d.DurationMs))+"; the limit is "+schedule.FormatDuration(d.ThresholdMs)+" ("+d.Basis+").")
		if run != nil {
			lines = append(lines, "Started "+whenInt(&run.StartedAt, now)+".")
		}
	case AlertOverBudget:
		title = name + " went over budget"
		for _, b := range draft.Details.(OverBudgetDetails).Breaches {
			lines = append(lines, b.Metric+": "+formatNumber(b.Value)+", limit "+formatNumber(b.Limit)+" ("+b.Basis+").")
		}
		if run != nil {
			lines = append(lines, "Started "+whenInt(&run.StartedAt, now)+".")
		}
	case AlertRecovered:
		d := draft.Details.(RecoveredDetails)
		if d.Reason == "unscheduled" {
			title = name + " is no longer scheduled"
			missed := ""
			if d.Since != nil {
				missed = "Missed since " + whenInt(d.Since, now) + ". "
			}
			lines = append(lines, missed+"It has no schedule now, so nothing is due; the missed alert is closed.")
			break
		}
		title = name + " recovered"
		names := make([]string, len(d.After))
		for i, c := range d.After {
			names[i] = strings.Replace(string(c), "_", " ", 1)
		}
		after := strings.Join(names, ", ")
		at := "just now"
		if run != nil {
			at = whenInt(&run.StartedAt, now)
		}
		line := "A run " + at + " succeeded"
		if after != "" {
			line += " after: " + after
		}
		lines = append(lines, line+".")
		if run != nil && run.DurationMs != nil {
			lines = append(lines, "Ran "+schedule.FormatDuration(float64(*run.DurationMs))+".")
		}
	}

	return Alert{
		Type:       draft.Type,
		Run:        cloneRun(run),
		Details:    draft.Details,
		Job:        name,
		Definition: def,
		Title:      title,
		Message:    strings.Join(lines, "\n"),
		At:         now,
	}
}
