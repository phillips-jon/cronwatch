package cronwatch

import "context"

// Store is where jobs, runs and state live. MemoryStore is one; the
// sqlstore package keeps them in the app's own database. A store of your
// own should pass the storetest package's contract test.
type Store interface {
	// Init is called once before first use: create tables here.
	Init(ctx context.Context) error
	UpsertJob(ctx context.Context, definition Definition, now int64) error
	// GetJob is nil when the store does not know the job.
	GetJob(ctx context.Context, name string) (*StoredJob, error)
	// ListJobs is every job, by name in byte order.
	ListJobs(ctx context.Context) ([]StoredJob, error)
	// DeleteJob removes a job, its runs and its state.
	DeleteJob(ctx context.Context, name string) error
	// InsertRun refuses an id already stored.
	InsertRun(ctx context.Context, run Run) error
	// UpdateRun writes a run's status, finish, duration, error, output and
	// metrics. A run that is gone stays gone.
	UpdateRun(ctx context.Context, run Run) error
	// GetRun is nil when there is no such run.
	GetRun(ctx context.Context, id string) (*Run, error)
	// ListRuns is a job's newest runs first, at most limit of them.
	ListRuns(ctx context.Context, job string, limit int) ([]Run, error)
	LastRun(ctx context.Context, job string) (*Run, error)
	// RunningRuns is every run still running, oldest first.
	RunningRuns(ctx context.Context) ([]Run, error)
	// GetState is nil when the job has no state yet.
	GetState(ctx context.Context, job string) (*JobState, error)
	// SetState writes a job's state unconditionally. Used only when the
	// store is not a StateComparer.
	SetState(ctx context.Context, state JobState) error
	// Prune deletes finished runs that started before this time, keeping
	// each job's newest run, and returns how many.
	Prune(ctx context.Context, before int64) (int, error)
	Close() error
}

// RunUpdater is a store that can finish a run conditionally. Without it the
// client reads then writes, which is safe only when one process at a time
// finishes a given run.
type RunUpdater interface {
	// UpdateRunIf writes the run as UpdateRun does, only when its stored
	// status is one of from, in one step (SQL: UPDATE ... WHERE id = ? AND
	// status IN (...)), and says whether it wrote. This is what lets exactly
	// one of several processes finishing the same run evaluate it.
	UpdateRunIf(ctx context.Context, run Run, from []RunStatus) (bool, error)
}

// StateComparer is a store that can write a job's state conditionally.
// Without it the client writes unconditionally, which is safe only when
// one process at a time writes a job's state.
type StateComparer interface {
	// CompareAndSetState writes state only when the stored state's version
	// (absent, or no row at all, counts as 0) equals expected, and says
	// whether it wrote. The client reads, works out the next state, and on
	// a refused write reads again.
	CompareAndSetState(ctx context.Context, state JobState, expected int64) (bool, error)
}

// RunDeleter is a store that can take back a run it recorded, only while
// the run is still of one job and in one status. The SDK has no
// counterpart: it is how an attempt a queue gave back without failing (a
// River job that snoozed or cancelled itself, an Asynq task revoked)
// leaves no run behind, neither a failure nor a success (see DiscardWhen),
// as the PHP port's stores take back a released Laravel job's attempt.
type RunDeleter interface {
	// DeleteRunIf deletes the run id only when its stored job is job and its
	// status is status (SQL: DELETE ... WHERE id = ? AND job = ? AND status
	// = ?), and says whether it deleted.
	DeleteRunIf(ctx context.Context, id, job string, status RunStatus) (bool, error)
}
