package cronwatch

// The dashboard's timelines (routes/timeline.ts), markup for markup: one
// lane per job (or per day, on a job's page), drawn on the server as inline
// SVG so the page needs no script.
//
// Every time a job was due is a faint tick, worked out from its schedule
// with the same functions the checks use, so the lane shows the cadence the
// job is meant to keep. Every run it recorded is a solid mark on top, as
// wide as it took and coloured by how it ended. A slot the check has
// reported missed is a dashed box. The empty part of a lane carries a short
// note about anything open, and a visually hidden list says the same things
// in words. Every time is UTC: without script the page cannot know the
// viewer's zone.

import (
	"math"
	"slices"
	"strings"

	"cronwatch.dev/go/internal/js"
	"cronwatch.dev/go/internal/schedule"
)

const (
	hourMs = 3_600_000
	dayMs  = 24 * hourMs
	// The board's span: the last day, plus a few hours ahead so what is due soon shows.
	boardBehindMs = dayMs
	boardAheadMs  = 3 * hourMs
	// How many jobs the board's timeline draws. The table below it lists every job.
	boardLanes = 30
	// Runs read for a lane when the twenty the table reads start inside the
	// span, so a frequent job's lane is not cut short. Older runs than this
	// are shown as not loaded rather than as absent.
	boardRuns = 200
	// How many days a job's page draws.
	weekDays = 7
	// Width of a lane in SVG units. Lanes stretch to fit, so strokes do not scale.
	laneWidth = 1000.0
	// A lane with more due times than this shows its cadence as a dotted line instead.
	maxTicks = 330
	// More missed slots than this are drawn as one dashed band.
	maxBoxes = 8
	// The narrowest a missed box is drawn, in SVG units.
	minBox = 10.0
)

var (
	monthNames   = [...]string{"Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"}
	weekdayNames = [...]string{"Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"}
)

// clockUTC is "22:42", in UTC.
func clockUTC(t int64) string { return js.ISOString(t)[11:16] }

// civil is the UTC date of t: its year, month (1 to 12), day and weekday
// (0 for Sunday).
func civil(t int64) (month, day, weekday int) {
	days := js.FloorDiv(t, dayMs)
	_, m, d := js.CivilFromDays(days)
	return int(m), int(d), int(js.Mod(days+4, 7))
}

// dayLabel is "Sat 26 Sep", in UTC.
func dayLabel(t int64) string {
	m, d, wd := civil(t)
	return weekdayNames[wd] + " " + num(d) + " " + monthNames[m-1]
}

// whenUTC is "22:42" on the same UTC day as now, otherwise "25 Sep 22:42".
// A time before the year 1 or after 9999 (a start read from a foreign or
// damaged row) is "before 1 Jan 0001 00:00" or "after 31 Dec 9999 23:59".
func whenUTC(t, now int64) string {
	if t > js.LastDateMs {
		return "after 31 Dec 9999 23:59"
	}
	if t < js.FirstDateMs {
		return "before 1 Jan 0001 00:00"
	}
	if js.FloorDiv(t, dayMs) == js.FloorDiv(now, dayMs) {
		return clockUTC(t)
	}
	m, d, _ := civil(t)
	return num(d) + " " + monthNames[m-1] + " " + clockUTC(t)
}

// span is the stretch of time a timeline draws, and the moment it was drawn.
type span struct{ from, to, now int64 }

// laneSchedule is the job's schedule, parsed, or nil when it has none or it
// no longer parses.
func laneSchedule(job JobSummary) *schedule.Parsed {
	v, _ := job.Definition.get("schedule")
	if !truthy(v) {
		return nil
	}
	parsed, err := parsedSchedule(job.Definition)
	if err != nil {
		return nil
	}
	return parsed
}

// dueTimes is when the job was due within from to to, ascending, or dense
// when there are too many to draw one by one. A cron's fires come from its
// schedule. An interval is due one period after each run started, and
// after the last run once a period for as long as nothing runs; with no run
// yet, from its next expected time.
func dueTimes(job JobSummary, parsed *schedule.Parsed, runs []Run, from, to int64) (times []int64, dense bool) {
	if parsed == nil {
		return nil, false
	}
	if parsed.Kind == "interval" {
		every := parsed.EveryMs
		if every <= 0 {
			return nil, false
		}
		if float64(to-from)/float64(every) > maxTicks {
			return nil, true
		}
		starts := make([]int64, len(runs))
		for i, r := range runs {
			starts[i] = r.StartedAt
		}
		slices.Sort(starts)
		set := map[int64]bool{}
		for _, start := range starts {
			if t := start + every; t >= from && t <= to {
				set[t] = true
			}
		}
		var next *int64
		if len(starts) > 0 {
			next = ptr(starts[len(starts)-1] + every)
		} else if job.NextExpectedAt != nil {
			next = ptr(*job.NextExpectedAt)
		}
		if next != nil {
			t := *next
			if t < from {
				t += int64(math.Ceil(float64(from-t)/float64(every))) * every
			}
			for ; t <= to; t += every {
				set[t] = true
			}
		}
		times = make([]int64, 0, len(set))
		for t := range set {
			times = append(times, t)
		}
		slices.Sort(times)
		return times, false
	}
	fires, ok := schedule.FiresBetween(parsed, from-1, to, maxTicks)
	if !ok {
		return nil, true
	}
	return fires, false
}

// missedAt is the slot a missed job was due at, the one the check reported:
// the first fire its last run does not cover. A job that never ran has no
// run to count from, so the latest due time whose grace has passed stands
// in. Nil when missed is not open.
func missedAt(job JobSummary, parsed *schedule.Parsed, times []int64, now int64) *int64 {
	if parsed == nil || !hasCondition(job.Open, ConditionMissed) {
		return nil
	}
	grace, err := graceMs(job.Definition)
	if err != nil {
		grace = 0
	}
	if job.LastRun != nil {
		last := job.LastRun.StartedAt
		exp, ok := schedule.Expect(parsed, &last, last, grace)
		if !ok {
			return nil
		}
		return &exp.DueAt
	}
	var found *int64
	for _, t := range times {
		if float64(t)+grace < float64(now) {
			found = ptr(t)
		}
	}
	return found
}

func toneOf(run Run, job JobSummary, now int64) string {
	switch run.Status {
	case StatusRunning:
		if stuck, err := isStuck(job.Definition, run, now); err == nil && stuck {
			return "stuck"
		}
		return "running"
	case StatusFailed:
		return "bad"
	case StatusTimeout:
		return "timeout"
	}
	latest := job.LastRun != nil && job.LastRun.ID == run.ID
	if latest && (hasCondition(job.Open, ConditionOverBudget) || hasCondition(job.Open, ConditionSlow)) {
		return "warn"
	}
	return "ok"
}

func timeoutText(job JobSummary) string {
	ms, err := timeoutMs(job.Definition)
	if err != nil {
		return "configured"
	}
	return schedule.FormatDuration(ms)
}

// describeRun is one run, as its tooltip says it.
func describeRun(run Run, tone string, job JobSummary, now int64) string {
	at := whenUTC(run.StartedAt, now) + " UTC"
	switch tone {
	case "running":
		return "running since " + at + ", " + schedule.FormatDuration(elapsedMs(run.StartedAt, now)) + " so far"
	case "stuck":
		return "running since " + at + ", past its " + timeoutText(job) + " timeout"
	}
	took := ""
	if run.DurationMs != nil {
		took = ", took " + schedule.FormatDuration(float64(*run.DurationMs))
	}
	extra := ""
	if tone == "warn" {
		extra = ", slow"
		if hasCondition(job.Open, ConditionOverBudget) {
			extra = ", over budget"
		}
	}
	return string(run.Status) + " at " + at + took + extra
}

// overCeilings are the metrics of the job's last run that went over their ceilings.
func overCeilings(job JobSummary) []string {
	budget, _ := get(job.Definition.o, "budget").(*js.Object)
	var over []string
	for _, k := range budget.Keys() {
		limit, _ := budget.Get(k)
		value := math.Inf(-1)
		if job.LastRun != nil {
			if v, ok := job.LastRun.Metrics.Get(k); ok {
				value = v
			}
		}
		if value > jsNumber(limit) {
			over = append(over, k)
		}
	}
	return over
}

// laneNote is what is worth saying about the job in a few words, or ""
// when all is well.
func laneNote(job JobSummary, missed *int64, now int64) string {
	last := job.LastRun
	switch {
	case job.SilencedUntil != nil && *job.SilencedUntil > now:
		return "silenced until " + whenUTC(*job.SilencedUntil, now)
	case hasCondition(job.Open, ConditionMissed):
		if missed != nil {
			return "due " + whenUTC(*missed, now) + ", nothing ran"
		}
		return "overdue, nothing ran"
	case last != nil && last.Status == StatusRunning:
		if stuck, err := isStuck(job.Definition, *last, now); err == nil && stuck {
			return "running since " + whenUTC(last.StartedAt, now) + ", past its " + timeoutText(job) + " timeout"
		}
		return "running since " + whenUTC(last.StartedAt, now)
	case last != nil && last.Status == StatusFailed:
		text := "failed at " + whenUTC(last.StartedAt, now)
		if job.ConsecutiveFailures > 1 {
			text += ", " + num(job.ConsecutiveFailures) + " in a row"
		}
		return text
	case last != nil && last.Status == StatusTimeout:
		return "timed out at " + whenUTC(last.StartedAt, now)
	case hasCondition(job.Open, ConditionStuck):
		return "stuck"
	}
	if hasCondition(job.Open, ConditionOverBudget) && last != nil {
		text := "went over budget"
		if over := overCeilings(job); len(over) > 0 {
			text += " on " + strings.Join(over, " and ")
		}
		return text + " at " + whenUTC(last.StartedAt, now)
	}
	if hasCondition(job.Open, ConditionSlow) && last != nil && last.DurationMs != nil {
		return "slow: took " + schedule.FormatDuration(float64(*last.DurationMs))
	}
	if hasCondition(job.Open, ConditionFailed) {
		return "failing"
	}
	if last == nil && job.NextExpectedAt != nil {
		return "no runs yet, first due " + whenUTC(*job.NextExpectedAt, now)
	}
	return ""
}

// laneInput is everything one lane shows.
type laneInput struct {
	job JobSummary
	// The job's runs, any order. Only those overlapping the span are drawn.
	runs []Run
	// False when older runs exist that were not read; the lane says so before its oldest run.
	complete bool
}

type laneParts struct{ svg, note, words string }

// fx is toFixed(1), the precision every coordinate is written with.
func fx(n float64) string { return toFixed(n, 1) }

// delay is the animation delay for a mark at x, so marks arrive in time
// order, left to right.
func delay(x, base, perUnit float64) string {
	return "--d:" + num(jsRound(base+math.Max(0, x)*perUnit)) + "ms"
}

func finishedOr(r Run, now int64) int64 {
	if r.FinishedAt != nil {
		return *r.FinishedAt
	}
	return now
}

func lane(input laneInput, sp span, nowInLane bool, name string) laneParts {
	job := input.job
	from, to, now := sp.from, sp.to, sp.now
	x := func(t int64) float64 {
		return math.Min(laneWidth, math.Max(0, (elapsedMs(from, t)/float64(to-from))*laneWidth))
	}
	parsed := laneSchedule(job)
	times, dense := dueTimes(job, parsed, input.runs, from, to)
	missed := missedAt(job, parsed, times, now)
	grace, err := graceMs(job.Definition)
	if err != nil {
		grace = 0
	}
	type interval struct{ lo, hi float64 }
	var busy []interval
	h := escapeHTML

	var s strings.Builder
	s.WriteString(`<svg class="marks" viewBox="0 0 1000 24" preserveAspectRatio="none" aria-hidden="true" focusable="false">`)
	if nowInLane && now > from && now < to {
		s.WriteString(`<rect class="ahead" x="` + fx(x(now)) + `" y="0" width="` + fx(laneWidth-x(now)) + `" height="24"/>`)
	}
	s.WriteString(`<line class="base" x1="0" y1="12" x2="1000" y2="12"/>`)

	var inSpan []Run
	for _, r := range input.runs {
		if r.StartedAt <= to && finishedOr(r, now) >= from {
			inSpan = append(inSpan, r)
		}
	}
	slices.SortStableFunc(inSpan, func(a, b Run) int {
		switch {
		case a.StartedAt < b.StartedAt:
			return -1
		case a.StartedAt > b.StartedAt:
			return 1
		}
		return 0
	})
	if !input.complete && len(input.runs) > 0 {
		oldest := input.runs[0].StartedAt
		for _, r := range input.runs[1:] {
			oldest = min(oldest, r.StartedAt)
		}
		if oldest > from {
			s.WriteString(`<rect class="unloaded" x="0" y="4" width="` + fx(x(oldest)) + `" height="16"><title>` +
				h(name+": runs before "+whenUTC(oldest, now)+" UTC are not loaded here") + `</title></rect>`)
		}
	}

	if dense {
		s.WriteString(`<line class="cadence" x1="0" y1="12" x2="1000" y2="12"><title>` +
			h(name+": due "+scheduleText(job, "")+", too often to mark each time") + `</title></line>`)
	}
	for _, t := range times {
		tx := x(t)
		ahead := ""
		if t > now {
			ahead = " ahead"
		}
		s.WriteString(`<line class="tick` + ahead + `" x1="` + fx(tx) + `" y1="6" x2="` + fx(tx) + `" y2="18" style="` + delay(tx, 0, 0.45) + `"/>`)
	}

	// Missed slots: the reported one and every later one whose grace has run out.
	if missed != nil && *missed <= to {
		m := *missed
		var slots []int64
		if !dense {
			for _, t := range times {
				if t >= m && float64(t)+grace < float64(now) {
					slots = append(slots, t)
				}
			}
		}
		if !slices.Contains(slots, m) && m >= from {
			slots = append([]int64{m}, slots...)
		}
		title := name + ": due " + whenUTC(m, now) + " UTC, nothing started"
		if len(slots) > 1 {
			title += " (" + num(len(slots)) + " slots in this span)"
		}
		title = h(title)
		if dense || len(slots) > maxBoxes {
			x1 := x(max(m, from))
			x2 := math.Max(x(now), x1+minBox)
			s.WriteString(`<rect class="missed" x="` + fx(x1) + `" y="5" width="` + fx(x2-x1) + `" height="14" style="` + delay(x1, 80, 0.75) + `"><title>` + title + `</title></rect>`)
			busy = append(busy, interval{x1, x2})
		} else {
			for _, t := range slots {
				if t < from {
					continue
				}
				x1 := x(t)
				width := math.Max(xf(float64(t)+grace, sp)-x1, minBox)
				s.WriteString(`<rect class="missed" x="` + fx(x1) + `" y="5" width="` + fx(width) + `" height="14" style="` + delay(x1, 80, 0.75) + `"><title>` + title + `</title></rect>`)
				busy = append(busy, interval{x1, x1 + width})
			}
		}
	}

	for _, run := range inSpan {
		tone := toneOf(run, job, now)
		// A zero-width rect is not drawn at all; its stroke gives short runs their width.
		x1 := x(run.StartedAt)
		x2 := math.Max(x(finishedOr(run, now)), x1+0.5)
		s.WriteString(`<rect class="run ` + tone + `" x="` + fx(x1) + `" y="5" width="` + fx(x2-x1) + `" height="14" style="` + delay(x1, 80, 0.75) + `"><title>` +
			h(name+": "+describeRun(run, tone, job, now)) + `</title></rect>`)
		busy = append(busy, interval{x1, x2})
	}

	if nowInLane && now > from && now < to {
		s.WriteString(`<line class="nowline" x1="` + fx(x(now)) + `" y1="0" x2="` + fx(x(now)) + `" y2="24"/>`)
	}
	s.WriteString(`</svg>`)

	// The note goes wherever the lane is actually empty, so it never sits on
	// the marks it describes; it is cut short with an ellipsis when narrow.
	text := laneNote(job, missed, now)
	note := ""
	if text != "" {
		nowX := x(now)
		lo, hi := nowX, nowX
		if len(busy) > 0 {
			lo, hi = math.Inf(1), math.Inf(-1)
			for _, b := range busy {
				lo, hi = math.Min(lo, b.lo), math.Max(hi, b.hi)
			}
		}
		right := laneWidth-hi >= lo
		room := lo
		if right {
			room = laneWidth - hi
		}
		if room > 90 {
			var place, cls string
			if right {
				place = "left:" + fx((hi+14)/10) + "%"
			} else {
				place = "right:" + fx(100-(lo-14)/10) + "%"
				cls = " before"
			}
			note = `<span class="note` + cls + `" style="` + place + `;max-width:` + fx((room-18)/10) + `%">` + h(text) + `</span>`
		}
	}
	return laneParts{svg: s.String(), note: note, words: laneWords(job, inSpan, times, dense, missed, sp, text)}
}

// xf is a lane's x for a time that need not be whole (a slot plus its grace).
func xf(t float64, sp span) float64 {
	return math.Min(laneWidth, math.Max(0, ((t-float64(sp.from))/float64(sp.to-sp.from))*laneWidth))
}

// scheduleText is `${definition.schedule ?? fallback}`.
func scheduleText(job JobSummary, fallback string) string {
	v, ok := job.Definition.get("schedule")
	if !ok || v == nil {
		return fallback
	}
	return jsText(v, true)
}

// laneWords is the lane in words, for anyone who cannot see it.
func laneWords(job JobSummary, runs []Run, times []int64, dense bool, missed *int64, sp span, note string) string {
	var parts []string
	schedValue, hasSched := job.Definition.get("schedule")
	if dense {
		parts = append(parts, "due "+jsText(schedValue, hasSched))
	} else if truthy(schedValue) {
		n := 0
		for _, t := range times {
			if t <= sp.now {
				n++
			}
		}
		switch n {
		case 0:
			parts = append(parts, "due no times so far")
		case 1:
			parts = append(parts, "due once so far")
		default:
			parts = append(parts, "due "+num(n)+" times so far")
		}
	}
	ok := 0
	for _, r := range runs {
		if r.Status == StatusOK {
			ok++
		}
	}
	recorded := num(len(runs)) + " runs recorded"
	if len(runs) == 1 {
		recorded = "1 run recorded"
	}
	switch {
	case len(runs) == 0:
	case ok == len(runs) && ok == 1:
		recorded += ", ok"
	case ok == len(runs):
		recorded += ", all ok"
	case ok > 0:
		recorded += ", " + num(ok) + " ok"
	}
	parts = append(parts, recorded)
	var bad []Run
	for _, r := range runs {
		if r.Status == StatusFailed || r.Status == StatusTimeout {
			bad = append(bad, r)
		}
	}
	if len(bad) > 5 {
		bad = bad[len(bad)-5:]
	}
	for _, r := range bad {
		took := 0.0
		if r.DurationMs != nil {
			took = float64(*r.DurationMs)
		}
		parts = append(parts, string(r.Status)+" at "+whenUTC(r.StartedAt, sp.now)+" UTC after "+schedule.FormatDuration(took))
	}
	if missed != nil {
		parts = append(parts, "due at "+whenUTC(*missed, sp.now)+" UTC and nothing started")
	}
	if note != "" && !strings.HasPrefix(note, "due ") && !strings.HasPrefix(note, "failed at") && !strings.HasPrefix(note, "timed out") {
		parts = append(parts, note)
	}
	return strings.Join(parts, "; ")
}

// hourGrid is the grid lines and hour labels every step, on UTC boundaries.
func hourGrid(sp span, step int64, nowLabel bool) (lines, labels string) {
	x := func(t int64) float64 { return (float64(t-sp.from) / float64(sp.to-sp.from)) * laneWidth }
	nowX := x(sp.now)
	var l, b strings.Builder
	for t := int64(math.Ceil(float64(sp.from)/float64(step))) * step; t <= sp.to; t += step {
		gx := x(t)
		l.WriteString(`<i class="gl" style="left:` + fx(gx/10) + `%"></i>`)
		nearNow := nowLabel && math.Abs(gx-nowX) < 70
		if gx < 25 || gx > laneWidth-25 || nearNow {
			continue
		}
		var cls []string
		if math.Mod(jsRound(float64(t)/hourMs), 6) != 0 {
			cls = append(cls, "minor")
		}
		// On a phone the track is too narrow for a label this close to "now"; CSS hides it there.
		if nowLabel && math.Abs(gx-nowX) < 170 {
			cls = append(cls, "near")
		}
		b.WriteString(`<span class="` + strings.Join(cls, " ") + `" style="left:` + fx(gx/10) + `%">` + clockUTC(t) + `</span>`)
	}
	if nowLabel && sp.now >= sp.from && sp.now <= sp.to {
		b.WriteString(`<span class="nowlabel" style="left:` + fx(nowX/10) + `%">now ` + clockUTC(sp.now) + `</span>`)
	}
	return l.String(), b.String()
}

// timelineLegend is the key under a timeline: a small sample of each mark
// and what it means.
var timelineLegend = func() string {
	key := func(inner string) string {
		return `<svg class="key" viewBox="0 0 16 12" aria-hidden="true" focusable="false">` + inner + `</svg>`
	}
	box := func(cls string) string { return key(`<rect class="` + cls + `" x="2" y="1" width="12" height="10"/>`) }
	items := [][2]string{
		{key(`<line class="tick" x1="8" y1="1" x2="8" y2="11"/>`), "due"},
		{box("run ok"), "ran"},
		{box("run bad"), "failed"},
		{box("run timeout"), "timed out"},
		{box("run warn"), "over budget or slow"},
		{box("run running"), "running"},
		{box("missed"), "missed"},
	}
	var b strings.Builder
	b.WriteString(`<p class="legend" aria-hidden="true">`)
	for _, it := range items {
		b.WriteString(`<span>` + it[0] + it[1] + `</span>`)
	}
	b.WriteString(`</p>`)
	return b.String()
}()

func stateClass(job JobSummary) string {
	switch job.Health {
	case HealthHealthy:
		return "ok"
	case HealthLate:
		return "warn"
	case HealthFailing, HealthStuck:
		return "bad"
	}
	return "muted"
}

// dayTimeline is the board's timeline: one lane per job across sp, with a
// shared now line and the first boardLanes jobs only. total is how many
// jobs there are in all, for the note when some are left out.
func dayTimeline(lanes []laneInput, sp span, base string, total int) string {
	lines, labels := hourGrid(sp, 3*hourMs, true)
	nowX := (float64(sp.now-sp.from) / float64(sp.to-sp.from)) * 100
	h := escapeHTML
	var rows, words strings.Builder
	for _, input := range lanes {
		job := input.job
		parts := lane(input, sp, false, job.Name)
		sched := scheduleText(job, "no schedule")
		rows.WriteString(`<li class="lane"><div class="who"><i class="sq ` + stateClass(job) + `" aria-hidden="true"></i><a class="name" href="` + h(base) + `/jobs/` + encodeURIComponent(job.Name) + `">` + escapeName(job.Name) + `</a><span class="sched">` + h(sched) + `</span></div><div class="track">` + parts.svg + parts.note + `</div></li>`)
		words.WriteString(`<li>` + h(job.Name+" ("+sched+"): "+parts.words+".") + `</li>`)
	}
	more := ""
	if total > len(lanes) {
		more = `<p class="more">Showing the first ` + num(len(lanes)) + ` of ` + num(total) + ` jobs here; the table below lists them all.</p>`
	}
	return `<figure class="timeline day">
<div class="axis" aria-hidden="true"><span></span><div class="hours">` + labels + `</div></div>
<div class="field">
<div class="under" aria-hidden="true"><span></span><div>` + lines + `<i class="future" style="left:` + fx(nowX) + `%"></i></div></div>
<ol class="lanes">` + rows.String() + `</ol>
<div class="over" aria-hidden="true"><span></span><div><i class="now" style="left:` + fx(nowX) + `%"></i></div></div>
</div>
` + timelineLegend + more + `
<ul class="vh">` + words.String() + `</ul>
</figure>`
}

// weekTimeline is a job's page: its last weekDays UTC days, today first,
// one lane each. complete is false when the runs read do not reach back
// over the week.
func weekTimeline(job JobSummary, runs []Run, complete bool, now int64) string {
	today := js.FloorDiv(now, dayMs) * dayMs
	var oldest *int64
	for _, r := range runs {
		if oldest == nil || r.StartedAt < *oldest {
			oldest = ptr(r.StartedAt)
		}
	}
	lines, labels := hourGrid(span{today, today + dayMs, now}, 3*hourMs, false)
	h := escapeHTML
	var rows, words strings.Builder
	for i := 0; i < weekDays; i++ {
		from := today - int64(i)*dayMs
		sp := span{from, from + dayMs, now}
		n := 0
		for _, r := range runs {
			if r.StartedAt < sp.to && finishedOr(r, now) >= from {
				n++
			}
		}
		known := complete || (oldest != nil && *oldest <= from)
		label := "today"
		if i > 0 {
			label = dayLabel(from)
		}
		parts := lane(laneInput{job, runs, known}, sp, i == 0, job.Name+", "+label)
		count := num(n) + " runs"
		if n == 1 {
			count = "1 run"
		}
		cls, name, note, said := "", dayLabel(from), "", dayLabel(from)
		if i == 0 {
			cls, name, note, said = " today", "Today, "+dayLabel(from)[4:], parts.note, "Today"
		}
		rows.WriteString(`<li class="lane` + cls + `"><div class="who"><span class="name">` + h(name) + `</span><span class="sched">` + h(count) + `</span></div><div class="track">` + parts.svg + note + `</div></li>`)
		words.WriteString(`<li>` + h(said+": "+parts.words+".") + `</li>`)
	}
	return `<figure class="timeline week">
<div class="axis" aria-hidden="true"><span></span><div class="hours">` + labels + `</div></div>
<div class="field">
<div class="under" aria-hidden="true"><span></span><div>` + lines + `</div></div>
<ol class="lanes">` + rows.String() + `</ol>
</div>
` + timelineLegend + `
<ul class="vh">` + words.String() + `</ul>
</figure>`
}

// weekRunsLimit is how many runs a job's page reads so its week is drawn in
// full: roughly how often the schedule was due over the week, with room to
// spare, from 50 (what the run list shows) to 500 (the most Runs returns).
func weekRunsLimit(job JobSummary, now int64) int {
	parsed := laneSchedule(job)
	if parsed == nil {
		return 50
	}
	from := js.FloorDiv(now, dayMs)*dayMs - (weekDays-1)*dayMs
	width := float64(now + dayMs - from)
	var expected float64
	if parsed.Kind == "interval" {
		expected = width / float64(parsed.EveryMs)
	} else {
		// A cron's fires over one day, times the week: close enough, and cheap.
		times, dense := dueTimes(job, parsed, nil, now-dayMs, now)
		if dense {
			expected = math.Inf(1)
		} else {
			expected = float64(len(times)) * width / dayMs
		}
	}
	return int(math.Min(500, math.Max(50, math.Ceil(expected*1.2)+10)))
}
