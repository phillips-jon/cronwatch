// Package river watches River (riverqueue/river) with CronWatch: periodic
// jobs are CronWatch jobs with their schedules, and every attempt of a
// watched job is a run, through a worker middleware. Import it under a name
// of its own beside River:
//
//	import (
//		"github.com/riverqueue/river"
//		cwriver "cronwatch.dev/go/river"
//	)
//
//	w := cwriver.New(cw, cwriver.Options{})
//	nightly, _ := cron.ParseStandard("0 2 * * *") // github.com/robfig/cron/v3
//	workers := river.NewWorkers()
//	river.AddWorker(workers, &NightlyReportWorker{})
//	river.AddWorker(workers, w.CheckWorker())
//	client, _ := river.NewClient(riverpgxv5.New(pool), &river.Config{
//		Workers:    workers,
//		Middleware: []rivertype.Middleware{w.Middleware()},
//		PeriodicJobs: []*river.PeriodicJob{
//			w.PeriodicJob(nightly, func() (river.JobArgs, *river.InsertOpts) {
//				return NightlyReportArgs{}, nil
//			}, &river.PeriodicJobOpts{ID: "nightly-report"}, cronwatch.Grace("15m")),
//			w.CheckPeriodicJob(5 * time.Minute),
//		},
//	})
//
// # Periodic jobs
//
// w.PeriodicJob is river.NewPeriodicJob, taking the same arguments and
// CronWatch's job options after them, and declaring the job: named by the
// periodic job's ID, else by the kind of the args its constructor returns
// (the constructor is called once more to learn it), with its schedule
// read as CronWatch reads it: a robfig/cron schedule (cron.ParseStandard,
// the cron River's documentation uses) through robfigcron.Convert, checked
// against its own fire times in the process's zone, where River asks for
// them; river.PeriodicInterval, or any schedule a constant time apart, as
// "every <interval>"; anything else is reported once and the job watched
// without a schedule. The jobs it inserts carry the CronWatch job's name in
// their metadata ("cronwatch"), so whichever process works them records
// their runs under it. A periodic job no longer made (taken out of the
// config) is declared again without its schedule by the next Sync, which
// the check worker runs, so it is never reported missed.
//
// Periodic jobs changed while the client runs are followed through the
// watcher: one made again with the ID of an earlier one (after River's
// Remove or Clear, with a new schedule, say) replaces it, and one taken out
// of River's bundle is taken out here with w.Remove, w.RemoveByID or
// w.Clear, beside the bundle's own call:
//
//	client.PeriodicJobs().RemoveByID("nightly-report")
//	w.RemoveByID("nightly-report")
//
// The job then loses its schedule at once, so it is never reported missed.
//
// # Runs and retries
//
// The middleware records each attempt of a job that carries the metadata,
// and of the kinds Options.Kinds names, as a run (trigger "river"), with
// the job's context carrying the run's JobContext (cronwatch.Current).
// Retries follow the gem's Sidekiq rules: every attempt is a run, an
// attempt that returns an error (or panics, which River recovers) is a
// failed run with it, so failing attempts open one failed alert and the one
// that succeeds closes it, and FailuresBeforeAlert rides through retries.
// An attempt that snoozes (river.JobSnooze) or cancels itself
// (river.JobCancel), or is cancelled from outside, did not fail and did not
// do its work: its run is taken back (cronwatch.DiscardWhen), as the PHP
// port takes back a released Laravel job's, so nothing is judged, no alert
// is sent, and failures in a row are left as they were. A cancelled job
// that should have run is then reported missed by its schedule.
//
// # The check
//
// w.CheckWorker is a River worker for CheckArgs (kind "cronwatch_check")
// that syncs the periodic jobs and runs a check; w.CheckPeriodicJob(every)
// schedules it (five minutes is a good interval). Its runs are never jobs.
//
// Jobs are tagged "river" and "river:<app>", the app named by Options.App,
// else bridge.AppName(), so two apps sharing a store never declare each
// other's jobs without a schedule; every process of one app needs the same
// name and the same periodic jobs, as River asks every client to be
// configured with them.
package river

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"slices"
	"sync"
	"time"

	cronwatch "cronwatch.dev/go"
	"cronwatch.dev/go/bridge"
	"cronwatch.dev/go/robfigcron"
	"github.com/riverqueue/river"
	"github.com/riverqueue/river/rivertype"
	"github.com/robfig/cron/v3"
)

// Tag is the tag every job this package declares carries, Trigger its
// runs' trigger, and MetadataKey the key in a River job's metadata naming
// the CronWatch job it runs.
const (
	Tag         = "river"
	Trigger     = "river"
	MetadataKey = "cronwatch"
)

// Options configure a Watcher.
type Options struct {
	// App names the app in its tag. Default bridge.AppName().
	App string
	// Defaults are job options for every periodic job, before its schedule.
	Defaults []cronwatch.JobOption
	// Kinds watches jobs of these kinds that are not periodic, each attempt
	// a run of a job named after the kind, with these options.
	Kinds map[string][]cronwatch.JobOption
}

// Watcher watches one River app's periodic jobs and workers. Safe for use
// by many goroutines at once.
type Watcher struct {
	cw      *cronwatch.Client
	watch   *bridge.Watch
	options Options

	declaring sync.Mutex
	mu        sync.Mutex
	periodic  []periodic
}

// periodic is a periodic job this watcher declared.
type periodic struct {
	job   *river.PeriodicJob
	id    string
	entry bridge.Entry
}

// New makes a Watcher.
func New(cw *cronwatch.Client, options Options) *Watcher {
	return &Watcher{cw: cw, watch: bridge.NewWatch(cw, Tag, options.App, "River"), options: options}
}

// PeriodicJob is river.NewPeriodicJob, declaring the periodic job as a
// CronWatch job with its schedule and the options given, and marking the
// jobs it inserts so their runs are recorded under it (see the package's
// documentation).
func (w *Watcher) PeriodicJob(schedule river.PeriodicSchedule, constructor river.PeriodicJobConstructor, opts *river.PeriodicJobOpts, options ...cronwatch.JobOption) *river.PeriodicJob {
	name, where, err := periodicName(constructor, opts)
	if err != nil {
		w.watch.ReportOnce(fmt.Errorf("cronwatch: %s %v", where, err), "declaring "+where)
		return river.NewPeriodicJob(schedule, constructor, opts)
	}
	e := bridge.Entry{Name: name, Where: where, Defaults: w.options.Defaults, Options: options}
	if converted, err := Convert(schedule, "cronwatch: "+where); err != nil {
		e.Problem = err
	} else {
		e.Schedule, e.Timezone = converted.Schedule, converted.Timezone
	}
	job := river.NewPeriodicJob(schedule, marked(constructor, name), opts)
	id := ""
	if opts != nil {
		id = opts.ID
	}
	w.mu.Lock()
	// Made again with the ID of an earlier one: it replaces that one, as
	// River's bundle holds one periodic job per ID.
	if id != "" {
		w.periodic = slices.DeleteFunc(w.periodic, func(p periodic) bool { return p.id == id })
	}
	w.periodic = append(w.periodic, periodic{job: job, id: id, entry: e})
	w.mu.Unlock()
	w.declare()
	return job
}

// Remove takes periodic jobs made by PeriodicJob out of what the watcher
// declares, as River's client.PeriodicJobs().Remove takes them out of the
// client: each job no periodic job holds any more loses its schedule at
// once, so it is never reported missed.
func (w *Watcher) Remove(jobs ...*river.PeriodicJob) {
	w.drop(func(p periodic) bool { return slices.Contains(jobs, p.job) })
}

// RemoveByID is Remove for the periodic jobs of these IDs, as River's
// client.PeriodicJobs().RemoveByID.
func (w *Watcher) RemoveByID(ids ...string) {
	w.drop(func(p periodic) bool { return p.id != "" && slices.Contains(ids, p.id) })
}

// Clear is Remove for every periodic job, as River's
// client.PeriodicJobs().Clear. The check keeps running.
func (w *Watcher) Clear() {
	w.drop(func(periodic) bool { return true })
}

func (w *Watcher) drop(gone func(periodic) bool) {
	w.mu.Lock()
	w.periodic = slices.DeleteFunc(w.periodic, gone)
	w.mu.Unlock()
	w.declare()
}

// declare declares the periodic jobs held now (bridge.Watch.Declare), one
// call at a time, so an older list never lands after a newer one.
func (w *Watcher) declare() {
	w.declaring.Lock()
	defer w.declaring.Unlock()
	w.watch.Declare(w.entries())
}

func (w *Watcher) entries() []bridge.Entry {
	w.mu.Lock()
	defer w.mu.Unlock()
	entries := make([]bridge.Entry, len(w.periodic))
	for i, p := range w.periodic {
		entries[i] = p.entry
	}
	return entries
}

// periodicName is a periodic job's CronWatch name: its ID, else the kind
// of the args its constructor returns.
func periodicName(constructor river.PeriodicJobConstructor, opts *river.PeriodicJobOpts) (string, string, error) {
	if opts != nil && opts.ID != "" {
		where := fmt.Sprintf("River periodic job %q", opts.ID)
		if !bridge.ValidName(opts.ID) {
			return "", where, errors.New("has an ID that is not a CronWatch job name")
		}
		return opts.ID, where, nil
	}
	args, _ := constructor()
	if args == nil {
		return "", "River periodic job", errors.New("has no ID, and its constructor returned no args to name it after; give it an ID")
	}
	kind := args.Kind()
	where := fmt.Sprintf("River periodic job of kind %q", kind)
	if !bridge.ValidName(kind) {
		return "", where, errors.New("has a kind that is not a CronWatch job name; give it an ID")
	}
	return kind, where, nil
}

// marked is a constructor whose jobs carry the CronWatch job's name in
// their metadata, beside the metadata the constructor gives them.
func marked(constructor river.PeriodicJobConstructor, name string) river.PeriodicJobConstructor {
	return func() (river.JobArgs, *river.InsertOpts) {
		args, opts := constructor()
		if args == nil {
			return nil, opts
		}
		made := river.InsertOpts{}
		if opts != nil {
			made = *opts
		}
		var metadata map[string]json.RawMessage
		if len(made.Metadata) > 0 {
			// Metadata that is not an object is the app's own, left as it
			// is rather than replaced; the job's runs are then recorded
			// only by its kind (Options.Kinds).
			if json.Unmarshal(made.Metadata, &metadata) != nil {
				return args, opts
			}
		}
		if metadata == nil {
			metadata = map[string]json.RawMessage{} // none, or JSON null
		}
		metadata[MetadataKey], _ = json.Marshal(name)
		made.Metadata, _ = json.Marshal(metadata)
		return args, &made
	}
}

// Convert is a River periodic schedule as CronWatch reads it: a robfig/cron
// schedule through robfigcron.Convert in the process's zone (River asks it
// for fire times from time.Now()), and any schedule whose next fire is
// always the same time after the one asked from (river.PeriodicInterval)
// as "every <interval>". where names the job in the error.
func Convert(schedule river.PeriodicSchedule, where string) (robfigcron.Converted, error) {
	switch s := schedule.(type) {
	case nil:
		return robfigcron.Converted{}, bridge.Refuse("%s has no schedule", where)
	case cron.Schedule:
		switch s.(type) {
		case *cron.SpecSchedule, cron.ConstantDelaySchedule, *cron.ConstantDelaySchedule:
			return robfigcron.Convert(s, time.Local, where)
		}
	}
	if every, ok := constant(schedule); ok {
		if every < time.Second {
			return robfigcron.Converted{}, bridge.Refuse("%s runs every %s; CronWatch watches intervals of one second or more", where, every)
		}
		return robfigcron.Converted{Schedule: bridge.EveryText(every)}, nil
	}
	return robfigcron.Converted{}, bridge.Refuse("%s has a %T schedule, which CronWatch cannot read; give the job a schedule of its own", where, schedule)
}

// constant is the interval of a schedule whose next fire is always the
// same time after the time it is asked from.
func constant(schedule river.PeriodicSchedule) (time.Duration, bool) {
	base := time.Date(2026, 1, 1, 0, 0, 0, 0, time.UTC)
	var every time.Duration
	for i, offset := range []time.Duration{0, 1234567 * time.Microsecond, 37 * time.Hour, 97*24*time.Hour + 13*time.Minute + 7*time.Nanosecond, 3 * 365 * 24 * time.Hour} {
		from := base.Add(offset)
		d := schedule.Next(from).Sub(from)
		if d <= 0 || d > 100*365*24*time.Hour || (i > 0 && d != every) {
			return 0, false
		}
		every = d
	}
	return every, true
}

// Wait waits until the periodic jobs declared have been written to the
// store (which happens in the background, so a process that only inserts
// them still puts them where the workers and the check read them), for
// tests and for a clean exit.
func (w *Watcher) Wait() { w.watch.Settle() }

// Sync declares the periodic jobs made in this process again, and again
// without its schedule each job of this app's that no periodic job holds
// any more (taken out of the config since a process declared it). The
// check worker runs it before each check.
func (w *Watcher) Sync(ctx context.Context) error {
	w.declare()
	_, err := w.watch.Unschedule(ctx)
	return err
}

// Middleware is the worker middleware that records each attempt of a
// watched job as a run (see the package's documentation). Give it to
// river.Config's Middleware.
func (w *Watcher) Middleware() rivertype.WorkerMiddleware { return &middleware{w: w} }

type middleware struct {
	river.MiddlewareDefaults
	w *Watcher
}

func (m *middleware) Work(ctx context.Context, row *rivertype.JobRow, doInner func(context.Context) error) error {
	job := m.w.jobFor(ctx, row)
	if job == nil {
		return doInner(ctx)
	}
	// Given back without failing: a snooze, a cancel by the job, or a cancel
	// from outside, which River makes the context's cause.
	givenBack := func(err error) bool {
		var snooze *rivertype.JobSnoozeError
		var cancel *rivertype.JobCancelError
		return errors.As(err, &snooze) || errors.As(err, &cancel) || errors.Is(context.Cause(ctx), rivertype.ErrJobCancelledRemotely)
	}
	return job.Run(ctx, func(ctx context.Context, _ *cronwatch.JobContext) error {
		return doInner(ctx)
	}, cronwatch.WithTrigger(Trigger), cronwatch.DiscardWhen(givenBack))
}

// jobFor is the CronWatch job a River job's attempt is a run of, or nil.
func (w *Watcher) jobFor(ctx context.Context, row *rivertype.JobRow) *cronwatch.Job {
	if row.Kind == CheckKind {
		return nil
	}
	name := ""
	var metadata map[string]json.RawMessage
	if json.Unmarshal(row.Metadata, &metadata) == nil {
		_ = json.Unmarshal(metadata[MetadataKey], &name)
	}
	var options []cronwatch.JobOption
	if name == "" {
		kind, ok := w.options.Kinds[row.Kind]
		if !ok {
			return nil
		}
		name, options = row.Kind, kind
	}
	if job := w.watch.Job(name); job != nil {
		return job
	}
	// A job this process did not declare (a worker that makes no periodic
	// jobs, a kind watched by Kinds): declared from what the store holds
	// when it is this app's, so the schedule another process stored stays.
	// The store is read with the job's own context on purpose: River
	// bounds it by the worker's timeout, and a read cut short declares
	// nothing (this attempt goes unrecorded and the next asks again)
	// rather than write over the stored schedule.
	return w.watch.Fallback(ctx, name, options)
}

// CheckKind is the kind of CheckArgs.
const CheckKind = "cronwatch_check"

// CheckArgs are the args of the job that runs a CronWatch check.
type CheckArgs struct{}

// Kind is "cronwatch_check".
func (CheckArgs) Kind() string { return CheckKind }

// InsertOpts gives the check one attempt: a check that fails is repeated
// by the next one.
func (CheckArgs) InsertOpts() river.InsertOpts { return river.InsertOpts{MaxAttempts: 1} }

// CheckWorker works CheckArgs: it syncs the periodic jobs and runs a check.
type CheckWorker struct {
	river.WorkerDefaults[CheckArgs]
	w *Watcher
}

// CheckWorker is the worker for CheckArgs; add it with river.AddWorker.
func (w *Watcher) CheckWorker() *CheckWorker { return &CheckWorker{w: w} }

// Work syncs and checks, with the job's own context on purpose: River
// bounds it by the worker's timeout (a minute by default) and cancels it
// at shutdown, so neither needs a deadline of CronWatch's; the check a
// cancelled caller shared still runs to its end (see Client.Check).
func (c *CheckWorker) Work(ctx context.Context, _ *river.Job[CheckArgs]) error {
	if err := c.w.Sync(ctx); err != nil {
		c.w.cw.ReportError(err, "river")
	}
	_, err := c.w.cw.Check(ctx)
	return err
}

// CheckPeriodicJob is a periodic job that runs the check every interval
// (five minutes is a good one), inserted once for the whole deployment by
// River's leader.
func (w *Watcher) CheckPeriodicJob(every time.Duration) *river.PeriodicJob {
	return river.NewPeriodicJob(river.PeriodicInterval(every), func() (river.JobArgs, *river.InsertOpts) {
		return CheckArgs{}, nil
	}, &river.PeriodicJobOpts{ID: CheckKind})
}
