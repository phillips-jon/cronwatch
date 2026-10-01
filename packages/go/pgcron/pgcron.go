// Package pgcron watches pg_cron jobs, which run inside Postgres where
// nothing can wrap them (sources/pgcron.ts). As a source, on every check
// it reads cron.job and declares each job with its schedule, then copies
// new rows of cron.job_run_details in as runs (ids "pgcron:<runid>"), so
// the usual evaluation raises missed, failed, stuck and slow alerts.
//
//	source := pgcron.New(db, pgcron.Options{Prefix: "db:"}) // the app's *sql.DB, any Postgres driver
//	cw, err := cronwatch.New(cronwatch.WithStore(store), cronwatch.WithSources(source))
//	cw.StartChecking(time.Minute)
//
// A job that is renamed, unscheduled or no longer picked keeps its old
// name's runs and history, and that name is declared again without a
// schedule, so it is never reported missed. Its description says why.
//
// It reads through the app's database/sql handle with whatever driver the
// app uses (pgx's stdlib, lib/pq): a *sql.DB, a *sql.Conn or a *sql.Tx.
// Settings are read from pg_settings, which answers no row for a setting
// the role may not read where current_setting() would raise an error and
// abort the caller's transaction, and the source never commits or rolls
// back anything.
package pgcron

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"maps"
	"math"
	"regexp"
	"slices"
	"strconv"
	"strings"
	"sync"
	"time"

	cronwatch "cronwatch.dev/go"
	"cronwatch.dev/go/internal/js"
)

// Querier is what the source reads through: *sql.DB, *sql.Conn and *sql.Tx
// are all one.
type Querier interface {
	QueryContext(ctx context.Context, query string, args ...any) (*sql.Rows, error)
}

// Job is a row of cron.job.
type Job struct {
	JobID int64
	// JobName is nil for a job scheduled without a name.
	JobName  *string
	Schedule string
	Database string
	Username string
	Active   bool
}

// Row is a row of cron.job_run_details.
type Row struct {
	RunID         int64
	JobID         int64
	Status        string
	ReturnMessage *string
	StartTime     *time.Time
	EndTime       *time.Time
}

// Options configure the source.
type Options struct {
	// Jobs and JobIDs pick the jobs to watch by name or id; Pick picks
	// them with a function. Default every job the role can see.
	Jobs   []string
	JobIDs []int64
	Pick   func(Job) bool
	// Prefix goes before every job name, to keep them apart from your own
	// ("db:"). It also keeps run ids apart.
	Prefix string
	// JobName is the CronWatch name for a job. Default its jobname with
	// anything other than letters, digits, ".", "_", ":" and "-" turned
	// into "-", or "pg_cron:<jobid>" when it has none (JobName). The prefix
	// goes in front either way. One that panics or returns "", like a Pick
	// or OptionsFor that panics, is reported once and fails only that job,
	// which keeps its last declaration until the callback works again.
	JobName func(Job) string
	// Options are job options (Grace, Timeout, MaxDuration, Expect and the
	// rest) for every job; OptionsFor gives them per job. The schedule and
	// timezone always come from pg_cron.
	Options    []cronwatch.JobOption
	OptionsFor func(Job) []cronwatch.JobOption
	// Timezone is the zone pg_cron reads its cron expressions in. Default
	// the server's cron.timezone, read from pg_settings, which shows it only
	// to roles with pg_read_all_settings; UTC (pg_cron's default) is
	// assumed when it cannot be read.
	Timezone string
}

const (
	// backfill is how many of a job's newest runs are copied, without
	// alerting, the first time it is seen.
	backfill = 20
	// page is how many run details are read per query; maxPages how many
	// queries one sync makes at most.
	page     = 500
	maxPages = 10
)

// hold is how long a run pg_cron has queued but not started (no start_time
// yet) is waited for. After that it is copied as running from when it was
// first seen, so a run that never starts is marked stuck like any other.
const hold = 10 * time.Minute

// Hold is how long a run pg_cron has queued but not started is waited for
// (ten minutes), before it is copied as running.
//
// Deprecated: Hold is internal, and goes in 1.0.
const Hold = hold

const (
	jobsSQL = `SELECT jobid, jobname, schedule, database, username, active FROM cron.job ORDER BY jobid`
	// pg_settings has no row for a setting the role may not read, where
	// current_setting() raises an error that would abort the caller's
	// transaction.
	settingSQL = `SELECT setting FROM pg_settings WHERE name = $1`
	columns    = `d.runid, d.jobid, d.status, d.return_message, d.start_time, d.end_time`
	// Every tracked job's runs after its cursor, and any run still open
	// here, whatever its job. The arrays are passed as array literals in
	// text, which every driver can send.
	runsSQL = `SELECT ` + columns + `
  FROM cron.job_run_details d
  LEFT JOIN unnest($1::text::bigint[], $2::text::bigint[]) AS c(jobid, after) ON d.jobid = c.jobid
  WHERE d.runid > c.after OR d.runid = ANY($3::text::bigint[])
  ORDER BY d.runid LIMIT 500`
	newestSQL = `SELECT ` + columns + ` FROM cron.job_run_details d WHERE d.jobid = $1 ORDER BY d.runid DESC LIMIT 20`
)

func finished(status string) bool { return status == "succeeded" || status == "failed" }

var (
	secondsRE = regexp.MustCompile(`^(?i)([0-9]+)[` + js.Whitespace + `]*seconds?$`)
	rebootRE  = regexp.MustCompile(`^(?i)@reboot$`)
	spacesRE  = regexp.MustCompile(`[` + js.Whitespace + `]+`)
	unsafeRE  = regexp.MustCompile(`[^A-Za-z0-9._:-]+`)
	leadingRE = regexp.MustCompile(`^[^A-Za-z0-9]+`)
	jobidRE   = regexp.MustCompile(`^pg_cron job ([0-9]+) in `)
	utcRE     = regexp.MustCompile(`^(?i)(gmt|utc|z)$`)
)

// Schedule is a pg_cron schedule as a CronWatch one, or false for one that
// has no cadence to watch (@reboot).
//
// Deprecated: Schedule is internal, and goes in 1.0.
func Schedule(schedule string) (string, bool) { return scheduleOf(schedule) }

// scheduleOf is a pg_cron schedule as a CronWatch one: a cron expression,
// "$" for the last day of the month read as "L", or "N seconds" as
// "every Ns". pg_cron reads only the first five fields of an expression
// and ignores the rest, so only those are kept (a sixth would otherwise be
// read as seconds). It answers false for one that has no cadence to watch
// (@reboot).
func scheduleOf(schedule string) (string, bool) {
	text := js.Trim(schedule)
	if m := secondsRE.FindStringSubmatch(text); m != nil {
		n, _ := strconv.ParseFloat(m[1], 64)
		return "every " + js.FormatNumber(n) + "s", true
	}
	if rebootRE.MatchString(text) {
		return "", false
	}
	fields := spacesRE.Split(text, -1)
	if len(fields) > 5 && !strings.HasPrefix(fields[0], "@") {
		fields = fields[:5]
	}
	if len(fields) == 5 && strings.Contains(fields[2], "$") {
		fields[2] = strings.ReplaceAll(fields[2], "$", "L")
	}
	return strings.Join(fields, " "), true
}

// JobName is the default CronWatch name for a pg_cron job, before the
// prefix.
//
// Deprecated: JobName is internal, and goes in 1.0. The default name is
// documented (the job's jobname with characters a name cannot hold made
// "-", or "pg_cron:<jobid>") and does not change.
func JobName(j Job) string { return defaultJobName(j) }

// defaultJobName is the default CronWatch name for a pg_cron job, before
// the prefix.
func defaultJobName(j Job) string {
	name := ""
	if j.JobName != nil {
		name = *j.JobName
	}
	cleaned := leadingRE.ReplaceAllString(unsafeRE.ReplaceAllString(name, "-"), "")
	if len(cleaned) > 100 {
		cleaned = cleaned[:100]
	}
	if cleaned == "" {
		return "pg_cron:" + strconv.FormatInt(j.JobID, 10)
	}
	return cleaned
}

// RunOf is a row of cron.job_run_details as a CronWatch run, or nil for
// one that has not started.
//
// Deprecated: RunOf is internal, and goes in 1.0.
func RunOf(row Row, job, idPrefix string, fallbackAt int64) *cronwatch.Run {
	return runOf(row, job, idPrefix, fallbackAt)
}

// runOf is a row of cron.job_run_details as a CronWatch run, or nil for
// one that has not started (no start_time, not finished). A finished row
// with no start_time (pg_cron writes these for runs a server restart cut
// off, "server restarted") starts at its end_time, else at fallbackAt (the
// reader passes the job's newest run's start, or now).
func runOf(row Row, job, idPrefix string, fallbackAt int64) *cronwatch.Run {
	var finishedAt *int64
	if row.EndTime != nil {
		ms := row.EndTime.UnixMilli()
		finishedAt = &ms
	}
	done := finished(row.Status)
	if row.StartTime == nil && !done {
		return nil
	}
	startedAt := fallbackAt
	switch {
	case row.StartTime != nil:
		startedAt = row.StartTime.UnixMilli()
	case finishedAt != nil:
		startedAt = *finishedAt
	}
	var message *string
	if row.ReturnMessage != nil {
		if m := js.Trim(js.WellFormed(*row.ReturnMessage)); m != "" {
			message = &m
		}
	}
	status := cronwatch.RunStatus("running")
	switch row.Status {
	case "succeeded":
		status = "ok"
	case "failed":
		status = "failed"
	}
	run := &cronwatch.Run{
		ID:        idPrefix + strconv.FormatInt(row.RunID, 10),
		Job:       job,
		Status:    status,
		StartedAt: startedAt,
		Metrics:   cronwatch.Metrics{},
		Trigger:   "pg_cron",
	}
	if done {
		end := startedAt
		if finishedAt != nil {
			end = max(startedAt, *finishedAt)
		}
		// Held to 2^53 - 1 as the SDK's runDuration holds it: Postgres
		// timestamps span more milliseconds than that, never a wrap.
		duration := min(end-startedAt, 9007199254740991)
		run.FinishedAt, run.DurationMs = &end, &duration
	}
	switch status {
	case "failed":
		text := "pg_cron reported the run as failed"
		if message != nil {
			text = *message
		}
		run.Error = &text
	case "ok":
		run.Output = message
	}
	return run
}

// declared is a job as last declared: its name and the definition its
// options gave.
type declared struct {
	name       string
	definition cronwatch.Definition
}

// Source is the pg_cron source. Make one with New.
type Source struct {
	db       Querier
	o        Options
	idPrefix string

	mu sync.Mutex
	// cursors is the newest runid read for each jobid, once known.
	cursors map[int64]int64
	// lastAt is the start of the newest run copied for each jobid: where a
	// restart row with no times is put.
	lastAt map[int64]int64
	// pending are runs copied while still going, by runid, with their job:
	// read again until they finish, even once a check marks them timeout.
	pending map[int64]string
	// held are runs read before they started, by runid, with when they
	// were first seen.
	held map[int64]int64
	// known is each job's name and definition as last declared, by jobid.
	known map[int64]declared
	// declaredKeys is the last definition declared for each name, so an
	// unchanged job is not declared again.
	declaredKeys map[string]string
	// retired are names declared again without a schedule, whose open runs
	// are still read.
	retired map[string]bool
	scanned bool
	warned  map[string]bool
	// failing are jobids whose callback failed, reported once until it
	// works again.
	failing map[int64]bool
}

var _ cronwatch.Source = (*Source)(nil)

// New is a pg_cron source reading through db.
func New(db Querier, o Options) *Source {
	return &Source{
		db: db, o: o, idPrefix: "pgcron:" + o.Prefix,
		cursors: map[int64]int64{}, lastAt: map[int64]int64{}, pending: map[int64]string{}, held: map[int64]int64{},
		known: map[int64]declared{}, declaredKeys: map[string]string{}, retired: map[string]bool{}, warned: map[string]bool{},
		failing: map[int64]bool{},
	}
}

// Name is "pg_cron".
func (s *Source) Name() string { return "pg_cron" }

func (s *Source) warnOnce(host cronwatch.SourceHost, key, message string) {
	if s.warned[key] {
		return
	}
	s.warned[key] = true
	host.ReportError(errors.New(message), "source pg_cron")
}

func (s *Source) picks(j Job) bool {
	switch {
	case s.o.Pick != nil:
		return s.o.Pick(j)
	case s.o.Jobs == nil && s.o.JobIDs == nil:
		return true
	}
	for _, id := range s.o.JobIDs {
		if id == j.JobID {
			return true
		}
	}
	for _, name := range s.o.Jobs {
		if j.JobName != nil && name == *j.JobName {
			return true
		}
	}
	return false
}

// setting is a server setting from pg_settings, or false when the role may
// not read it (or the read failed).
func (s *Source) setting(ctx context.Context, name string) (string, bool) {
	rows, err := query(ctx, s.db, settingSQL, name)
	if err != nil || len(rows) == 0 {
		return "", false
	}
	v, ok := text(rows[0]["setting"])
	return v, ok
}

// runIDOf is the pg_cron runid of a run id this source made, or false.
func (s *Source) runIDOf(id string) (int64, bool) {
	rest, ok := strings.CutPrefix(id, s.idPrefix)
	if !ok {
		return 0, false
	}
	// Number(rest): "" is 0, spaces around it are dropped.
	rest = js.Trim(rest)
	if rest == "" {
		return 0, true
	}
	n, err := strconv.ParseFloat(rest, 64)
	if err != nil || n != math.Trunc(n) || math.Abs(n) > js.MaxSafeInteger {
		return 0, false
	}
	return int64(n), true
}

// guard is fn's answer, or the value it panicked with.
func guard[T any](fn func() T) (out T, panicked any) {
	defer func() {
		if p := recover(); p != nil {
			panicked = p
		}
	}()
	return fn(), nil
}

// panicText is a recovered panic's value as text: an error's message, or
// the value printed.
func panicText(p any) string {
	if err, ok := p.(error); ok {
		return err.Error()
	}
	return fmt.Sprint(p)
}

func keyOf(def cronwatch.Definition) string { return js.Stringify(def) }

// unscheduled are the options of a declared definition that can be
// declared again, without its schedule.
func unscheduled(def cronwatch.Definition) []cronwatch.JobOption {
	var out []cronwatch.JobOption
	if v, ok := def.Get("description"); ok {
		if d, ok := v.(string); ok {
			out = append(out, cronwatch.Description(d))
		}
	}
	if v, ok := def.Get("tags"); ok {
		list, _ := v.([]any)
		tags := []string{}
		for _, t := range list {
			if s, ok := t.(string); ok {
				tags = append(tags, s)
			}
		}
		out = append(out, cronwatch.Tags(tags...))
	}
	duration := func(key string, option func(v any) cronwatch.JobOption) {
		if v, ok := def.Get(key); ok {
			if o := option(v); o != nil {
				out = append(out, o)
			}
		}
	}
	duration("grace", func(v any) cronwatch.JobOption {
		switch d := v.(type) {
		case string:
			return cronwatch.Grace(d)
		case float64:
			return cronwatch.Grace(d)
		}
		return nil
	})
	duration("timeout", func(v any) cronwatch.JobOption {
		switch d := v.(type) {
		case string:
			return cronwatch.Timeout(d)
		case float64:
			return cronwatch.Timeout(d)
		}
		return nil
	})
	duration("maxDuration", func(v any) cronwatch.JobOption {
		switch d := v.(type) {
		case string:
			return cronwatch.MaxDuration(d)
		case float64:
			return cronwatch.MaxDuration(d)
		}
		return nil
	})
	if v, ok := def.Get("budget"); ok {
		if budget, ok := v.(*js.Object); ok {
			for _, metric := range budget.Keys() {
				ceiling, _ := budget.Get(metric)
				if n, ok := ceiling.(float64); ok {
					out = append(out, cronwatch.Budget(metric, n))
				}
			}
		}
	}
	if v, ok := def.Get("failuresBeforeAlert"); ok {
		if n, ok := v.(float64); ok {
			out = append(out, cronwatch.FailuresBeforeAlert(int(n)))
		}
	}
	return out
}

// retire declares a name this source no longer uses for any job again,
// without its schedule.
func (s *Source) retire(host cronwatch.SourceHost, name string, def cronwatch.Definition, why string) {
	description := "pg_cron job"
	if v, ok := def.Get("description"); ok {
		if d, ok := v.(string); ok {
			description = d
		}
	}
	options := append(unscheduled(def), cronwatch.Description(description+" ("+why+")"))
	if _, err := host.Job(name, options...); err != nil {
		host.ReportError(err, "source pg_cron: job "+name)
		return
	}
	s.declaredKeys[name] = keyOf(cronwatch.DescribeJob(name, options...))
	s.retired[name] = true
}

// Sync declares the jobs and copies their new runs in, returning the alerts
// recording them sent.
func (s *Source) Sync(ctx context.Context, host cronwatch.SourceHost) ([]cronwatch.Alert, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	now := host.Now()
	timezone := s.o.Timezone
	if timezone == "" {
		tz, ok := s.setting(ctx, "cron.timezone")
		if !ok {
			s.warnOnce(host, "tz", "could not read cron.timezone; assuming UTC. Grant pg_read_all_settings or pass pgcron.Options{Timezone: ...}.")
		}
		timezone = tz
		if !ok || utcRE.MatchString(tz) {
			timezone = "UTC"
		}
	}
	logRun, ok := s.setting(ctx, "cron.log_run")
	recording := !ok || logRun != "off"
	if !recording {
		s.warnOnce(host, "log_run", "cron.log_run is off, so pg_cron records no runs: jobs are watched without their schedules and no run can fail. Turn it on to watch them.")
	}

	rows, err := query(ctx, s.db, jobsSQL)
	if err != nil {
		return nil, err
	}
	if len(rows) == 0 {
		s.warnOnce(host, "empty", "cron.job shows no jobs. pg_cron's row level security shows a role only the jobs it scheduled: connect as that role, or give this one BYPASSRLS.")
	}
	all := make([]Job, len(rows))
	for i, r := range rows {
		all[i] = jobOf(r)
	}

	// Declare each job. A paused one (active = false) keeps its failures but loses its schedule, so it is not missed.
	// One forgotten since it was declared (the dashboard's forget) is declared again, though
	// unchanged: RecordRun takes runs only of a declared job. A host that cannot say (not a
	// *cronwatch.Client) is taken to keep every job the source declared.
	declares, canTell := host.(interface{ Declares(name string) bool })
	var order []int64
	names := map[int64]string{}
	definitions := map[int64]cronwatch.Definition{}
	used := map[string]bool{}
	// A callback of the app's (Pick, JobName, OptionsFor) that panicked, or
	// a JobName that gave no name, fails only its job, as a bad row does:
	// reported once until it works again, and the job carries on as last
	// declared (skipped when it never was), so its runs are still copied.
	trouble := func(j Job, what string) {
		if !s.failing[j.JobID] {
			s.failing[j.JobID] = true
			host.ReportError(fmt.Errorf("pg_cron job %d: %s; it keeps its last declaration until that works", j.JobID, what), "source pg_cron")
		}
		last, ok := s.known[j.JobID]
		if !ok || used[last.name] {
			return
		}
		order = append(order, j.JobID)
		names[j.JobID] = last.name
		definitions[j.JobID] = last.definition
		used[last.name] = true
	}
	for _, j := range all {
		picked, p := guard(func() bool { return s.picks(j) })
		if p != nil {
			trouble(j, "Pick panicked: "+panicText(p))
			continue
		}
		if !picked {
			delete(s.failing, j.JobID)
			continue
		}
		base := defaultJobName(j)
		if s.o.JobName != nil {
			base, p = guard(func() string { return s.o.JobName(j) })
			if p != nil {
				trouble(j, "JobName panicked: "+panicText(p))
				continue
			}
			if base == "" {
				trouble(j, "JobName returned no name")
				continue
			}
		}
		extra := s.o.Options
		if s.o.OptionsFor != nil {
			extra, p = guard(func() []cronwatch.JobOption { return s.o.OptionsFor(j) })
			if p != nil {
				trouble(j, "OptionsFor panicked: "+panicText(p))
				continue
			}
		}
		delete(s.failing, j.JobID)
		name := s.o.Prefix + base
		if used[name] {
			name += ":" + strconv.FormatInt(j.JobID, 10)
		}
		used[name] = true
		schedule := ""
		if j.Active && recording {
			schedule, _ = scheduleOf(j.Schedule)
		}
		paused := ""
		if !j.Active {
			paused = " (paused)"
		}
		options := []cronwatch.JobOption{
			cronwatch.Description(fmt.Sprintf("pg_cron job %d in %s as %s%s", j.JobID, j.Database, j.Username, paused)),
			cronwatch.Tags("pg_cron"),
		}
		options = append(options, extra...)
		unscheduledOptions := options
		if schedule != "" {
			options = append(options[:len(options):len(options)], cronwatch.Schedule(schedule), cronwatch.Timezone(timezone))
		}
		definition := cronwatch.DescribeJob(name, options...)
		key := keyOf(definition)
		if s.declaredKeys[name] != key || (canTell && !declares.Declares(name)) {
			if _, err := host.Job(name, options...); err != nil {
				if schedule == "" {
					host.ReportError(err, "source pg_cron: job "+strconv.FormatInt(j.JobID, 10))
					continue
				}
				// A schedule CronWatch cannot read: watch the runs, not the cadence.
				host.ReportError(fmt.Errorf("pg_cron job %d: %s; watching it without a schedule", j.JobID, err.Error()), "source pg_cron")
				definition = cronwatch.DescribeJob(name, unscheduledOptions...)
				if _, err := host.Job(name, unscheduledOptions...); err != nil {
					host.ReportError(err, "source pg_cron: job "+strconv.FormatInt(j.JobID, 10))
					continue
				}
			}
			s.declaredKeys[name] = key
		}
		order = append(order, j.JobID)
		names[j.JobID] = name
		definitions[j.JobID] = definition
	}

	// A name this source used for a job that has since been renamed, unscheduled or dropped from the jobs picked.
	inUse := map[string]bool{}
	for _, name := range names {
		inUse[name] = true
		delete(s.retired, name)
	}
	for _, jobid := range sortedKeys(s.known) {
		previous := s.known[jobid]
		if inUse[previous.name] {
			continue
		}
		why := "no longer watched"
		if renamed, ok := names[jobid]; ok {
			why = "renamed to " + renamed
		}
		s.retire(host, previous.name, previous.definition, why)
	}
	s.known = map[int64]declared{}
	for jobid, name := range names {
		s.known[jobid] = declared{name, definitions[jobid]}
	}
	// Once per process, the same for names left scheduled in the store while no process was watching.
	if !s.scanned && len(rows) > 0 {
		s.scanned = true
		visible := map[int64]bool{}
		for _, j := range all {
			visible[j.JobID] = true
		}
		stored, err := host.Store().ListJobs(ctx)
		if err != nil {
			host.ReportError(err, "source pg_cron")
		}
		for _, job := range stored {
			def := job.Definition
			if !strings.HasPrefix(job.Name, s.o.Prefix) || inUse[job.Name] || def.Schedule() == "" || !contains(def.Tags(), "pg_cron") {
				continue
			}
			m := jobidRE.FindStringSubmatch(def.Description())
			if m == nil {
				continue
			}
			jobid, _ := strconv.ParseInt(m[1], 10, 64)
			current, has := names[jobid]
			switch {
			case !visible[jobid]:
				s.retire(host, job.Name, def, "no longer in cron.job")
			// Another pg_cron source's name for the same job ends the same way: that one is left alone.
			case has && !strings.HasSuffix(job.Name, current[len(s.o.Prefix):]):
				s.retire(host, job.Name, def, "renamed to "+current)
			}
		}
	}
	if !recording || len(names) == 0 {
		return []cronwatch.Alert{}, nil
	}

	alerts := []cronwatch.Alert{}
	// record copies one row. A row that cannot be recorded is reported and skipped; it never stops the others.
	record := func(row Row, evaluate bool) {
		name, ok := s.pending[row.RunID]
		if !ok {
			name, ok = names[row.JobID]
		}
		if !ok {
			delete(s.held, row.RunID)
			return
		}
		var run *cronwatch.Run
		if row.StartTime == nil && !finished(row.Status) {
			since, seen := s.held[row.RunID]
			if !seen {
				since = now
			}
			if now-since < hold.Milliseconds() {
				s.held[row.RunID] = since
				return
			}
			start := time.UnixMilli(since)
			row.StartTime = &start
			run = runOf(row, name, s.idPrefix, now)
		} else {
			fallback, ok := s.lastAt[row.JobID]
			if !ok {
				fallback = now
			}
			run = runOf(row, name, s.idPrefix, fallback)
		}
		delete(s.held, row.RunID)
		if run == nil {
			return
		}
		var options []cronwatch.RecordOption
		if !evaluate {
			options = append(options, cronwatch.WithoutEvaluation())
		}
		sent, err := host.RecordRun(ctx, *run, options...)
		if err != nil {
			host.ReportError(err, "source pg_cron: run "+strconv.FormatInt(row.RunID, 10))
			return
		}
		alerts = append(alerts, sent...)
		if run.Status == "running" {
			s.pending[row.RunID] = name
		} else {
			delete(s.pending, row.RunID)
		}
		if last, ok := s.lastAt[row.JobID]; !ok || run.StartedAt > last {
			s.lastAt[row.JobID] = run.StartedAt
		}
	}

	// Where each job left off. Found from the store the first time, so a restart carries on.
	for _, jobid := range order {
		name := names[jobid]
		if _, ok := s.cursors[jobid]; ok {
			continue
		}
		runs, err := host.Store().ListRuns(ctx, name, backfill)
		if err != nil {
			return alerts, err
		}
		var ours []cronwatch.Run
		for _, r := range runs {
			if _, ok := s.runIDOf(r.ID); ok {
				ours = append(ours, r)
			}
		}
		if len(ours) > 0 {
			cursor, last := int64(math.MinInt64), int64(math.MinInt64)
			for _, r := range ours {
				id, _ := s.runIDOf(r.ID)
				cursor, last = max(cursor, id), max(last, r.StartedAt)
				if r.Status == cronwatch.StatusRunning || r.Status == cronwatch.StatusTimeout {
					s.pending[id] = r.Job
				}
			}
			s.cursors[jobid], s.lastAt[jobid] = cursor, last
			continue
		}
		// First sight: copy recent history quietly, and judge only from the newest finished run on.
		// The cursor goes to the newest row read, whatever is held, so history is never judged later.
		found, err := query(ctx, s.db, newestSQL, jobid)
		if err != nil {
			return alerts, err
		}
		ordered := make([]Row, len(found))
		for i, r := range found {
			ordered[len(found)-1-i] = rowOf(r)
		}
		lastFinished := -1
		for i, r := range ordered {
			if finished(r.Status) {
				lastFinished = i
			}
		}
		for i, row := range ordered {
			// Already copied under another name (the job was renamed while no process watched): left there.
			stored, err := host.Store().GetRun(ctx, s.idPrefix+strconv.FormatInt(row.RunID, 10))
			if err != nil {
				return alerts, err
			}
			if stored != nil {
				continue
			}
			record(row, i >= lastFinished)
		}
		s.cursors[jobid] = 0
		if len(ordered) > 0 {
			s.cursors[jobid] = ordered[len(ordered)-1].RunID
		}
	}

	// New runs, runs copied while still going (or since marked timeout), and runs not yet started.
	watched := map[string]bool{}
	for _, name := range names {
		watched[name] = true
	}
	for name := range s.retired {
		watched[name] = true
	}
	running, err := host.Store().RunningRuns(ctx)
	if err != nil {
		return alerts, err
	}
	for _, r := range running {
		if id, ok := s.runIDOf(r.ID); ok && watched[r.Job] {
			s.pending[id] = r.Job
		}
	}
	open := map[int64]bool{}
	for id := range s.pending {
		open[id] = true
	}
	for id := range s.held {
		open[id] = true
	}
	complete := false
	for p := 0; p < maxPages; p++ {
		afters := make([]int64, len(order))
		for i, jobid := range order {
			afters[i] = s.cursors[jobid]
		}
		found, err := query(ctx, s.db, runsSQL, arrayOf(order), arrayOf(afters), arrayOf(sortedKeys(open)))
		if err != nil {
			return alerts, err
		}
		for _, r := range found {
			row := rowOf(r)
			delete(open, row.RunID)
			record(row, true)
			// Held or not, the cursor moves on: a held run is read again by its runid.
			if _, tracked := names[row.JobID]; tracked && row.RunID > s.cursors[row.JobID] {
				s.cursors[row.JobID] = row.RunID
			}
		}
		if len(found) < page {
			complete = true
			break
		}
	}
	// Every row was read and these were not among them: pg_cron no longer has them.
	if complete {
		for id := range open {
			delete(s.pending, id)
			delete(s.held, id)
		}
	}
	return alerts, nil
}

func contains(list []string, s string) bool {
	for _, e := range list {
		if e == s {
			return true
		}
	}
	return false
}

func sortedKeys[V any](m map[int64]V) []int64 {
	return slices.Sorted(maps.Keys(m))
}

// arrayOf is a Postgres array literal, "{1,2,3}".
func arrayOf(ids []int64) string {
	parts := make([]string, len(ids))
	for i, id := range ids {
		parts[i] = strconv.FormatInt(id, 10)
	}
	return "{" + strings.Join(parts, ",") + "}"
}
