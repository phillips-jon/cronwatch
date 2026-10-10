package bridge

import (
	"context"
	"errors"
	"fmt"
	"slices"
	"strings"
	"sync"
	"time"

	cronwatch "cronwatch.dev/go"
	"cronwatch.dev/go/internal/js"
)

// Entry is one job a scheduler runs, as an integration reads it.
type Entry struct {
	// Name is the job's name.
	Name string
	// Where names the entry in messages: `robfig/cron entry 3 (jobs.Nightly)`.
	Where string
	// Schedule and Timezone are the scheduler's schedule as CronWatch reads
	// it, "" for none.
	Schedule, Timezone string
	// Problem is why an entry with a schedule of its own has none here: it
	// is reported once, and the job watched without a schedule.
	Problem error
	// Defaults are the integration's options for every job, applied before
	// the schedule, as the SDK spreads a client's defaults first.
	Defaults []cronwatch.JobOption
	// Options are the job options the app gave this entry, applied after
	// the schedule, so a Schedule among them replaces the scheduler's.
	Options []cronwatch.JobOption
}

// Watch is what an integration keeps for one scheduler: the jobs it
// declared, by name, and the problems it reported. Safe for use by many
// goroutines at once.
type Watch struct {
	cw        *cronwatch.Client
	tag       string
	appTag    string
	scheduler string

	// declaring holds one Declare at a time, so one never takes another's
	// entries for gone.
	declaring sync.Mutex

	mu   sync.Mutex
	jobs map[string]*declared
	// fallback are jobs declared for runs of jobs this watch did not declare.
	fallback map[string]*cronwatch.Job
	reported map[string]bool
	// seen is whether this process ever declared an entry: until it has, it
	// takes no job for one the scheduler dropped (a process that runs a
	// check and no scheduler must not unschedule the app's jobs).
	seen bool

	// pending are names declared and not yet written to the store, which
	// one goroutine at a time (saving) writes; settled is signalled when it
	// has none left.
	pending map[string]bool
	saving  bool
	settled *sync.Cond
}

type declared struct {
	job *cronwatch.Job
	// key is the definition's JSON, to tell a changed declaration.
	key string
	// options declared it, to declare it again after a forget.
	options []cronwatch.JobOption
	// entry is still in the scheduler.
	current bool
}

// NewWatch is a watch for one scheduler: tag is the integration's
// ("robfig-cron"), app the app's name for its tag ("" for AppName()), and
// scheduler how messages name the scheduler ("robfig/cron").
func NewWatch(cw *cronwatch.Client, tag, app, scheduler string) *Watch {
	if app == "" {
		app = AppName()
	}
	w := &Watch{cw: cw, tag: tag, appTag: AppTag(tag, app), scheduler: scheduler, jobs: map[string]*declared{}, fallback: map[string]*cronwatch.Job{}, reported: map[string]bool{}, pending: map[string]bool{}}
	w.settled = sync.NewCond(&w.mu)
	return w
}

// saveTimeout bounds one write of a declaration to the store.
const saveTimeout = 30 * time.Second

// save writes name's declaration to the store in the background: a process
// that only schedules (an Asynq scheduler, say, whose server runs in
// another process) neither runs nor checks, and a declaration kept only in
// memory would never reach the processes that do. Writes run in turn, one
// goroutine at a time, each the client's declaration as it is then.
func (w *Watch) save(name string) {
	w.mu.Lock()
	defer w.mu.Unlock()
	w.pending[name] = true
	if w.saving {
		return
	}
	w.saving = true
	go w.saveAll()
}

func (w *Watch) saveAll() {
	for {
		w.mu.Lock()
		if len(w.pending) == 0 {
			w.saving = false
			w.settled.Broadcast()
			w.mu.Unlock()
			return
		}
		names := make([]string, 0, len(w.pending))
		for name := range w.pending {
			names = append(names, name)
		}
		clear(w.pending)
		w.mu.Unlock()
		slices.Sort(names)
		defined := map[string]bool{}
		for _, def := range w.cw.DefinedJobs() {
			defined[def.Name()] = true
		}
		for _, name := range names {
			if !defined[name] {
				continue // forgotten since
			}
			ctx, cancel := context.WithTimeout(context.Background(), saveTimeout)
			if _, err := w.cw.SyncJob(ctx, name); err != nil {
				w.cw.ReportError(err, "declaring "+name)
			}
			cancel()
		}
	}
}

// Settle waits until what Declare declared has been written to the store,
// for tests and a clean exit.
func (w *Watch) Settle() {
	w.mu.Lock()
	defer w.mu.Unlock()
	for w.saving {
		w.settled.Wait()
	}
}

// Client is the client the watch declares jobs on.
func (w *Watch) Client() *cronwatch.Client { return w.cw }

// Tag is the integration's tag, and AppTag the app's under it.
func (w *Watch) Tag() string { return w.tag }

// AppTag is the app's tag under the integration's.
func (w *Watch) AppTag() string { return w.appTag }

// ReportOnce hands err to the client's error handler the first time this
// process sees its message for that where.
func (w *Watch) ReportOnce(err error, where string) {
	key := where + "\x00" + err.Error()
	w.mu.Lock()
	seen := w.reported[key]
	w.reported[key] = true
	w.mu.Unlock()
	if !seen {
		w.cw.ReportError(err, where)
	}
}

// Job is the job declared under name, or nil.
func (w *Watch) Job(name string) *cronwatch.Job {
	w.mu.Lock()
	defer w.mu.Unlock()
	if d, ok := w.jobs[name]; ok {
		return d.job
	}
	return nil
}

// Declare declares every entry the scheduler has now, one job per name,
// and declares again without its schedule a job this watch declared whose
// entries are all gone. Several entries of one name on different schedules
// are one job without a schedule, reported once. Each job is tagged with
// the integration's tag and the app's. A declaration that has not changed
// is left alone; one the client refuses is reported, as is each entry's
// Problem, once.
func (w *Watch) Declare(entries []Entry) {
	w.declaring.Lock()
	defer w.declaring.Unlock()
	var order []string
	byName := map[string][]Entry{}
	for _, e := range entries {
		if _, ok := byName[e.Name]; !ok {
			order = append(order, e.Name)
		}
		byName[e.Name] = append(byName[e.Name], e)
	}
	w.mu.Lock()
	if len(entries) > 0 {
		w.seen = true
	}
	for _, d := range w.jobs {
		d.current = false
	}
	w.mu.Unlock()

	for _, name := range order {
		group := byName[name]
		first := group[0]
		sched, zone := first.Schedule, first.Timezone
		var times []string
		for _, e := range group {
			if e.Problem != nil {
				w.ReportOnce(e.Problem, "declaring "+e.Where)
			}
			text := e.Schedule
			if e.Timezone != "" {
				text += " in " + e.Timezone
			}
			if text == "" {
				text = "no schedule"
			}
			if !slices.Contains(times, text) {
				times = append(times, text)
			}
		}
		if len(times) > 1 {
			sched, zone = "", ""
			w.ReportOnce(fmt.Errorf("cronwatch: %s is run by %d %s entries on different schedules (%s), so it is watched without a schedule; give each a name of its own",
				js.Quote(name), len(group), w.scheduler, strings.Join(times, "; ")), "declaring "+first.Where)
		}
		options := slices.Clone(first.Defaults)
		if sched != "" {
			options = append(options, cronwatch.Schedule(sched))
			if zone != "" {
				options = append(options, cronwatch.Timezone(zone))
			}
		}
		options = append(options, first.Options...)
		w.declare(name, first.Where, w.tagged(name, options), true)
	}

	// Jobs whose entries are gone keep their runs and lose their schedule.
	w.mu.Lock()
	var gone []string
	for name, d := range w.jobs {
		if !d.current && d.job.Definition().Schedule() != "" {
			gone = append(gone, name)
		}
	}
	w.mu.Unlock()
	slices.Sort(gone)
	for _, name := range gone {
		w.mu.Lock()
		def := w.jobs[name].job.Definition()
		w.mu.Unlock()
		w.declare(name, js.Quote(name), Unscheduled(def), false)
	}
}

// tagged is options with the integration's and the app's tags added to
// the ones the options give.
func (w *Watch) tagged(name string, options []cronwatch.JobOption) []cronwatch.JobOption {
	tags := cronwatch.DescribeJob(name, options...).Tags()
	for _, t := range []string{w.tag, w.appTag} {
		if !slices.Contains(tags, t) {
			tags = append(tags, t)
		}
	}
	return append(slices.Clone(options), cronwatch.Tags(tags...))
}

func (w *Watch) declare(name, where string, options []cronwatch.JobOption, current bool) {
	key := js.Stringify(cronwatch.DescribeJob(name, options...))
	w.mu.Lock()
	d, ok := w.jobs[name]
	// Unchanged, and still declared: a job forgotten since (the dashboard's
	// forget) is declared again, or its next run would write it back and
	// Unschedule take it for an entry gone.
	if ok && d.key == key && w.cw.Declares(name) {
		d.current = d.current || current
		w.mu.Unlock()
		return
	}
	w.mu.Unlock()
	job, err := w.cw.Job(name, options...)
	if err != nil {
		w.ReportOnce(err, "declaring "+where)
		return
	}
	w.mu.Lock()
	if d, ok := w.jobs[name]; ok {
		d.job, d.key, d.options, d.current = job, key, options, d.current || current
	} else {
		w.jobs[name] = &declared{job: job, key: key, options: options, current: current}
	}
	w.mu.Unlock()
	w.save(name)
}

// kept are the options a job keeps when it is declared again without its
// schedule, as the PHP port keeps them.
var kept = []string{"tags", "grace", "timeout", "maxDuration", "budget", "floor", "failuresBeforeAlert"}

// Unscheduled is the options that declare a job again without its
// schedule: its description with " (no longer scheduled)", its tags,
// grace, timeout, maxDuration, budget, floor, and failuresBeforeAlert.
func Unscheduled(def cronwatch.Definition) []cronwatch.JobOption {
	description := def.Description()
	if description == "" {
		description = "A scheduled task"
	}
	if !strings.HasSuffix(description, " (no longer scheduled)") {
		description += " (no longer scheduled)"
	}
	options := []cronwatch.JobOption{cronwatch.Description(description)}
	for _, key := range kept {
		value, ok := def.Get(key)
		if !ok {
			continue
		}
		switch key {
		case "tags":
			options = append(options, cronwatch.Tags(def.Tags()...))
		case "grace":
			options = appendDuration(options, cronwatch.Grace[string], cronwatch.Grace[float64], value)
		case "timeout":
			options = appendDuration(options, cronwatch.Timeout[string], cronwatch.Timeout[float64], value)
		case "maxDuration":
			options = appendDuration(options, cronwatch.MaxDuration[string], cronwatch.MaxDuration[float64], value)
		case "budget":
			// Read from the definition's own object, which keeps the order
			// the metrics were given in.
			raw, _ := js.ValueOf(def).(*js.Object).Get("budget")
			if budget, ok := raw.(*js.Object); ok {
				for _, metric := range budget.Keys() {
					v, _ := budget.Get(metric)
					if ceiling, ok := v.(float64); ok {
						options = append(options, cronwatch.Budget(metric, ceiling))
					}
				}
			}
		case "floor":
			raw, _ := js.ValueOf(def).(*js.Object).Get("floor")
			if floor, ok := raw.(*js.Object); ok {
				for _, metric := range floor.Keys() {
					v, _ := floor.Get(metric)
					if limit, ok := v.(float64); ok {
						options = append(options, cronwatch.Floor(metric, limit))
					}
				}
			}
		case "failuresBeforeAlert":
			if n, ok := value.(float64); ok {
				options = append(options, cronwatch.FailuresBeforeAlert(int(n)))
			}
		}
	}
	return options
}

// appendDuration adds a duration option as it was stored: text as text, a
// number of milliseconds as a number.
func appendDuration(options []cronwatch.JobOption, text func(string) cronwatch.JobOption, number func(float64) cronwatch.JobOption, value any) []cronwatch.JobOption {
	switch v := value.(type) {
	case string:
		return append(options, text(v))
	case float64:
		return append(options, number(v))
	}
	return options
}

// Unschedule declares again without its schedule every job of this app's
// (tagged with its app tag) that the store holds with a schedule and this
// process has not declared: a scheduler entry taken out since the job was
// declared, by this process or an earlier one, so it is never reported
// missed and a missed alert already open closes. Call it just before a
// check. A process that never declared an entry of this scheduler leaves
// every job alone. Returns the names declared again.
func (w *Watch) Unschedule(ctx context.Context) ([]string, error) {
	w.mu.Lock()
	seen := w.seen
	w.mu.Unlock()
	if !seen {
		return nil, nil
	}
	// A job whose entry the scheduler still has, forgotten since (the
	// dashboard's forget), is declared again first, so it keeps its
	// schedule rather than being taken for an entry gone.
	w.declaring.Lock()
	w.mu.Lock()
	mine := make([]string, 0, len(w.jobs))
	var forgotten []string
	for name, d := range w.jobs {
		mine = append(mine, name)
		if d.current && !w.cw.Declares(name) {
			forgotten = append(forgotten, name)
		}
	}
	w.mu.Unlock()
	slices.Sort(forgotten)
	for _, name := range forgotten {
		w.mu.Lock()
		d := w.jobs[name]
		where, options, key := js.Quote(name), d.options, d.key
		w.mu.Unlock()
		job, err := w.cw.Job(name, options...)
		if err != nil {
			w.ReportOnce(err, "declaring "+where)
			continue
		}
		w.mu.Lock()
		if d := w.jobs[name]; d != nil && d.key == key {
			d.job = job
		}
		w.mu.Unlock()
	}
	w.declaring.Unlock()
	// This process's own declarations are written back where the store
	// holds something else: another process of the app (an older release
	// still up during a deploy) may have taken the schedule out of a job it
	// does not run, and a long-running process would otherwise never put
	// it back.
	defined := map[string]bool{}
	for _, def := range w.cw.DefinedJobs() {
		defined[def.Name()] = true
	}
	slices.Sort(mine)
	var failed []error
	for _, name := range mine {
		if !defined[name] {
			continue // forgotten (the dashboard's forget) since
		}
		if _, err := w.cw.SyncJob(ctx, name); err != nil {
			failed = append(failed, fmt.Errorf("declaring %s: %w", name, err))
		}
	}
	stored, err := w.cw.Jobs(ctx)
	if err != nil {
		return nil, errors.Join(append(failed, err)...)
	}
	// In turn with Declare and Fallback, and with what is declared read
	// again: a job declared since the first read (a scheduler entry added
	// while the store was read) must keep its schedule.
	w.declaring.Lock()
	clear(defined)
	for _, def := range w.cw.DefinedJobs() {
		defined[def.Name()] = true
	}
	var names []string
	for _, job := range stored {
		def := job.Definition
		if defined[job.Name] || def.Schedule() == "" || !slices.Contains(def.Tags(), w.appTag) {
			continue
		}
		if _, err := w.cw.Job(job.Name, Unscheduled(def)...); err != nil {
			failed = append(failed, fmt.Errorf("declaring %s: %w", job.Name, err))
			continue
		}
		names = append(names, job.Name)
	}
	w.declaring.Unlock()
	// Written before returning, and in order with this call's other
	// writes: a process that never checks would otherwise leave the
	// schedule in the store, and a write left to run behind could land
	// after another process has put the schedule back. SyncJob writes
	// what is declared at the time, so a job declared again since keeps
	// its schedule.
	for _, name := range names {
		if _, err := w.cw.SyncJob(ctx, name); err != nil {
			failed = append(failed, fmt.Errorf("declaring %s: %w", name, err))
		}
	}
	return names, errors.Join(failed...)
}
