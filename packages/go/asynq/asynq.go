// Package asynq watches Asynq (hibiken/asynq) with CronWatch: the
// scheduler's entries are CronWatch jobs with their cronspecs as schedules,
// and every attempt of a watched task is a run, through a server
// middleware. Import it under a name of its own beside Asynq:
//
//	import (
//		"github.com/hibiken/asynq"
//		cwasynq "cronwatch.dev/go/asynq"
//	)
//
//	w := cwasynq.New(cw, cwasynq.Options{})
//
//	// The scheduler process: cwasynq's Scheduler is asynq's, declaring each entry.
//	scheduler := w.NewScheduler(redisOpt, &asynq.SchedulerOpts{Location: time.UTC})
//	scheduler.Register("0 2 * * *", asynq.NewTask("report:nightly", nil))
//	scheduler.Register("*/5 * * * *", cwasynq.CheckTask())
//
//	// The server process.
//	mux := asynq.NewServeMux()
//	mux.Use(w.Middleware())
//	mux.HandleFunc("report:nightly", nightlyReport)
//	mux.Handle(cwasynq.CheckType, w.CheckHandler())
//
// # Schedules
//
// A scheduler made with w.NewScheduler (or NewSchedulerFromRedisClient) is
// asynq's own with Register and Unregister that also declare the entry's
// task type as a CronWatch job, its cronspec read as robfig/cron (which
// Asynq runs it with) reads it, in its CRON_TZ or the scheduler's Location
// (UTC by default, as Asynq's), checked against robfig/cron's own fire
// times (robfigcron.Convert). A PeriodicTaskManager made with
// w.NewPeriodicTaskManager declares its provider's configs each time the
// manager reads them. An entry unregistered, or a config the provider no
// longer gives, has its job declared again without its schedule, so it is
// never reported missed; so does one an earlier process scheduled, at the
// next check through CheckHandler. Two entries of one task type on
// different cronspecs are one job without a schedule, reported once, as is
// a cronspec CronWatch would expect at other times than Asynq runs it.
// Register's own options come after the job options for every job:
// Register(spec, task, asynq options...) takes Asynq's; give CronWatch's
// with RegisterWith.
//
// # Runs and retries
//
// The middleware records each attempt of a task whose type this process's
// scheduler declared, whose type Options.Tasks names, or whose type the
// store holds as this app's job (a server in a process of its own finds the
// scheduler's jobs there, looked up once a minute per type), as a run
// (trigger "asynq"), the handler's context carrying the run's JobContext
// (cronwatch.Current). Retries follow the gem's Sidekiq rules: every attempt
// is a run, an attempt that returns an error (asynq.SkipRetry included) or
// panics (which Asynq recovers) is a failed run with it, so failing attempts
// open one failed alert and the one that succeeds closes it, and
// FailuresBeforeAlert rides through retries. An attempt that returns
// asynq.RevokeTask gives the task back without failing: its run is taken
// back (cronwatch.DiscardWhen), nothing is judged, and no alert is sent.
//
// # The check
//
// CheckTask is a task of type "cronwatch:check" and CheckHandler its
// handler, which declares again without their schedules the jobs this
// app's schedulers no longer run and checks. Schedule it every five
// minutes with the scheduler; it is never a job.
//
// Jobs are tagged "asynq" and "asynq:<app>", the app named by Options.App,
// else bridge.AppName(), so two apps sharing a store never declare each
// other's jobs without a schedule: give the scheduler's and the server's
// processes the same name (CRONWATCH_APP_ID) when their executables differ.
package asynq

import (
	"context"
	"errors"
	"fmt"
	"slices"
	"sync"
	"time"

	cronwatch "cronwatch.dev/go"
	"cronwatch.dev/go/bridge"
	"cronwatch.dev/go/robfigcron"
	"github.com/hibiken/asynq"
	"github.com/redis/go-redis/v9"
	"github.com/robfig/cron/v3"
)

// Tag is the tag every job this package declares carries, Trigger its
// runs' trigger, and CheckType the check task's type.
const (
	Tag       = "asynq"
	Trigger   = "asynq"
	CheckType = "cronwatch:check"
)

// lookupEvery is how long a server takes a task type the store does not
// hold as a job to stay one, before it looks again.
var lookupEvery = time.Minute

// Options configure a Watcher.
type Options struct {
	// App names the app in its tag. Default bridge.AppName().
	App string
	// Defaults are job options for every scheduled job, before its schedule.
	Defaults []cronwatch.JobOption
	// Tasks watches tasks of these types that no scheduler here declares,
	// each attempt a run of a job named after the type, with these
	// options (a job the store holds as this app's keeps its own).
	Tasks map[string][]cronwatch.JobOption
	// Exclude leaves task types out.
	Exclude []string
}

// Watcher watches one Asynq app's schedulers and servers. Safe for use by
// many goroutines at once.
type Watcher struct {
	cw      *cronwatch.Client
	watch   *bridge.Watch
	options Options

	mu      sync.Mutex
	sources map[any][]bridge.Entry
	order   []any
	unknown map[string]time.Time
	swept   time.Time
}

// New makes a Watcher.
func New(cw *cronwatch.Client, options Options) *Watcher {
	return &Watcher{cw: cw, watch: bridge.NewWatch(cw, Tag, options.App, "Asynq"), options: options,
		sources: map[any][]bridge.Entry{}, unknown: map[string]time.Time{}}
}

// set replaces the entries one scheduler or provider holds, and declares
// every entry the watcher knows.
func (w *Watcher) set(source any, entries []bridge.Entry) {
	w.mu.Lock()
	if _, ok := w.sources[source]; !ok {
		w.order = append(w.order, source)
	}
	w.sources[source] = entries
	var all []bridge.Entry
	for _, s := range w.order {
		all = append(all, w.sources[s]...)
	}
	w.mu.Unlock()
	w.watch.Declare(all)
}

// entry is a cronspec for a task type as CronWatch declares it; false for
// one left out (the check, Exclude) or that cannot be a job name.
func (w *Watcher) entry(cronspec, taskType string, loc *time.Location, options []cronwatch.JobOption) (bridge.Entry, bool) {
	if taskType == CheckType || slices.Contains(w.options.Exclude, taskType) {
		return bridge.Entry{}, false
	}
	where := fmt.Sprintf("Asynq entry %q for %s", cronspec, taskType)
	if !bridge.ValidName(taskType) {
		w.watch.ReportOnce(fmt.Errorf("cronwatch: %s: the task type %q is not a CronWatch job name, so its runs are not watched", where, taskType), "declaring "+where)
		return bridge.Entry{}, false
	}
	e := bridge.Entry{Name: taskType, Where: where, Defaults: w.options.Defaults, Options: slices.Concat(w.options.Tasks[taskType], options)}
	if converted, err := Convert(cronspec, loc, "cronwatch: "+where); err != nil {
		e.Problem = err
	} else {
		e.Schedule, e.Timezone = converted.Schedule, converted.Timezone
	}
	return e, true
}

// Convert is an Asynq cronspec as CronWatch reads it: parsed as Asynq's
// scheduler parses it (robfig/cron's standard parser: five fields,
// descriptors, @every, CRON_TZ=), in loc (the scheduler's Location, UTC by
// default) unless the spec names its own zone, and checked against
// robfig/cron's own fire times (robfigcron.Convert). where names the entry
// in the error.
func Convert(cronspec string, loc *time.Location, where string) (robfigcron.Converted, error) {
	if loc == nil {
		loc = time.UTC
	}
	s, err := cron.ParseStandard(cronspec)
	if err != nil {
		return robfigcron.Converted{}, bridge.Refuse("%s: robfig/cron cannot read the cronspec: %v", where, err)
	}
	return robfigcron.Convert(s, loc, where)
}

// Scheduler is asynq's Scheduler with Register and Unregister declaring
// its entries.
type Scheduler struct {
	*asynq.Scheduler
	w   *Watcher
	loc *time.Location

	mu      sync.Mutex
	entries map[string]registered
	order   []string
}

type registered struct {
	spec     string
	taskType string
	options  []cronwatch.JobOption
}

// NewScheduler is asynq.NewScheduler, watched.
func (w *Watcher) NewScheduler(r asynq.RedisConnOpt, opts *asynq.SchedulerOpts) *Scheduler {
	return w.scheduler(asynq.NewScheduler(r, opts), opts)
}

// NewSchedulerFromRedisClient is asynq.NewSchedulerFromRedisClient, watched.
func (w *Watcher) NewSchedulerFromRedisClient(c redis.UniversalClient, opts *asynq.SchedulerOpts) *Scheduler {
	return w.scheduler(asynq.NewSchedulerFromRedisClient(c, opts), opts)
}

func (w *Watcher) scheduler(s *asynq.Scheduler, opts *asynq.SchedulerOpts) *Scheduler {
	loc := time.UTC
	if opts != nil && opts.Location != nil {
		loc = opts.Location
	}
	return &Scheduler{Scheduler: s, w: w, loc: loc, entries: map[string]registered{}}
}

// Register is asynq's Register, declaring the entry's task type as a job
// with the cronspec as its schedule.
func (s *Scheduler) Register(cronspec string, task *asynq.Task, opts ...asynq.Option) (string, error) {
	return s.RegisterWith(cronspec, task, nil, opts...)
}

// RegisterWith is Register with CronWatch's job options for the entry's job.
func (s *Scheduler) RegisterWith(cronspec string, task *asynq.Task, options []cronwatch.JobOption, opts ...asynq.Option) (string, error) {
	id, err := s.Scheduler.Register(cronspec, task, opts...)
	if err != nil {
		return id, err
	}
	s.mu.Lock()
	s.entries[id] = registered{spec: cronspec, taskType: task.Type(), options: options}
	s.order = append(s.order, id)
	s.mu.Unlock()
	s.declare()
	return id, nil
}

// Unregister is asynq's Unregister; the entry's job loses its schedule
// when no other entry runs its task type.
func (s *Scheduler) Unregister(entryID string) error {
	if err := s.Scheduler.Unregister(entryID); err != nil {
		return err
	}
	s.mu.Lock()
	delete(s.entries, entryID)
	s.order = slices.DeleteFunc(s.order, func(id string) bool { return id == entryID })
	s.mu.Unlock()
	s.declare()
	return nil
}

func (s *Scheduler) declare() {
	s.mu.Lock()
	var entries []bridge.Entry
	for _, id := range s.order {
		r := s.entries[id]
		if e, ok := s.w.entry(r.spec, r.taskType, s.loc, r.options); ok {
			entries = append(entries, e)
		}
	}
	s.mu.Unlock()
	s.w.set(s, entries)
}

// NewPeriodicTaskManager is asynq.NewPeriodicTaskManager, with the
// provider's configs declared each time the manager reads them.
func (w *Watcher) NewPeriodicTaskManager(opts asynq.PeriodicTaskManagerOpts) (*asynq.PeriodicTaskManager, error) {
	if opts.PeriodicTaskConfigProvider != nil {
		loc := time.UTC
		if opts.SchedulerOpts != nil && opts.SchedulerOpts.Location != nil {
			loc = opts.SchedulerOpts.Location
		}
		opts.PeriodicTaskConfigProvider = &provider{w: w, inner: opts.PeriodicTaskConfigProvider, loc: loc}
	}
	return asynq.NewPeriodicTaskManager(opts)
}

type provider struct {
	w     *Watcher
	inner asynq.PeriodicTaskConfigProvider
	loc   *time.Location
}

// GetConfigs is the provider's configs, declared.
func (p *provider) GetConfigs() ([]*asynq.PeriodicTaskConfig, error) {
	configs, err := p.inner.GetConfigs()
	if err != nil {
		return configs, err
	}
	var entries []bridge.Entry
	for _, c := range configs {
		if c == nil || c.Task == nil {
			continue
		}
		if e, ok := p.w.entry(c.Cronspec, c.Task.Type(), p.loc, nil); ok {
			entries = append(entries, e)
		}
	}
	p.w.set(p, entries)
	return configs, nil
}

// Wait waits until the entries and configs declared have been written to
// the store (which happens in the background, so a scheduler whose server
// runs in another process still puts its jobs where the server and the
// check read them), for tests and for a clean exit.
func (w *Watcher) Wait() { w.watch.Settle() }

// Sync declares again without its schedule each job of this app's that no
// scheduler or provider here runs any more (taken out since a process
// declared it). CheckHandler runs it before each check.
func (w *Watcher) Sync(ctx context.Context) error {
	_, err := w.watch.Unschedule(ctx)
	return err
}

// Middleware records each attempt of a watched task as a run (see the
// package's documentation). Give it to the server's ServeMux with Use.
func (w *Watcher) Middleware() asynq.MiddlewareFunc {
	return func(next asynq.Handler) asynq.Handler {
		return asynq.HandlerFunc(func(ctx context.Context, task *asynq.Task) error {
			job := w.jobFor(ctx, task.Type())
			if job == nil {
				return next.ProcessTask(ctx, task)
			}
			return job.Run(ctx, func(ctx context.Context, _ *cronwatch.JobContext) error {
				return next.ProcessTask(ctx, task)
			}, cronwatch.WithTrigger(Trigger), cronwatch.DiscardWhen(func(err error) bool { return errors.Is(err, asynq.RevokeTask) }))
		})
	}
}

// jobFor is the job a task of this type is a run of, or nil.
func (w *Watcher) jobFor(ctx context.Context, taskType string) *cronwatch.Job {
	if taskType == CheckType || slices.Contains(w.options.Exclude, taskType) || !bridge.ValidName(taskType) {
		return nil
	}
	if job := w.watch.Job(taskType); job != nil {
		return job
	}
	options, listed := w.options.Tasks[taskType]
	if !listed {
		// A type the store holds as this app's job: a scheduler in another
		// process declared it. Looked up once a minute per type.
		w.mu.Lock()
		checked, seen := w.unknown[taskType]
		w.mu.Unlock()
		if seen && time.Since(checked) < lookupEvery {
			return nil
		}
		summary, err := w.cw.JobSummary(ctx, taskType)
		if err != nil || summary == nil || !slices.Contains(summary.Definition.Tags(), w.watch.AppTag()) {
			w.noteUnknown(taskType, time.Now())
			return nil
		}
	}
	return w.watch.Fallback(ctx, taskType, options)
}

// maxUnknown bounds the task types remembered as not jobs: past it the
// memory is let go, which costs only a lookup more for each type.
const maxUnknown = 10000

// noteUnknown remembers taskType as not a job, as of now, and lets go of
// types whose minute has passed, so a server that sees many task types
// over its life (or types a caller made up) keeps only the last minute's.
func (w *Watcher) noteUnknown(taskType string, now time.Time) {
	w.mu.Lock()
	defer w.mu.Unlock()
	if now.Sub(w.swept) >= lookupEvery || len(w.unknown) >= maxUnknown {
		for t, checked := range w.unknown {
			if now.Sub(checked) >= lookupEvery {
				delete(w.unknown, t)
			}
		}
		if len(w.unknown) >= maxUnknown {
			clear(w.unknown)
		}
		w.swept = now
	}
	w.unknown[taskType] = now
}

// CheckTask is the task that runs a CronWatch check: no retries, since a
// check that fails is repeated by the next one.
func CheckTask() *asynq.Task { return asynq.NewTask(CheckType, nil, asynq.MaxRetry(0)) }

// CheckHandler handles CheckTask: it declares again without their
// schedules the jobs this app no longer schedules, and checks.
func (w *Watcher) CheckHandler() asynq.Handler {
	return asynq.HandlerFunc(func(ctx context.Context, _ *asynq.Task) error {
		if err := w.Sync(ctx); err != nil {
			w.cw.ReportError(err, "asynq")
		}
		_, err := w.cw.Check(ctx)
		return err
	})
}
