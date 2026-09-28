// Package robfigcron watches a robfig/cron v3 scheduler with CronWatch:
// every entry is a job with its spec as the schedule, and every run is
// recorded, with one option given to cron.New.
//
//	cw, _ := cronwatch.New(cronwatch.WithStore(store))
//	c := cron.New(robfigcron.Watch(cw, robfigcron.Options{}))
//	c.AddFunc("0 2 * * *", jobs.NightlyReport) // the job "jobs.NightlyReport"
//	c.Start()
//	cw.Start(time.Minute) // checks for missed and stuck runs
//
// Watch installs a JobWrapper that records each run (a panic is a failed
// run, and carries on to the wrappers outside it, such as cron.Recover)
// and a Logger that hears the cron start and entries being added and
// removed, so entries added or removed later are followed: an entry's job
// is declared with its schedule, and a job whose entries are all gone is
// declared again without one, so it is never reported missed. Give your own
// wrappers and logger to Options (Chain, Logger): a cron.WithChain or
// cron.WithLogger given to cron.New after Watch replaces CronWatch's.
//
// # Names
//
// A job is named, in order: by Named (or Watcher.Func), which also gives it
// options; else after the function a FuncJob holds, without its package's
// path ("jobs.NightlyReport", a method value "jobs.Reporter.Run"); else
// after the job's type ("jobs.Nightly" for a *jobs.Nightly). A function
// literal has no stable name and is not watched until it is given one with
// Named, and is reported once. Options.Jobs gives options by name, and
// Options.Exclude leaves names out.
//
// # Schedules
//
// A spec is read from the schedule robfig/cron parsed (standard five
// fields, a seconds field with a seconds parser, descriptors such as
// @daily, CRON_TZ=), in its zone, else the cron's Location: see Convert.
// @every is "every <interval>". A schedule CronWatch would expect at
// other times than robfig/cron runs it (a time daylight saving skips, a
// zone that is not an IANA zone, a custom Schedule) is reported once to
// the client's error handler and the job is watched without a schedule.
//
// A robfig/cron job has no context and returns nothing, so a run fails
// only by panicking and cronwatch.Current is nil inside it. Watcher.Func
// makes a job from a cronwatch.JobFunc, which gets the run's context and
// JobContext and fails the run by returning an error.
//
// Jobs are tagged "robfig-cron" and "robfig-cron:<app>", the app named by
// Options.App, else bridge.AppName() ($CRONWATCH_APP_ID, else the
// executable's name), so two apps sharing a store never declare each
// other's jobs without a schedule.
package robfigcron

import (
	"context"
	"errors"
	"fmt"
	"slices"
	"sync"

	cronwatch "cronwatch.dev/go"
	"cronwatch.dev/go/bridge"
	"github.com/robfig/cron/v3"
)

// Tag is the tag every job this package declares carries, and Trigger its
// runs' trigger.
const (
	Tag     = "robfig-cron"
	Trigger = "robfig-cron"
)

// Options configure a Watcher.
type Options struct {
	// App names the app in its tag. Default bridge.AppName().
	App string
	// Defaults are job options for every job, before a job's own.
	Defaults []cronwatch.JobOption
	// Jobs are job options by job name. A Schedule among them replaces
	// the entry's.
	Jobs map[string][]cronwatch.JobOption
	// Exclude leaves jobs out by name: they are not declared from the
	// cron's entries and their runs are not recorded, except a
	// Watcher.Func's, which records its own runs (without a schedule).
	Exclude []string
	// Chain are the cron's own JobWrappers, outside CronWatch's, so one
	// that skips a run (cron.SkipIfStillRunning) records nothing and one
	// that recovers panics (cron.Recover) sees them after the run is
	// recorded.
	Chain []cron.JobWrapper
	// Logger is the cron's logger. Default cron.DefaultLogger.
	Logger cron.Logger
}

// Watcher watches one cron. Safe for use by many goroutines at once.
type Watcher struct {
	cw      *cronwatch.Client
	watch   *bridge.Watch
	options Options

	mu      sync.Mutex
	cron    *cron.Cron
	wrapped int
	pending bool
	again   bool
	idle    *sync.Cond
}

// New makes a Watcher; give its Option to cron.New.
func New(cw *cronwatch.Client, options Options) *Watcher {
	w := &Watcher{cw: cw, watch: bridge.NewWatch(cw, Tag, options.App, "robfig/cron"), options: options}
	w.idle = sync.NewCond(&w.mu)
	return w
}

// Watch is New(cw, options).Option(), for cron.New.
func Watch(cw *cronwatch.Client, options Options) cron.Option { return New(cw, options).Option() }

// Option is the cron.Option that attaches the watcher to the cron it is
// given to: CronWatch's JobWrapper inside Options.Chain, and a Logger
// around Options.Logger. A Watcher watches one cron; given to a second, it
// reports that and leaves the second alone.
func (w *Watcher) Option() cron.Option {
	return func(c *cron.Cron) {
		w.mu.Lock()
		taken := w.cron != nil && w.cron != c
		if !taken {
			w.cron = c
		}
		w.mu.Unlock()
		if taken {
			w.cw.ReportError(errors.New("a robfigcron.Watcher watches one cron; make another with robfigcron.New for this one"), "robfig/cron")
			return
		}
		inner := w.options.Logger
		if inner == nil {
			inner = cron.DefaultLogger
		}
		cron.WithLogger(logger{w: w, inner: inner})(c)
		cron.WithChain(append(slices.Clone(w.options.Chain), w.wrap)...)(c)
	}
}

// logger is the cron's logger, passing everything on, that starts a sync
// when the cron starts and when an entry is added or removed. The cron
// logs from its own goroutine while it holds its lock, so the sync runs in
// another.
type logger struct {
	w     *Watcher
	inner cron.Logger
}

func (l logger) Info(msg string, keysAndValues ...any) {
	l.inner.Info(msg, keysAndValues...)
	switch msg {
	case "start", "added", "removed":
		l.w.later()
	}
}

func (l logger) Error(err error, msg string, keysAndValues ...any) {
	l.inner.Error(err, msg, keysAndValues...)
}

// later syncs in a goroutine of its own, once more if asked again while one
// is under way.
func (w *Watcher) later() {
	w.mu.Lock()
	if w.pending {
		w.again = true
		w.mu.Unlock()
		return
	}
	w.pending = true
	w.mu.Unlock()
	go func() {
		for {
			if err := w.Sync(context.Background()); err != nil {
				w.cw.ReportError(err, "robfig/cron")
			}
			w.mu.Lock()
			if !w.again {
				w.pending = false
				w.idle.Broadcast()
				w.mu.Unlock()
				return
			}
			w.again = false
			w.mu.Unlock()
		}
	}()
}

// Wait waits for the syncs the cron's events started to finish, for tests
// and for a clean exit.
func (w *Watcher) Wait() {
	w.mu.Lock()
	for w.pending {
		w.idle.Wait()
	}
	w.mu.Unlock()
}

// Sync declares the cron's entries now: each entry's job with its schedule,
// and again without its schedule each job of this app's whose entries are
// gone (this process's, and those an earlier process declared). It runs by
// itself when the cron starts and when an entry is added or removed; call
// it to declare the entries of a cron that is not started.
func (w *Watcher) Sync(ctx context.Context) error {
	w.mu.Lock()
	c, wrapped := w.cron, w.wrapped
	w.mu.Unlock()
	if c == nil {
		return errors.New("the watcher was not given to cron.New; pass robfigcron.Watch(cw, options) or watcher.Option() to it")
	}
	entries := c.Entries()
	if len(entries) > 0 && wrapped == 0 {
		w.watch.ReportOnce(errors.New("the cron's jobs are not wrapped by CronWatch, so no run is recorded: a cron.WithChain given to cron.New after robfigcron.Watch replaced its wrapper; give your wrappers in robfigcron.Options.Chain"), "robfig/cron")
	}
	var found []bridge.Entry
	for _, entry := range entries {
		name, own, err := nameOf(entry.Job)
		where := fmt.Sprintf("robfig/cron entry %d", entry.ID)
		if err != nil {
			w.watch.ReportOnce(fmt.Errorf("cronwatch: %s %v", where, err), "declaring "+where)
			continue
		}
		if slices.Contains(w.options.Exclude, name) {
			continue
		}
		where += " (" + name + ")"
		options := slices.Concat(w.options.Jobs[name], own)
		e := bridge.Entry{Name: name, Where: where, Defaults: w.options.Defaults, Options: options}
		if converted, err := Convert(entry.Schedule, c.Location(), "cronwatch: "+where); err != nil {
			e.Problem = err
		} else {
			e.Schedule, e.Timezone = converted.Schedule, converted.Timezone
		}
		found = append(found, e)
	}
	w.watch.Declare(found)
	_, err := w.watch.Unschedule(ctx)
	return err
}

// wrap is CronWatch's JobWrapper: each run of a watched job is recorded.
func (w *Watcher) wrap(job cron.Job) cron.Job {
	w.mu.Lock()
	w.wrapped++
	w.mu.Unlock()
	if _, ok := job.(*funcJob); ok {
		return job // records its own runs
	}
	name, _, err := nameOf(job)
	return cron.FuncJob(func() {
		var watched *cronwatch.Job
		if err == nil {
			watched = w.jobFor(name)
		}
		if watched == nil {
			job.Run()
			return
		}
		_ = watched.Run(context.Background(), func(context.Context, *cronwatch.JobContext) error {
			job.Run()
			return nil
		}, cronwatch.WithTrigger(Trigger))
	})
}

// jobFor is the job declared for name, syncing first when it is not
// declared yet (an entry added while the cron runs, before the sync its
// event started); nil for a name left out.
func (w *Watcher) jobFor(name string) *cronwatch.Job {
	if name == "" || slices.Contains(w.options.Exclude, name) {
		return nil
	}
	if job := w.watch.Job(name); job != nil {
		return job
	}
	if err := w.Sync(context.Background()); err != nil {
		w.cw.ReportError(err, "robfig/cron")
	}
	return w.watch.Job(name)
}

// funcJob is a job made by Watcher.Func.
type funcJob struct {
	w       *Watcher
	name    string
	fn      cronwatch.JobFunc
	options []cronwatch.JobOption

	// own is the job declared for a Func outside the cron's entries.
	once   sync.Once
	own    *cronwatch.Job
	ownErr error
}

// Func is a robfig/cron job from a cronwatch.JobFunc, named name and given
// options: it gets the run's context (cancelled at the job's timeout) and
// JobContext, logs and reports metrics, and fails the run by returning an
// error. It records its own runs, even in a cron that is not watched.
//
//	c.AddJob("0 2 * * *", w.Func("nightly-report", func(ctx context.Context, job *cronwatch.JobContext) error {
//		job.Log("Report written")
//		return nil
//	}, cronwatch.Grace("15m")))
func (w *Watcher) Func(name string, fn cronwatch.JobFunc, options ...cronwatch.JobOption) cron.Job {
	return &funcJob{w: w, name: name, fn: fn, options: options}
}

func (f *funcJob) Run() {
	job := f.w.jobFor(f.name)
	if job == nil {
		// Not an entry of the watched cron, or left out by Exclude: declared
		// on its own, without a schedule, so its runs are still recorded.
		f.once.Do(func() {
			f.own, f.ownErr = f.w.cw.Job(f.name, slices.Concat(f.w.options.Defaults, f.w.options.Jobs[f.name], f.options)...)
		})
		made, err := f.own, f.ownErr
		if err != nil {
			// A name or option CronWatch refuses: the function still runs,
			// with no JobContext.
			f.w.watch.ReportOnce(err, "declaring "+f.name)
			_ = f.fn(context.Background(), nil)
			return
		}
		job = made
	}
	_ = job.Run(context.Background(), f.fn, cronwatch.WithTrigger(Trigger))
}
