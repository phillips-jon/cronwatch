package cronwatch

// The dashboard's pages (routes/html.ts), byte for byte: set like
// cronwatch.dev, a printed sheet on grey paper, a serif for what a person
// reads, a mono for what a machine printed, neutral greys, and colour only
// for the states CronWatch reports. The page loads nothing but its own app
// shell, and works without its one script.

import (
	"strings"

	"cronwatch.dev/go/internal/js"
	"cronwatch.dev/go/internal/schedule"
)

// layout is a page. base is where the dashboard is mounted ("" at the
// root); refresh, when above 0, is the page's refresh in seconds.
func layout(title, body, base string, refresh int) string {
	b := escapeHTML(base)
	meta := ""
	if refresh > 0 {
		meta = `<meta http-equiv="refresh" content="` + num(refresh) + `">`
	}
	return `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover">
<meta name="robots" content="noindex,nofollow">
<meta name="color-scheme" content="light dark">
` + meta + `
<title>` + escapeHTML(title) + `</title>
<meta name="theme-color" content="` + pwaThemeColor + `" media="(prefers-color-scheme: light)">
<meta name="theme-color" content="` + pwaThemeColorDark + `" media="(prefers-color-scheme: dark)">
<meta name="mobile-web-app-capable" content="yes">
<meta name="apple-mobile-web-app-capable" content="yes">
<meta name="apple-mobile-web-app-title" content="CronWatch">
<meta name="apple-mobile-web-app-status-bar-style" content="default">
<link rel="manifest" href="` + b + `/manifest.webmanifest">
<link rel="icon" href="` + b + `/icons/icon.svg" type="image/svg+xml">
<link rel="apple-touch-icon" href="` + b + `/icons/apple-touch-icon.png">
<script src="` + b + `/app.js" defer></script>
<style>` + dashboardCSS + `</style>
</head>
<body><div class="sheet">` + body + `</div></body>
</html>`
}

// brand is the header's mark and name, and a crumb after it when one is given.
func brand(base string, crumb *string) string {
	home := `<a href="` + escapeHTML(base) + `/">` + dashboardMark + `<span>CronWatch</span></a>`
	if crumb == nil {
		return `<p class="brand">` + home + `</p>`
	}
	return `<p class="brand">` + home + `<span class="slash" aria-hidden="true">/</span><span class="crumb">` + escapeName(*crumb) + `</span></p>`
}

// healthOrder is the healths in the SDK's order, with their class and label.
var healthOrder = []struct {
	health     JobHealth
	cls, label string
}{
	{HealthFailing, "bad", "failing"},
	{HealthStuck, "bad", "stuck"},
	{HealthLate, "warn", "late"},
	{HealthHealthy, "ok", "healthy"},
	{HealthSilenced, "muted", "silenced"},
	{HealthNeverRan, "muted", "never ran"},
}

func healthLabel(h JobHealth) (cls, label string) {
	for _, e := range healthOrder {
		if e.health == h {
			return e.cls, e.label
		}
	}
	// A health this version does not know, as the SDK's lookup would leave it.
	return "undefined", "undefined"
}

// conditionText is c.replace("_", " "): the first underscore only.
func conditionText(c Condition) string { return strings.Replace(string(c), "_", " ", 1) }

// healthState is the job's health, with any open condition it does not
// already say (over budget, slow) after it.
func healthState(job JobSummary) string {
	cls, label := healthLabel(job.Health)
	var extras strings.Builder
	for _, c := range job.Open {
		if c != ConditionMissed && c != ConditionFailed && c != ConditionStuck {
			extras.WriteString(`<span class="state warn">` + escapeHTML(conditionText(c)) + `</span>`)
		}
	}
	return `<span class="state ` + cls + `"><i class="sq ` + cls + `" aria-hidden="true"></i>` + label + `</span>` + extras.String()
}

func runState(run Run) string {
	cls := "bad"
	switch run.Status {
	case StatusOK:
		cls = "ok"
	case StatusRunning:
		cls = "info"
	}
	return `<span class="state ` + cls + `">` + escapeHTML(string(run.Status)) + `</span>`
}

// sparkline is the last twenty runs, oldest first, as bars as tall as they
// took; grey unless something went wrong.
func sparkline(runs []Run) string {
	points := runs[:min(20, len(runs))]
	if len(points) < 2 {
		return ""
	}
	const bar, gap, hgt = 4.0, 1.5, 22.0
	took := func(r Run) float64 {
		if r.DurationMs == nil {
			return 0
		}
		return float64(*r.DurationMs)
	}
	most := 1.0
	for _, r := range points {
		most = max(most, took(r))
	}
	var bars strings.Builder
	for i := range points {
		r := points[len(points)-1-i]
		x := toFixed(float64(i)*(bar+gap), 1)
		if r.Status == StatusRunning {
			bars.WriteString(`<rect class="running" x="` + x + `" y="15.5" width="3" height="6"/>`)
			continue
		}
		floor, cls := 6.0, ` class="bad"`
		if r.Status == StatusOK {
			floor, cls = 2, ""
		}
		tall := max(floor, (took(r)/most)*hgt)
		bars.WriteString(`<rect` + cls + ` x="` + x + `" y="` + toFixed(hgt-tall, 1) + `" width="4" height="` + toFixed(tall, 1) + `" rx=".5"/>`)
	}
	w := toFixed(float64(len(points))*(bar+gap)-gap, 1)
	return `<svg class="spark" width="` + w + `" height="22" viewBox="0 0 ` + w + ` 22" aria-hidden="true" focusable="false">` + bars.String() + `</svg>`
}

// stamp is a time as "5m ago", with the full UTC time as its title.
func stamp(at *int64, now int64) string {
	if at == nil {
		return `<span class="muted">never</span>`
	}
	iso := js.ISOString(*at)
	return `<time class="nowrap" datetime="` + iso + `" title="` + strings.Replace(iso, "T", " ", 1)[:19] + ` UTC">` + escapeHTML(schedule.FormatRelative(*at, now)) + `</time>`
}

// healthFigures are the counts by health, the ones needing attention first;
// a zero is set faint rather than left out, so the row keeps its shape.
func healthFigures(jobs []JobSummary) string {
	var b strings.Builder
	b.WriteString(`<dl class="figures">`)
	for _, e := range healthOrder {
		n := 0
		for _, j := range jobs {
			if j.Health == e.health {
				n++
			}
		}
		cls := e.cls
		if n == 0 {
			cls = "zero"
		}
		b.WriteString(`<div class="` + cls + `"><dt><i class="sq ` + e.cls + `" aria-hidden="true"></i>` + e.label + `</dt><dd>` + num(n) + `</dd></div>`)
	}
	b.WriteString(`</dl>`)
	return b.String()
}

// defValue is a definition's field and whether it is truthy, as a template's
// `d.x ? ... : ...` reads it.
func defValue(d Definition, key string) (any, bool) {
	v, _ := d.get(key)
	return v, truthy(v)
}

// scheduleCell is the board's schedule column.
func scheduleCell(d Definition) string {
	sched, ok := defValue(d, "schedule")
	if !ok {
		return `<span class="muted">no schedule</span>`
	}
	out := escapeValue(sched)
	if tz, ok := defValue(d, "timezone"); ok {
		out += `<span class="tz">` + escapeValue(tz) + `</span>`
	}
	return out
}

func dashboardPage(jobs []JobSummary, runsByJob map[string][]Run, now int64, base string, checkedAt *int64, lanes []laneInput) string {
	h := escapeHTML
	attention := 0
	for _, j := range jobs {
		if j.Health != HealthHealthy {
			attention++
		}
	}
	var headline string
	switch {
	case len(jobs) == 0:
		headline = "No jobs yet."
	case attention == 0 && len(jobs) == 1:
		headline = "The one job is healthy."
	case attention == 0:
		headline = "All " + num(len(jobs)) + " jobs are healthy."
	default:
		s := "s"
		if len(jobs) == 1 {
			s = ""
		}
		headline = num(len(jobs)) + " job" + s + ", <b>" + num(attention) + " needing attention</b>."
	}

	rows := make([]string, len(jobs))
	for i, job := range jobs {
		d := job.Definition
		desc := ""
		if v, ok := defValue(d, "description"); ok {
			desc = `<span class="desc">` + escapeValue(v) + `</span>`
		}
		last := `<span class="muted">never</span>`
		if job.LastRun != nil {
			last = runState(*job.LastRun) + " " + stamp(&job.LastRun.StartedAt, now)
			if job.LastRun.DurationMs != nil {
				last += `<span class="sub">took ` + h(schedule.FormatDuration(float64(*job.LastRun.DurationMs))) + `</span>`
			}
		}
		next := `<span class="muted">not scheduled</span>`
		if job.NextExpectedAt != nil {
			next = ""
			if *job.NextExpectedAt < now {
				next = `<span class="state warn">overdue</span> `
			}
			next += stamp(job.NextExpectedAt, now) + `<span class="sub">` + h(whenUTC(*job.NextExpectedAt, now)) + ` UTC</span>`
		}
		rows[i] = `<tr>
<td class="job"><a class="name" href="` + h(base) + `/jobs/` + encodeURIComponent(job.Name) + `">` + escapeName(job.Name) + `</a>` + desc + `</td>
<td class="health">` + healthState(job) + `</td>
<td class="nowrap hide-sm">` + scheduleCell(d) + `</td>
<td class="nowrap last">` + last + `</td>
<td class="nowrap hide-sm">` + next + `</td>
<td class="hide-sm">` + sparkline(runsByJob[job.Name]) + `</td>
</tr>`
	}

	checked := ""
	if checkedAt != nil && *checkedAt != 0 {
		checked = ", checked " + h(schedule.FormatRelative(*checkedAt, now))
	}
	health := `<p class="empty">Declare one with <code>cw.job("name", { schedule: "0 2 * * *" })</code> and run it once, and it shows up here.</p>`
	sections := ""
	if len(jobs) > 0 {
		health = healthFigures(jobs)
		sp := span{now - boardBehindMs, now + boardAheadMs, now}
		sections = `<section class="sec" aria-label="Last 24 hours">
  <h2>Last 24 hours</h2>
  <p class="lede">One lane per job. Faint ticks mark when it was due, bars the runs it recorded, as long as they took. A dashed box is a slot nothing ran in. Times are UTC.</p>
  <div class="wide">` + dayTimeline(lanes, sp, base, len(jobs)) + `</div>
</section>
<section class="sec" aria-label="Jobs">
  <h2>Jobs</h2>
  <p class="lede">Every job in the store. Open one for its week, its runs and their output.</p>
  <div class="wide"><table class="board">
<thead><tr><th>Job</th><th>Health</th><th class="hide-sm">Schedule</th><th>Last run</th><th class="hide-sm">Next due</th><th class="hide-sm">Recent runs</th></tr></thead>
<tbody>` + strings.Join(rows, "\n") + `</tbody></table></div>
</section>`
	}
	body := `
<header class="top">
  ` + brand(base, nil) + `
  <div class="actions">
    <span class="meta">` + h(clockUTC(now)) + ` UTC` + checked + `</span>
    <form class="inline" method="post" action="` + h(base) + `/check"><button class="primary" type="submit">Run check now</button></form>
  </div>
</header>
<main>
<section class="sec" aria-label="Health">
  <h2>Health</h2>
  <div>
    <p class="headline">` + headline + `</p>
    ` + health + `
  </div>
</section>
` + sections + `
</main>
<footer><span>Refreshes every minute. Times are UTC.</span><a href="` + h(base) + `/api/jobs">JSON</a></footer>`
	return layout("CronWatch", body, base, 60)
}

// metricText is a metric's value as the run list shows it: whole numbers
// as they are, others to four places.
func metricText(v float64) string {
	if js.IsInteger(v) {
		return num(v)
	}
	return toFixed(v, 4)
}

// jobPage is one job: its state and figures, its last seven days, its runs
// with their output, and its definition. complete is false when runs does
// not reach back over the whole week (the run list shows the newest fifty).
func jobPage(job JobSummary, runs []Run, now int64, base string, complete bool) string {
	h := escapeHTML
	d := job.Definition
	okRate := num(jsRound(job.Stats.OkRate*100)) + "%"
	listed := runs[:min(50, len(runs))]
	runRows := make([]string, len(listed))
	for i, run := range listed {
		detail := ""
		if run.Error != nil && *run.Error != "" {
			detail += `<details class="out error" open><summary>error</summary><pre>` + h(*run.Error) + `</pre></details>`
		}
		if run.Output != nil && *run.Output != "" {
			open := " open"
			if run.Status == StatusOK {
				open = ""
			}
			detail += `<details class="out"` + open + `><summary>output</summary><pre>` + h(*run.Output) + `</pre></details>`
		}
		var metrics strings.Builder
		for _, m := range run.Metrics {
			metrics.WriteString(`<span><span class="k">` + h(m.Name) + `</span> ` + h(metricText(m.Value)) + `</span>`)
		}
		took := `<span class="muted">running</span>`
		if run.DurationMs != nil {
			took = h(schedule.FormatDuration(float64(*run.DurationMs)))
		}
		metricCell := ""
		if metrics.Len() > 0 {
			metricCell = `<span class="metrics">` + metrics.String() + `</span>`
		}
		hasDetail, detailRow := "", ""
		if detail != "" {
			hasDetail = ` class="has-detail"`
			detailRow = `<tr class="detail"><td colspan="5">` + detail + `</td></tr>`
		}
		runRows[i] = `<tr` + hasDetail + `>
<td class="nowrap">` + runState(run) + `</td>
<td class="nowrap">` + h(whenUTC(run.StartedAt, now)) + ` <span class="muted">UTC</span><span class="sub">` + stamp(&run.StartedAt, now) + `</span></td>
<td class="nowrap">` + took + `</td>
<td class="hide-sm">` + metricCell + `</td>
<td class="hide-sm muted">` + h(run.Trigger) + `</td>
</tr>` + detailRow
	}

	silenced := job.SilencedUntil != nil && *job.SilencedUntil > now
	path := h(base) + "/jobs/" + encodeURIComponent(job.Name)
	why := laneNote(job, missedAt(job, laneSchedule(job), nil, now), now)
	whyHTML := ""
	if why != "" {
		whyHTML = `<span class="why">` + h(why) + `</span>`
	}
	desc := ""
	if v, ok := defValue(d, "description"); ok {
		desc = `<p class="desc">` + escapeValue(v) + `</p>`
	}
	var silence string
	if silenced {
		silence = `<form class="inline" method="post" action="` + path + `/unsilence"><button type="submit">Unsilence (until ` + h(schedule.FormatRelative(*job.SilencedUntil, now)) + `)</button></form>`
	} else {
		silence = `<form class="inline" method="post" action="` + path + `/silence"><select name="for" aria-label="Silence for"><option value="1h">1 hour</option><option value="4h">4 hours</option><option value="1d">1 day</option><option value="7d">1 week</option></select><button type="submit">Silence</button></form>`
	}
	lastRun := "never"
	if job.LastRun != nil {
		lastRun = h(schedule.FormatRelative(job.LastRun.StartedAt, now))
	}
	nextDue := `<small>no schedule</small>`
	if job.NextExpectedAt != nil {
		nextDue = h(schedule.FormatRelative(*job.NextExpectedAt, now))
	}
	percentile := func(p *int64) string {
		if p == nil {
			return "?"
		}
		return h(schedule.FormatDuration(float64(*p)))
	}
	runsSection := `<p class="lede">No runs yet.</p>`
	if len(listed) > 0 {
		newest := num(len(listed)) + " runs"
		if len(listed) == 1 {
			newest = "run"
		}
		runsSection = `<p class="lede">The newest ` + newest + `, with any error and output.</p>
  <div class="wide"><table class="runs">
<thead><tr><th>Status</th><th>Started</th><th>Took</th><th class="hide-sm">Metrics</th><th class="hide-sm">Trigger</th></tr></thead>
<tbody>` + strings.Join(runRows, "\n") + `</tbody></table></div>`
	}

	body := `
<header class="top">
  ` + brand(base, &job.Name) + `
  <div class="actions"><span class="meta">` + h(clockUTC(now)) + ` UTC</span></div>
</header>
<main>
<section class="sec intro" aria-label="Job">
  <h2>Job</h2>
  <div>
    <h1 class="jobname">` + escapeName(job.Name) + `</h1>
    ` + desc + `
    <p class="stateline">` + healthState(job) + whyHTML + `</p>
    <div class="actions">
      ` + silence + `
      <details class="confirm"><summary>Forget</summary><form class="inline" method="post" action="` + path + `/forget"><span>Remove this job and its runs from the store?</span> <button type="submit">Forget</button></form></details>
    </div>
    <dl class="figures">
      <div><dt>Last run</dt><dd>` + lastRun + `</dd></div>
      <div><dt>Next due</dt><dd>` + nextDue + `</dd></div>
      <div><dt>Success, last ` + h(num(job.Stats.Runs)) + `</dt><dd>` + h(okRate) + `</dd></div>
      <div><dt>p50 / p95</dt><dd>` + percentile(job.Stats.P50Ms) + ` <small>/ ` + percentile(job.Stats.P95Ms) + `</small></dd></div>
    </dl>
  </div>
</section>
<section class="sec" aria-label="Last 7 days">
  <h2>Last 7 days</h2>
  <p class="lede">A lane per UTC day, today first. Faint ticks mark when the job was due, bars its runs, as long as they took.</p>
  <div class="wide">` + weekTimeline(job, runs, complete, now) + `</div>
</section>
<section class="sec" aria-label="Runs">
  <h2>Runs</h2>
  ` + runsSection + `
</section>
<section class="sec" aria-label="Definition">
  <h2>Definition</h2>
  <dl class="def">
  <dt>Schedule</dt><dd>` + definitionSchedule(d) + `</dd>
  <dt>Grace</dt><dd>` + orDefault(d, "grace", "10m") + `</dd>
  <dt>Timeout</dt><dd>` + orDefault(d, "timeout", "1h") + `</dd>
  ` + definitionRow(d, "maxDuration", "Max duration") + `
  ` + budgetRow(d) + `
  ` + definitionRow(d, "expect", "Expect") + `
  ` + alertAfterRow(d) + `
  ` + tagsRow(d) + `
  ` + openRow(job) + `
  ` + failuresRow(job) + `
  </dl>
</section>
</main>
<footer><span>Refreshes every minute. Times are UTC.</span><a href="` + h(base) + `/api/jobs/` + encodeURIComponent(job.Name) + `">JSON</a></footer>`
	return layout(job.Name+": CronWatch", body, base, 60)
}

func definitionSchedule(d Definition) string {
	sched, ok := defValue(d, "schedule")
	if !ok {
		return `<span class="muted">none</span>`
	}
	out := escapeValue(sched)
	if tz, ok := defValue(d, "timezone"); ok {
		out += ` <span class="muted">` + escapeValue(tz) + `</span>`
	}
	return out
}

// orDefault is h(d[key] ?? fallback).
func orDefault(d Definition, key, fallback string) string {
	if v, _ := d.get(key); v != nil {
		return escapeValue(v)
	}
	return escapeHTML(fallback)
}

func definitionRow(d Definition, key, label string) string {
	v, ok := defValue(d, key)
	if !ok {
		return ""
	}
	return `<dt>` + label + `</dt><dd>` + escapeValue(v) + `</dd>`
}

func budgetRow(d Definition) string {
	v, ok := defValue(d, "budget")
	if !ok {
		return ""
	}
	var parts []string
	if o, isObject := v.(*js.Object); isObject {
		for _, k := range o.Keys() {
			limit, _ := o.Get(k)
			parts = append(parts, k+" ≤ "+jsText(limit, true))
		}
	}
	return `<dt>Budget</dt><dd>` + escapeHTML(strings.Join(parts, ", ")) + `</dd>`
}

func alertAfterRow(d Definition) string {
	v, ok := defValue(d, "failuresBeforeAlert")
	if !ok || !(jsNumber(v) > 1) {
		return ""
	}
	return `<dt>Alert after</dt><dd>` + escapeValue(v) + ` consecutive failures</dd>`
}

func tagsRow(d Definition) string {
	v, _ := d.get("tags")
	var tags []string
	switch t := v.(type) {
	case []any:
		for _, e := range t {
			tags = append(tags, escapeValue(e))
		}
	case string:
		// A string's length and map are not an array's, so the SDK's page
		// would fail on one; show it as it is.
		if t != "" {
			tags = append(tags, escapeHTML(t))
		}
	}
	if len(tags) == 0 {
		return ""
	}
	return `<dt>Tags</dt><dd>` + strings.Join(tags, ", ") + `</dd>`
}

func openRow(job JobSummary) string {
	if len(job.Open) == 0 {
		return ""
	}
	var b strings.Builder
	for _, c := range job.Open {
		cls := "warn"
		if c == ConditionFailed || c == ConditionStuck {
			cls = "bad"
		}
		b.WriteString(`<span class="state ` + cls + `">` + escapeHTML(conditionText(c)) + `</span>`)
	}
	return `<dt>Open</dt><dd>` + b.String() + `</dd>`
}

func failuresRow(job JobSummary) string {
	if job.ConsecutiveFailures <= 0 {
		return ""
	}
	return `<dt>Failures in a row</dt><dd>` + num(job.ConsecutiveFailures) + `</dd>`
}

// messagePage is a page with one message. With signIn, a form under it
// takes the token and sends it as ?token=, which the routes move into the
// cookie: the way in where there is no address bar to open a link with,
// such as an app on an iPhone's home screen.
func messagePage(title, message, base string, signIn bool) string {
	form := ""
	if signIn {
		form = `<form class="signin" method="get" action="` + escapeHTML(base) + `/"><label for="token">Token</label><input id="token" name="token" type="password" autocomplete="current-password" autocapitalize="off" spellcheck="false" required><button class="primary" type="submit">Sign in</button></form>`
	}
	return layout(title, `<header class="top">`+brand(base, nil)+`</header><main class="message"><h1>`+escapeHTML(title)+`</h1><p>`+escapeHTML(message)+`</p>`+form+`</main>`, base, 0)
}
