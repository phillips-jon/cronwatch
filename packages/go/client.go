package cronwatch

// The client (client.ts): jobs, runs, state updates. Evaluation is in
// evaluate.go as pure functions; everything with a side effect is here and
// in run.go, handle.go, check.go and deliver.go.

import (
	"context"
	"crypto/rand"
	"fmt"
	"io"
	"os"
	"regexp"
	"sync"
	"time"

	"cronwatch.dev/go/internal/js"
	"cronwatch.dev/go/internal/output"
	"cronwatch.dev/go/internal/schedule"
)

var nameRE = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9._:-]{0,119}$`)

// The waits, variables only so the package's own tests can shorten them.
var (
	triageTimeout = 25 * time.Second
	// How long one channel may take to send one alert.
	channelTimeout = 15 * time.Second
	// Wall-clock time one check spends retrying undelivered alerts, across
	// every job. Once it is spent the rest wait for the next check.
	retryBudget = 20 * time.Second
	// How long Start waits before its first check.
	firstCheckDelay = time.Second
)

const (
	pruneInterval = 60 * 60_000
	// Undelivered alerts kept per job for retry; the oldest go first.
	maxUndelivered = 20
	// Reads and writes of one job's state before an update gives up on a
	// store that keeps changing under it.
	stateAttempts = 10
	// Runs read for a baseline, and the most read when failures crowd out the successes.
	historyPage = baselineWindow + 5
	historyMax  = 200
)

// Stderr is where the default error handler, the in-memory store's
// warning and the console channel's failures go. Tests may replace it.
var Stderr io.Writer = os.Stderr

// Stdout is where the console channel writes recoveries.
var Stdout io.Writer = os.Stdout

// Client watches an app's jobs: it records their runs in a store, judges
// each one, sends alerts, and runs the checks that find missed and stuck
// runs. One per app, made once with New. It is safe for use by many
// goroutines at once.
type Client struct {
	store         Store
	defaultStore  bool
	alerts        []Channel
	triage        TriageFunc
	sources       []Source
	cronSecret    string
	secretOptOut  bool
	retention     any
	retentionMs   float64
	defaults      *js.Object
	customRedact  func(string) string
	noRedact      bool
	deferDelivery bool
	onError       func(error, string)
	now           func() int64

	mu          sync.Mutex
	order       []string // declared names, in the order first declared
	definitions map[string]*jobDef
	synced      map[string]bool
	jobLocks    map[string]*sync.Mutex
	starting    map[string]*startCall

	readyMu sync.Mutex
	ready   bool

	checkMu     sync.Mutex
	checking    *checkCall
	lastPruneAt int64

	timerMu sync.Mutex
	stop    chan struct{}

	warnMu              sync.Mutex
	warnedDeferredStart bool

	busyMu      sync.Mutex
	channelBusy map[int]bool
	triageBusy  bool
}

// jobDef is a declared job: its stored definition, and the live expect rule
// the stored one only describes.
type jobDef struct {
	name   string
	stored Definition
	expect expectRule
}

// New makes a client. With no options it keeps everything in memory and
// writes alerts to the console.
func New(options ...Option) (*Client, error) {
	c := &Client{
		alerts:      []Channel{Console()},
		retention:   "30d",
		now:         func() int64 { return time.Now().UnixMilli() },
		definitions: map[string]*jobDef{},
		synced:      map[string]bool{},
		jobLocks:    map[string]*sync.Mutex{},
		starting:    map[string]*startCall{},
		channelBusy: map[int]bool{},
	}
	c.onError = func(err error, where string) { fmt.Fprintf(Stderr, "[cronwatch] %s: %v\n", where, err) }
	c.cronSecret = os.Getenv("CRON_SECRET")
	for _, o := range options {
		if err := o(c); err != nil {
			return nil, err
		}
	}
	if c.store == nil {
		c.store = NewMemoryStore()
		c.defaultStore = true
	}
	ms, err := schedule.ParseDuration(c.retention, "retention")
	if err != nil {
		return nil, err
	}
	c.retentionMs = ms
	return c, nil
}

// MustNew is New for a package-level client: it panics when an option is invalid.
func MustNew(options ...Option) *Client {
	c, err := New(options...)
	if err != nil {
		panic(err)
	}
	return c
}

// Store is where this client keeps jobs, runs and state.
func (c *Client) Store() Store { return c.store }

// Now is the client's clock, in epoch milliseconds.
func (c *Client) Now() int64 { return c.now() }

// CronSecret is the secret job handlers' requests must carry, or "" when
// none is set.
func (c *Client) CronSecret() string { return c.cronSecret }

// ReportError hands an error to the client's error handler, as the client
// reports its own. A source uses it.
func (c *Client) ReportError(err error, where string) { c.report(err, where) }

// report calls the error handler, carrying on even when it panics.
func (c *Client) report(err error, where string) {
	defer func() { _ = recover() }()
	c.onError(err, where)
}

// redact applies the client's redaction to a run's output or error.
func (c *Client) redact(text string) string {
	if c.noRedact {
		return text
	}
	if c.customRedact == nil {
		return output.RedactSecrets(text)
	}
	out, ok := func() (out string, ok bool) {
		defer func() {
			if p := recover(); p != nil {
				// A broken redact must not stop the run finishing, nor leak what it was given.
				c.report(fmt.Errorf("redact panicked: %v", p), "redact")
			}
		}()
		return c.customRedact(text), true
	}()
	if !ok {
		return output.RedactSecrets(text)
	}
	return out
}

// Job declares a job and returns its handle. Call it once, at startup, and
// keep the handle. Declaring a name again replaces its definition.
func (c *Client) Job(name string, options ...JobOption) (*Job, error) {
	if !nameRE.MatchString(name) {
		return nil, fmt.Errorf("job name %s must be 1 to 120 characters of letters, digits, \".\", \"_\", \":\" or \"-\"", js.Quote(name))
	}
	var cfg jobConfig
	for _, o := range options {
		o(&cfg)
	}
	fields := c.defaults.Clone()
	if fields == nil {
		fields = &js.Object{}
	}
	for _, k := range cfg.fields.Keys() {
		v, _ := cfg.fields.Get(k)
		fields.Set(k, js.CloneValue(v))
	}
	fields.Set("name", name)
	def := &jobDef{name: name, stored: toStored(fields, cfg.expect), expect: cfg.expect}
	if err := validateDefinition(name, def.stored); err != nil {
		return nil, err
	}
	c.mu.Lock()
	if _, ok := c.definitions[name]; !ok {
		c.order = append(c.order, name)
	}
	c.definitions[name] = def
	delete(c.synced, name)
	c.mu.Unlock()
	return &Job{c: c, def: def}, nil
}

// MustJob is Job for package-level declarations: it panics when an option
// is invalid.
func (c *Client) MustJob(name string, options ...JobOption) *Job {
	j, err := c.Job(name, options...)
	if err != nil {
		panic(err)
	}
	return j
}

// Run runs a job by name without keeping a handle, declaring it on first
// use (or again, when options are given).
func (c *Client) Run(ctx context.Context, name string, fn JobFunc, options ...JobOption) error {
	c.mu.Lock()
	def, ok := c.definitions[name]
	c.mu.Unlock()
	if len(options) > 0 || !ok {
		j, err := c.Job(name, options...)
		if err != nil {
			return err
		}
		def = j.def
	}
	return (&Job{c: c, def: def}).Run(ctx, fn)
}

// DefinedJobs are the definitions declared in this process, in the order
// they were first declared.
func (c *Client) DefinedJobs() []Definition {
	c.mu.Lock()
	defer c.mu.Unlock()
	out := make([]Definition, 0, len(c.order))
	for _, name := range c.order {
		out = append(out, c.definitions[name].stored.clone())
	}
	return out
}

func (c *Client) declared(name string) (*jobDef, bool) {
	c.mu.Lock()
	defer c.mu.Unlock()
	d, ok := c.definitions[name]
	return d, ok
}

func (c *Client) declaredAll() []*jobDef {
	c.mu.Lock()
	defer c.mu.Unlock()
	out := make([]*jobDef, 0, len(c.order))
	for _, name := range c.order {
		out = append(out, c.definitions[name])
	}
	return out
}

// ensureReady initializes the store once. One that fails is tried again
// on the next call rather than failing forever.
func (c *Client) ensureReady(ctx context.Context) error {
	c.readyMu.Lock()
	defer c.readyMu.Unlock()
	if c.ready {
		return nil
	}
	if err := c.store.Init(ctx); err != nil {
		return err
	}
	c.ready = true
	if c.defaultStore && environment() == "production" {
		fmt.Fprintln(Stderr, "[cronwatch] using the in-memory store: runs and state are lost on restart. Pass a store with WithStore, such as sqlstore.New over the app's database.")
	}
	return nil
}

// sync writes a declared definition to the store once per declaration.
func (c *Client) sync(ctx context.Context, def *jobDef) error {
	if err := c.ensureReady(ctx); err != nil {
		return err
	}
	c.mu.Lock()
	done := c.synced[def.name] && c.definitions[def.name] == def
	c.mu.Unlock()
	if done {
		return nil
	}
	if err := c.store.UpsertJob(ctx, def.stored.clone(), c.now()); err != nil {
		return err
	}
	c.mu.Lock()
	if c.definitions[def.name] == def {
		c.synced[def.name] = true
	}
	c.mu.Unlock()
	return nil
}

// jobLock is the lock every state update of a job in this process takes in
// turn (the SDK's serial()). Other processes are coordinated by
// updateState's conditional writes instead.
func (c *Client) jobLock(job string) *sync.Mutex {
	c.mu.Lock()
	defer c.mu.Unlock()
	l, ok := c.jobLocks[job]
	if !ok {
		l = &sync.Mutex{}
		c.jobLocks[job] = l
	}
	return l
}

func (c *Client) readState(ctx context.Context, job string) (JobState, error) {
	s, err := c.store.GetState(ctx, job)
	if err != nil {
		return JobState{}, err
	}
	return normalizeState(s, job), nil
}

// updateState is every read-modify-write of a job's state. In turn with
// this process's other updates to the job, it reads the state, asks change
// for the next one, and writes it with the version one higher, only if the
// stored version is still the one read. When another process wrote in
// between, the write is refused and it starts again from a fresh read, up
// to stateAttempts times. So change may run more than once and must only
// compute: what it returns from the attempt that was written is the result.
// Nothing is written when the state is unchanged. Returns the state as stored.
func updateState[T any](ctx context.Context, c *Client, job string, change func(JobState) (JobState, T, error)) (JobState, T, error) {
	lock := c.jobLock(job)
	lock.Lock()
	defer lock.Unlock()
	var zero T
	for attempt := 1; ; attempt++ {
		current, err := c.readState(ctx, job)
		if err != nil {
			return JobState{}, zero, err
		}
		next, result, err := change(current.clone())
		if err != nil {
			return JobState{}, zero, err
		}
		if js.Stringify(next) == js.Stringify(current) {
			return current, result, nil
		}
		version := current.version()
		next.Version = ptr(version + 1)
		ok, err := c.writeState(ctx, next, version)
		if err != nil {
			return JobState{}, zero, err
		}
		if ok {
			return next, result, nil
		}
		if attempt >= stateAttempts {
			return JobState{}, zero, fmt.Errorf("the state of %s changed under %d attempts in a row to update it; gave up", job, stateAttempts)
		}
	}
}

// writeState is a conditional write, or for a store without
// CompareAndSetState, a plain one that always succeeds.
func (c *Client) writeState(ctx context.Context, state JobState, expected int64) (bool, error) {
	if cas, ok := c.store.(StateComparer); ok {
		return cas.CompareAndSetState(ctx, state, expected)
	}
	return true, c.store.SetState(ctx, state)
}

// newID is a random UUID (version 4), as crypto.randomUUID() makes one.
func newID() string {
	var b [16]byte
	_, _ = rand.Read(b[:])
	b[6] = b[6]&0x0f | 0x40
	b[8] = b[8]&0x3f | 0x80
	return fmt.Sprintf("%x-%x-%x-%x-%x", b[0:4], b[4:6], b[6:8], b[8:10], b[10:16])
}

// clampLimit is a whole number from min to 500.
func clampLimit(limit, min int) int {
	if limit < min {
		limit = min
	}
	if limit > 500 {
		limit = 500
	}
	return limit
}

// storeCtx is the context the store is written with while recording a run:
// the caller's values without its cancellation, so a run whose caller gave
// up (a request that ended, a deadline) is still recorded rather than left
// running to be reported stuck.
func storeCtx(ctx context.Context) context.Context { return context.WithoutCancel(ctx) }

func isTimezone(name string) bool { return schedule.IsTimezone(name) }
