// Package cron is a port of croner 10, the cron library the SDK uses: its
// reading of an expression (CronPattern, with its checks and its messages
// word for word) and its walk to the next matching time (CronDate),
// habits included: a day the month does not have rolls over, a wall-clock
// time in a spring-forward gap moves forward by the gap, and a time that
// happens twice is the earlier one. The names and the order of every step
// follow croner's source, as the Python port's _cron.py and the PHP port's
// src/Cron do, so the four agree on every expression they read, every one
// they refuse and every fire time.
//
// Where it cannot match croner:
//
//   - A date no month has (0 0 30 2 *) makes croner, which walks by
//     recursion a year at a time, run out of stack before the year 3000.
//     This port walks in a loop and answers that the expression never
//     fires.
//   - Croner reads a string with a colon after its first character as a
//     one-time date, through JavaScript's lenient Date.parse. This port
//     refuses every such string: one that looks like an ISO date with
//     "CronPattern: a one-time date is not supported by the Go port",
//     anything else with the message croner gives for text Date.parse
//     cannot read, "Invalid ISO8601 passed to timezone parser.".
package cron

import (
	"fmt"
	"math"
	"strconv"
	"strings"

	"cronwatch.dev/go/internal/js"
)

// Error is what croner throws for an expression it will not read, with its
// message.
type Error struct{ msg string }

func (e *Error) Error() string { return e.msg }

func fail(format string, args ...any) error {
	return &Error{fmt.Sprintf(format, args...)}
}

// Croner's bits for "the nth weekday of the month"; 32 is the last one, 63 any.
var nthBits = [5]int{1, 2, 4, 8, 16}

const (
	lastBit = 32
	anyBits = 63
)

var (
	monthNames = []string{"jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"}
	dayNames   = []string{"sun", "mon", "tue", "wed", "thu", "fri", "sat"}
)

// The fields of a pattern, by croner's names.
type kind int

const (
	kSecond kind = iota
	kMinute
	kHour
	kDay
	kMonth
	kDayOfWeek
	kYear
	kNearestWeekdays
)

var kindNames = map[kind]string{
	kSecond: "second", kMinute: "minute", kHour: "hour", kDay: "day", kMonth: "month",
	kDayOfWeek: "dayOfWeek", kYear: "year", kNearestWeekdays: "nearestWeekdays",
}

// How many entries each field's table has, as croner sizes them.
var sizes = map[kind]int{
	kSecond: 60, kMinute: 60, kHour: 24, kDay: 31, kMonth: 12, kDayOfWeek: 7, kYear: 10_000, kNearestWeekdays: 31,
}

// value is what a field's table is set to: 1 (a match), croner's 63 for any
// nth weekday, or the text of a day-of-week modifier ("2" of "1#2", "L").
type value struct {
	n     int
	s     string
	isStr bool
}

// Pattern is croner's CronPattern: the fields of an expression as tables
// of what matches.
type Pattern struct {
	pattern         string
	second          [60]int
	minute          [60]int
	hour            [24]int
	day             [31]int
	month           [12]int
	dayOfWeek       [7]int
	nearestWeekdays [31]int
	// The years that match: every one ("*"), or the table croner keeps,
	// made only when the field names years.
	everyYear bool
	years     []bool

	lastDayOfMonth bool
	lastWeekday    bool
	starDOM        bool
	starDOW        bool
	starYear       bool
	useAndLogic    bool
}

func (p *Pattern) table(k kind) []int {
	switch k {
	case kSecond:
		return p.second[:]
	case kMinute:
		return p.minute[:]
	case kHour:
		return p.hour[:]
	case kDay:
		return p.day[:]
	case kMonth:
		return p.month[:]
	case kDayOfWeek:
		return p.dayOfWeek[:]
	case kNearestWeekdays:
		return p.nearestWeekdays[:]
	}
	return nil
}

// hasYear is croner's year[y]: whether year y matches (0 outside the table).
func (p *Pattern) hasYear(y int64) bool {
	if y < 0 || y >= 10_000 {
		return false
	}
	return p.everyYear || (p.years != nil && p.years[y])
}

// NewPattern reads an expression as croner's CronPattern does.
func NewPattern(text string) (*Pattern, error) {
	p := &Pattern{pattern: text}
	if err := p.parse(); err != nil {
		return nil, err
	}
	return p, nil
}

// parseInt is parseInt(text, 10): NaN when no digits lead.
func parseInt(text string) float64 {
	s := strings.TrimLeftFunc(text, js.IsSpace)
	i := 0
	if i < len(s) && (s[i] == '+' || s[i] == '-') {
		i++
	}
	j := i
	for j < len(s) && s[j] >= '0' && s[j] <= '9' {
		j++
	}
	if j == i {
		return math.NaN()
	}
	f, _ := strconv.ParseFloat(s[:j], 64)
	return f
}

// toNumber is JavaScript's Number(text) for the characters a field may
// hold: NaN when it is not a number.
func toNumber(text string) float64 {
	s := js.Trim(text)
	if s == "" {
		return 0
	}
	i := 0
	if s[i] == '+' || s[i] == '-' {
		i++
	}
	digits, dot, frac := 0, false, 0
	for ; i < len(s); i++ {
		switch c := s[i]; {
		case c >= '0' && c <= '9':
			if dot {
				frac++
			} else {
				digits++
			}
		case c == '.' && !dot:
			dot = true
		case (c == 'e' || c == 'E') && digits+frac > 0:
			rest := s[i+1:]
			if rest != "" && (rest[0] == '+' || rest[0] == '-') {
				rest = rest[1:]
			}
			if rest == "" || strings.Trim(rest, "0123456789") != "" {
				return math.NaN()
			}
			i = len(s)
		default:
			return math.NaN()
		}
	}
	if digits+frac == 0 {
		return math.NaN()
	}
	f, err := strconv.ParseFloat(s, 64)
	if err != nil {
		if ne, ok := err.(*strconv.NumError); ok && ne.Err == strconv.ErrRange {
			return f
		}
		return math.NaN()
	}
	return f
}

// replaceFold replaces every occurrence of an ASCII word, matched without
// regard to ASCII case (a JavaScript /gi regular expression).
func replaceFold(text, word, with string) string {
	var b strings.Builder
	for i := 0; i < len(text); {
		if i+len(word) <= len(text) && asciiEqualFold(text[i:i+len(word)], word) {
			b.WriteString(with)
			i += len(word)
			continue
		}
		b.WriteByte(text[i])
		i++
	}
	return b.String()
}

func asciiEqualFold(a, b string) bool {
	for i := 0; i < len(a); i++ {
		x, y := a[i], b[i]
		if 'A' <= x && x <= 'Z' {
			x += 'a' - 'A'
		}
		if 'A' <= y && y <= 'Z' {
			y += 'a' - 'A'
		}
		if x != y {
			return false
		}
	}
	return true
}

func upper(s string) string { return strings.ToUpper(s) }

func (p *Pattern) parse() error {
	if strings.Contains(p.pattern, "@") {
		text, err := nicknames(p.pattern)
		if err != nil {
			return err
		}
		p.pattern = js.Trim(text)
	}
	parts := strings.FieldsFunc(p.pattern, js.IsSpace)
	if len(parts) == 0 {
		parts = []string{""}
	}
	if len(parts) < 5 || len(parts) > 7 {
		return fail("CronPattern: invalid configuration format ('%s'), exactly five, six, or seven space separated parts are required.", p.pattern)
	}
	if len(parts) == 5 {
		parts = append([]string{"0"}, parts...)
	}
	if len(parts) == 6 {
		parts = append(parts, "*")
	}
	if upper(parts[3]) == "LW" {
		p.lastWeekday = true
		parts[3] = ""
	} else if strings.Contains(upper(parts[3]), "L") {
		parts[3] = replaceFold(parts[3], "l", "")
		p.lastDayOfMonth = true
	}
	if parts[3] == "*" {
		p.starDOM = true
	}
	if parts[6] == "*" {
		p.starYear = true
	}
	if js.Length16(parts[4]) >= 3 {
		for i, name := range monthNames {
			parts[4] = replaceFold(parts[4], name, strconv.Itoa(i+1))
		}
	}
	if js.Length16(parts[5]) >= 3 {
		parts[5] = replaceFold(parts[5], "-sun", "-7")
		for i, name := range dayNames {
			parts[5] = replaceFold(parts[5], name, strconv.Itoa(i))
		}
	}
	if strings.HasPrefix(parts[5], "+") {
		p.useAndLogic = true
		parts[5] = parts[5][1:]
		if parts[5] == "" {
			return fail("CronPattern: Day-of-week field cannot be empty after '+' modifier.")
		}
	}
	if parts[5] == "*" {
		p.starDOW = true
	}
	if strings.Contains(p.pattern, "?") {
		for i := range parts {
			parts[i] = strings.ReplaceAll(parts[i], "?", "*")
		}
	}
	if err := illegalCharacters(parts); err != nil {
		return err
	}
	fields := []struct {
		k      kind
		offset float64
		v      value
	}{
		{kSecond, 0, value{n: 1}}, {kMinute, 0, value{n: 1}}, {kHour, 0, value{n: 1}}, {kDay, -1, value{n: 1}},
		{kMonth, -1, value{n: 1}}, {kDayOfWeek, 0, value{n: anyBits}}, {kYear, 0, value{n: 1}},
	}
	for i, f := range fields {
		if err := p.part(f.k, parts[i], f.offset, f.v); err != nil {
			return err
		}
	}
	return nil
}

func nicknames(pattern string) (string, error) {
	switch strings.ToLower(js.Trim(pattern)) {
	case "@yearly", "@annually":
		return "0 0 1 1 *", nil
	case "@monthly":
		return "0 0 1 * *", nil
	case "@weekly":
		return "0 0 * * 0", nil
	case "@daily", "@midnight":
		return "0 0 * * *", nil
	case "@hourly":
		return "0 * * * *", nil
	case "@reboot":
		return "", fail("CronPattern: @reboot is not supported in this environment. This is an event-based trigger that requires system startup detection.")
	}
	return pattern, nil
}

// illegalCharacters is croner's check of each field's characters: digits,
// "/*,-" everywhere, W and L in the day of the month, # and L in the day
// of the week.
func illegalCharacters(parts []string) error {
	for i, part := range parts {
		allowed := "/*0123456789,-"
		switch i {
		case 3:
			allowed += "WwLl"
		case 5:
			allowed += "#Ll"
		}
		for _, r := range part {
			if !strings.ContainsRune(allowed, r) {
				return fail("CronPattern: configuration entry %d (%s) contains illegal characters.", i, part)
			}
		}
	}
	return nil
}

func (p *Pattern) part(k kind, text string, offset float64, v value) error {
	lastDom := k == kDay && p.lastDayOfMonth
	lastWd := k == kDay && p.lastWeekday
	if text == "" && !lastDom && !lastWd {
		return fail("CronPattern: configuration entry %s (%s) is empty, check for trailing spaces.", kindNames[k], text)
	}
	if text == "*" {
		if k == kYear {
			p.everyYear = true
			return nil
		}
		t := p.table(k)
		for i := range t {
			t[i] = v.n
		}
		return nil
	}
	items := strings.Split(text, ",")
	switch {
	case len(items) > 1:
		for _, item := range items {
			if err := p.part(k, item, offset, v); err != nil {
				return err
			}
		}
	case strings.Contains(text, "-") && strings.Contains(text, "/"):
		return p.rangeWithStepping(text, k, offset, v)
	case strings.Contains(text, "-"):
		return p.rangeOf(text, k, offset, v)
	case strings.Contains(text, "/"):
		return p.stepping(text, k, v)
	case text != "":
		return p.number(text, k, offset, v)
	}
	return nil
}

// modifierOr is croner's `nth[1] || value`: the modifier when there is one,
// else the field's value.
func modifierOr(nth string, has bool, v value) value {
	if has && nth != "" {
		return value{s: nth, isStr: true}
	}
	return v
}

func (p *Pattern) number(text string, k kind, offset float64, v value) error {
	base, nth, has, err := extractNth(text, k)
	if err != nil {
		return err
	}
	nearest := strings.Contains(upper(text), "W")
	if k != kDay && nearest {
		return fail("CronPattern: Nearest weekday modifier (W) only allowed in day-of-month.")
	}
	if nearest {
		k = kNearestWeekdays
	}
	n := parseInt(base)
	if math.IsNaN(n) {
		return fail("CronPattern: %s is not a number: '%s'", kindNames[k], text)
	}
	return p.set(k, n+offset, modifierOr(nth, has, v))
}

func (p *Pattern) set(k kind, at float64, v value) error {
	if k == kDayOfWeek {
		if at == 7 {
			at = 0
		}
		if at < 0 || at > 6 {
			return fail("CronPattern: Invalid value for dayOfWeek: %s", js.FormatNumber(at))
		}
		return p.nthWeekday(int(at), v)
	}
	if k == kYear {
		if at < 1 || at >= 10_000 {
			return fail("CronPattern: Invalid value for %s: %s (supported range: 1-9999)", kindNames[k], js.FormatNumber(at))
		}
		if p.years == nil {
			p.years = make([]bool, 10_000)
		}
		p.years[int(at)] = v.n != 0 || v.isStr
		return nil
	}
	if at < 0 || at >= float64(sizes[k]) {
		return fail("CronPattern: Invalid value for %s: %s", kindNames[k], js.FormatNumber(at))
	}
	p.table(k)[int(at)] = v.n
	return nil
}

func validateRange(low, high float64, step *float64, size int, text string) error {
	if low > high {
		return fail("CronPattern: From value is larger than to value: '%s'", text)
	}
	if step != nil {
		if *step == 0 {
			return fail("CronPattern: Syntax error, illegal stepping: 0")
		}
		if *step > float64(size) {
			return fail("CronPattern: Syntax error, steps cannot be greater than maximum value of part (%d)", size)
		}
	}
	return nil
}

// digitsOnly reports whether s is one or more ASCII digits.
func digitsOnly(s string) bool {
	if s == "" {
		return false
	}
	for i := 0; i < len(s); i++ {
		if s[i] < '0' || s[i] > '9' {
			return false
		}
	}
	return true
}

func (p *Pattern) rangeWithStepping(text string, k kind, offset float64, v value) error {
	if strings.Contains(upper(text), "W") {
		return fail("CronPattern: Syntax error, W is not allowed in ranges with stepping.")
	}
	base, nth, has, err := extractNth(text, k)
	if err != nil {
		return err
	}
	// /^(\d+)-(\d+)\/(\d+)$/
	rng, stepText, ok1 := strings.Cut(base, "/")
	lowText, highText, ok2 := strings.Cut(rng, "-")
	if !ok1 || !ok2 || !digitsOnly(lowText) || !digitsOnly(highText) || !digitsOnly(stepText) {
		return fail("CronPattern: Syntax error, illegal range with stepping: '%s'", text)
	}
	low, _ := strconv.ParseFloat(lowText, 64)
	high, _ := strconv.ParseFloat(highText, 64)
	step, _ := strconv.ParseFloat(stepText, 64)
	low += offset
	high += offset
	if err := validateRange(low, high, &step, sizes[k], text); err != nil {
		return err
	}
	for at := low; at <= high; at += step {
		if err := p.set(k, at, modifierOr(nth, has, v)); err != nil {
			return err
		}
	}
	return nil
}

// extractNth splits a day-of-week modifier off: "1#2" is 1 and "2", "5L"
// is 5 and "L". Anywhere else a modifier is an error.
func extractNth(text string, k kind) (string, string, bool, error) {
	if strings.Contains(text, "#") {
		if k != kDayOfWeek {
			return "", "", false, fail("CronPattern: nth (#) only allowed in day-of-week field")
		}
		pieces := strings.Split(text, "#")
		return pieces[0], pieces[1], true, nil
	}
	if strings.HasSuffix(upper(text), "L") {
		if k != kDayOfWeek {
			return "", "", false, fail("CronPattern: L modifier only allowed in day-of-week field (use L alone for day-of-month)")
		}
		return text[:len(text)-1], "L", true, nil
	}
	return text, "", false, nil
}

func (p *Pattern) rangeOf(text string, k kind, offset float64, v value) error {
	if strings.Contains(upper(text), "W") {
		return fail("CronPattern: Syntax error, W is not allowed in a range.")
	}
	base, nth, has, err := extractNth(text, k)
	if err != nil {
		return err
	}
	bounds := strings.Split(base, "-")
	if len(bounds) != 2 {
		return fail("CronPattern: Syntax error, illegal range: '%s'", text)
	}
	low, high := parseInt(bounds[0]), parseInt(bounds[1])
	if math.IsNaN(low) {
		return fail("CronPattern: Syntax error, illegal lower range (NaN)")
	}
	if math.IsNaN(high) {
		return fail("CronPattern: Syntax error, illegal upper range (NaN)")
	}
	low += offset
	high += offset
	if err := validateRange(low, high, nil, sizes[k], text); err != nil {
		return err
	}
	for at := low; at <= high; at++ {
		if err := p.set(k, at, modifierOr(nth, has, v)); err != nil {
			return err
		}
	}
	return nil
}

func (p *Pattern) stepping(text string, k kind, v value) error {
	if strings.Contains(upper(text), "W") {
		return fail("CronPattern: Syntax error, W is not allowed in parts with stepping.")
	}
	base, nth, has, err := extractNth(text, k)
	if err != nil {
		return err
	}
	parts := strings.Split(base, "/")
	if len(parts) != 2 {
		return fail("CronPattern: Syntax error, illegal stepping: '%s'", text)
	}
	if parts[0] == "" {
		return fail("CronPattern: Syntax error, stepping with missing prefix ('%s') is not allowed. Use wildcard (*/step) or range (min-max/step) instead.", text)
	}
	if parts[0] != "*" {
		return fail("CronPattern: Syntax error, stepping with numeric prefix ('%s') is not allowed. Use wildcard (*/step) or range (min-max/step) instead.", text)
	}
	step := parseInt(parts[1])
	if math.IsNaN(step) {
		return fail("CronPattern: Syntax error, illegal stepping: (NaN)")
	}
	size := sizes[k]
	if err := validateRange(0, float64(size-1), &step, size, text); err != nil {
		return err
	}
	if step > 0 {
		for at := 0.0; at < float64(size); at += step {
			if err := p.set(k, at, modifierOr(nth, has, v)); err != nil {
				return err
			}
		}
	}
	return nil
}

func (p *Pattern) nthWeekday(day int, nth value) error {
	if nth.isStr && upper(nth.s) == "L" {
		p.dayOfWeek[day] |= lastBit
		return nil
	}
	if !nth.isStr && nth.n == anyBits {
		p.dayOfWeek[day] = anyBits
		return nil
	}
	n := float64(nth.n)
	if nth.isStr {
		n = toNumber(nth.s)
	}
	if n < 6 && n > 0 {
		index := n - 1
		if index == math.Floor(index) && index >= 0 && int(index) < len(nthBits) {
			p.dayOfWeek[day] |= nthBits[int(index)]
		}
		return nil
	}
	if nth.isStr {
		return fail("CronPattern: nth weekday out of range, should be 1-5 or L. Value: %s, Type: string", nth.s)
	}
	return fail("CronPattern: nth weekday out of range, should be 1-5 or L. Value: %s, Type: number", js.FormatNumber(n))
}
