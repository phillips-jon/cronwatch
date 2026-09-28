// Package gocron watches a go-co-op/gocron v2 scheduler with CronWatch:
// every job is a CronWatch job with its definition as the schedule, and
// every run is recorded through gocron's event listeners, with one option
// given to gocron.NewScheduler. Import it under a name of its own beside
// gocron:
//
//	import (
//		"github.com/go-co-op/gocron/v2"
//		cwgocron "cronwatch.dev/go/gocron"
//	)
//
//	s, _ := gocron.NewScheduler(cwgocron.Watch(cw, cwgocron.Options{}))
//	s.NewJob(gocron.CronJob("0 2 * * *", false), gocron.NewTask(jobs.NightlyReport))
//	s.Start()
//	cw.Start(time.Minute) // checks for missed and stuck runs
//
// Watch adds gocron's BeforeJobRuns, AfterJobRuns, AfterJobRunsWithError
// and AfterJobRunsWithPanic listeners to every job (WithGlobalJobOptions):
// a run starts when gocron is about to run the job and ends with its
// outcome, an error failing it. A panic fails the run and then carries on
// as it would without CronWatch (gocron recovers a panic only for a job
// with a panic listener, so CronWatch's panics again). A job that sets its
// own listener of one of these kinds (gocron keeps one of each per job)
// replaces CronWatch's for that job. A run gocron skips (singleton mode, a
// distributed lock held elsewhere) records nothing and may be reported
// missed. gocron gives a task no CronWatch context, so cronwatch.Current is
// nil inside it and a run's output is empty; wrap the work in job.Run
// yourself when it should log.
//
// # Names
//
// A job is named after gocron's name for it (gocron.WithName), without a
// package's path when it is a function's name, which gocron uses when no
// name is given ("jobs.NightlyReport"). A function literal has no stable
// name and is not watched until it is given one with gocron.WithName, and
// is reported once, as is a name CronWatch does not take. Options.Jobs
// gives options by name, and Options.Exclude leaves names out.
//
// # Schedules
//
// A job's definition is read from Job.Schedule() (gocron 2.21 or newer) and
// converted where it maps exactly (see Convert): a cron job, a duration
// job, and daily, weekly and monthly jobs of an interval of 1. Anything
// else is watched without a schedule and reported once. The zone is the
// scheduler's (gocron.WithLocation), read from a job's next run once the
// scheduler has started, else Options.Location, else time.Local, gocron's
// default. A job added, updated or removed later is followed: added or
// updated at once, removed at the next sync (the next run of any job, or
// Sync), when its job is declared again without its schedule so it is never
// reported missed.
//
// gocron's options that change when a job runs without showing in its
// definition are not seen: WithIntervalFromCompletion (a duration counted
// from the end of the last run, where CronWatch counts from its start),
// WithStartAt, WithStopAt, and a daylight saving policy other than the
// default (a cron job's time in a gap is then refused rather than read).
//
// Jobs are tagged "gocron" and "gocron:<app>", the app named by Options.App,
// else bridge.AppName(), so two apps sharing a store never declare each
// other's jobs without a schedule.
package gocron

import (
	"context"
	"errors"
	"fmt"
	"reflect"
	"slices"
	"sync"
	"time"

	cronwatch "cronwatch.dev/go"
	"cronwatch.dev/go/bridge"
	"github.com/go-co-op/gocron/v2"
	"github.com/google/uuid"
)

// Tag is the tag every job this package declares carries, and Trigger its
// runs' trigger.
const (
	Tag     = "gocron"
	Trigger = "gocron"
)

// settle is how long a sync waits after a job is added, so the scheduler
// holds it when the sync asks for its jobs.
var settle = 100 * time.Millisecond

// Options configure a Watcher.
type Options struct {
	// App names the app in its tag. Default bridge.AppName().
	App string
	// Defaults are job options for every job, before its schedule.
	Defaults []cronwatch.JobOption
	// Jobs are job options by job name, after its schedule: a Schedule
	// among them replaces the job's.
	Jobs map[string][]cronwatch.JobOption
	// Exclude leaves jobs out by name.
	Exclude []string
	// Location is the scheduler's zone (gocron.WithLocation), for jobs
	// declared before the scheduler starts. Default time.Local.
	Location *time.Location
}

// Watcher watches one gocron scheduler. Safe for use by many goroutines
// at once.
type Watcher struct {
	cw      *cronwatch.Client
	watch   *bridge.Watch
	options Options

	mu        sync.Mutex
	scheduler gocron.Scheduler
	loc       *time.Location
	running   map[uuid.UUID][]*cronwatch.RunHandle
	pending   bool
	again     bool
	idle      *sync.Cond
}

// New makes a Watcher; give its Option to gocron.NewScheduler.
func New(cw *cronwatch.Client, options Options) *Watcher {
	w := &Watcher{cw: cw, watch: bridge.NewWatch(cw, Tag, options.App, "gocron"), options: options,
		running: map[uuid.UUID][]*cronwatch.RunHandle{}}
	w.idle = sync.NewCond(&w.mu)
	return w
}

// Watch is New(cw, options).Option(), for gocron.NewScheduler.
func Watch(cw *cronwatch.Client, options Options) gocron.SchedulerOption {
	return New(cw, options).Option()
}

// Option is the gocron.SchedulerOption that attaches the watcher to the
// scheduler it is given to, adding CronWatch's listeners to every job as a
// global job option. A Watcher watches one scheduler; given to a second,
// it reports that and leaves the second alone.
func (w *Watcher) Option() gocron.SchedulerOption {
	global := gocron.WithGlobalJobOptions(w.jobOption())
	// A SchedulerOption takes gocron's unexported scheduler, which is a
	// gocron.Scheduler; the option is made through reflect to keep hold of
	// it, so Watch is the one line an app adds.
	t := reflect.TypeOf(global)
	made := reflect.MakeFunc(t, func(args []reflect.Value) []reflect.Value {
		s, _ := args[0].Interface().(gocron.Scheduler)
		w.mu.Lock()
		taken := w.scheduler != nil && w.scheduler != s
		if !taken {
			w.scheduler = s
		}
		w.mu.Unlock()
		if taken {
			w.cw.ReportError(errors.New("a gocron watcher watches one scheduler; make another with cwgocron.New for this one"), "gocron")
			return []reflect.Value{reflect.Zero(t.Out(0))}
		}
		return reflect.ValueOf(global).Call(args)
	})
	return made.Interface().(gocron.SchedulerOption)
}

// jobOption is CronWatch's listeners, as a job option that also starts a
// sync, since gocron applies it to each job added or updated.
func (w *Watcher) jobOption() gocron.JobOption {
	listeners := gocron.WithEventListeners(
		gocron.BeforeJobRuns(w.before),
		gocron.AfterJobRuns(w.after),
		gocron.AfterJobRunsWithError(w.failed),
		gocron.AfterJobRunsWithPanic(w.panicked),
	)
	t := reflect.TypeOf(listeners)
	return reflect.MakeFunc(t, func(args []reflect.Value) []reflect.Value {
		w.later()
		return reflect.ValueOf(listeners).Call(args)
	}).Interface().(gocron.JobOption)
}

// later syncs in a goroutine of its own, once the scheduler holds the job
// being added, and once more if asked again meanwhile.
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
			time.Sleep(settle)
			if err := w.Sync(context.Background()); err != nil {
				w.cw.ReportError(err, "gocron")
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

// Wait waits for the syncs the scheduler's events started to finish, for
// tests and for a clean exit.
func (w *Watcher) Wait() {
	w.mu.Lock()
	for w.pending {
		w.idle.Wait()
	}
	w.mu.Unlock()
}

// Sync declares the scheduler's jobs now: each with its schedule, and again
// without its schedule each job of this app's that is gone (this
// process's, and those an earlier process declared).
func (w *Watcher) Sync(ctx context.Context) error {
	w.mu.Lock()
	s := w.scheduler
	w.mu.Unlock()
	if s == nil {
		return errors.New("the watcher was not given to gocron.NewScheduler; pass cwgocron.Watch(cw, options) or watcher.Option() to it")
	}
	jobs := s.Jobs()
	loc := w.location(jobs)
	var found []bridge.Entry
	for _, job := range jobs {
		name, err := bridge.FuncName(job.Name())
		where := fmt.Sprintf("gocron job %s", job.ID())
		if err != nil {
			w.watch.ReportOnce(fmt.Errorf("cronwatch: %s %v; give it a name with gocron.WithName", where, err), "declaring "+where)
			continue
		}
		if slices.Contains(w.options.Exclude, name) {
			continue
		}
		where += " (" + name + ")"
		e := bridge.Entry{Name: name, Where: where, Defaults: w.options.Defaults, Options: w.options.Jobs[name]}
		if converted, err := Convert(job.Schedule(), loc, "cronwatch: "+where); err != nil {
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

// location is the scheduler's zone: a job's next run is given in it once
// the scheduler has started.
func (w *Watcher) location(jobs []gocron.Job) *time.Location {
	w.mu.Lock()
	known := w.loc
	w.mu.Unlock()
	if known != nil {
		return known
	}
	for _, job := range jobs {
		if next, err := job.NextRun(); err == nil && !next.IsZero() {
			loc := next.Location()
			if given := w.options.Location; given != nil && given.String() != loc.String() {
				w.watch.ReportOnce(fmt.Errorf("the gocron scheduler runs in %s, not %s as cwgocron.Options.Location says; its jobs are read in %s", loc, given, loc), "gocron")
			}
			w.mu.Lock()
			w.loc = loc
			w.mu.Unlock()
			return loc
		}
	}
	if w.options.Location != nil {
		return w.options.Location
	}
	return time.Local
}

// job is the CronWatch job a gocron run belongs to, or nil for one left
// out. A job not declared yet (added a moment ago) is declared from what
// the store holds, else without a schedule, until the sync this starts
// gives it its own.
func (w *Watcher) job(name string) *cronwatch.Job {
	clean, err := bridge.FuncName(name)
	if err != nil || slices.Contains(w.options.Exclude, clean) {
		return nil
	}
	if job := w.watch.Job(clean); job != nil {
		return job
	}
	w.later()
	return w.watch.Fallback(context.Background(), clean, slices.Concat(w.options.Defaults, w.options.Jobs[clean]))
}

func (w *Watcher) before(id uuid.UUID, name string) {
	job := w.job(name)
	if job == nil {
		return
	}
	handle, err := job.Start(context.Background(), cronwatch.WithTrigger(Trigger))
	if err != nil {
		w.cw.ReportError(err, "starting "+job.Name())
		return
	}
	w.mu.Lock()
	w.running[id] = append(w.running[id], handle)
	w.mu.Unlock()
}

// take is the oldest run of a job still going. gocron says only which job
// ended, so runs of one job at once are paired with their ends in order.
func (w *Watcher) take(id uuid.UUID) *cronwatch.RunHandle {
	w.mu.Lock()
	defer w.mu.Unlock()
	list := w.running[id]
	if len(list) == 0 {
		return nil
	}
	handle := list[0]
	if len(list) == 1 {
		delete(w.running, id)
	} else {
		w.running[id] = list[1:]
	}
	return handle
}

func (w *Watcher) after(id uuid.UUID, _ string) {
	if handle := w.take(id); handle != nil {
		handle.Finish(context.Background())
	}
}

func (w *Watcher) failed(id uuid.UUID, _ string, err error) {
	// gocron reports a panic to its panic listener and then as an error;
	// the panic listener has recorded it.
	if errors.Is(err, gocron.ErrPanicRecovered) {
		return
	}
	if handle := w.take(id); handle != nil {
		handle.Fail(context.Background(), err)
	}
}

// Panic is what a gocron job panicked with, as a run's error: "Panic: <value>".
type Panic struct{ Value any }

func (p Panic) Error() string { return fmt.Sprint(p.Value) }

func (w *Watcher) panicked(id uuid.UUID, _ string, recovered any) {
	if handle := w.take(id); handle != nil {
		handle.Fail(context.Background(), Panic{recovered})
	}
	// gocron recovered it only because CronWatch listens for panics: it
	// carries on as it would have without CronWatch.
	panic(recovered)
}
