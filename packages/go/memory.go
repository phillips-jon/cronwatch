package cronwatch

import (
	"context"
	"fmt"
	"sort"
	"sync"
)

// MemoryStore keeps everything in process memory (stores/memory.ts). The
// default when no store is given, good for tests and for trying the
// library out. State is gone on restart, so a missed run cannot be noticed
// across one. Safe for use by many goroutines at once.
type MemoryStore struct {
	mu     sync.Mutex
	jobs   map[string]StoredJob
	runs   map[string]Run
	order  map[string]int64
	states map[string]JobState
	seq    int64
}

// NewMemoryStore is an empty in-memory store.
func NewMemoryStore() *MemoryStore {
	return &MemoryStore{jobs: map[string]StoredJob{}, runs: map[string]Run{}, order: map[string]int64{}, states: map[string]JobState{}}
}

var (
	_ RunUpdater    = (*MemoryStore)(nil)
	_ StateComparer = (*MemoryStore)(nil)
	_ RunDeleter    = (*MemoryStore)(nil)
)

// Init does nothing.
func (m *MemoryStore) Init(context.Context) error { return nil }

// Close does nothing.
func (m *MemoryStore) Close() error { return nil }

func (m *MemoryStore) UpsertJob(_ context.Context, def Definition, now int64) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	created := now
	if existing, ok := m.jobs[def.Name()]; ok {
		created = existing.CreatedAt
	}
	m.jobs[def.Name()] = StoredJob{Name: def.Name(), Definition: def.clone(), CreatedAt: created, UpdatedAt: now}
	return nil
}

func (m *MemoryStore) GetJob(_ context.Context, name string) (*StoredJob, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	j, ok := m.jobs[name]
	if !ok {
		return nil, nil
	}
	j.Definition = j.Definition.clone()
	return &j, nil
}

// ListJobs is every job by name in byte order, as the SQL stores sort.
func (m *MemoryStore) ListJobs(context.Context) ([]StoredJob, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	out := make([]StoredJob, 0, len(m.jobs))
	for _, j := range m.jobs {
		j.Definition = j.Definition.clone()
		out = append(out, j)
	}
	sort.Slice(out, func(a, b int) bool { return out[a].Name < out[b].Name })
	return out, nil
}

func (m *MemoryStore) DeleteJob(_ context.Context, name string) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	delete(m.jobs, name)
	delete(m.states, name)
	for id, r := range m.runs {
		if r.Job == name {
			delete(m.runs, id)
			delete(m.order, id)
		}
	}
	return nil
}

// InsertRun refuses an id already recorded, like SQL's primary key.
func (m *MemoryStore) InsertRun(_ context.Context, run Run) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	if _, ok := m.runs[run.ID]; ok {
		return fmt.Errorf("run %s already exists", run.ID)
	}
	m.seq++
	m.runs[run.ID] = run.clone()
	m.order[run.ID] = m.seq
	return nil
}

// finish writes the fields a finish changes onto a stored run.
func finish(existing, run Run) Run {
	r := existing.clone()
	c := run.clone()
	r.Status, r.FinishedAt, r.DurationMs, r.Error, r.Output, r.Metrics = c.Status, c.FinishedAt, c.DurationMs, c.Error, c.Output, c.Metrics
	return r
}

// UpdateRun changes only the finish's fields; a run that is gone (its job
// was forgotten) stays gone, as SQL's UPDATE has it.
func (m *MemoryStore) UpdateRun(_ context.Context, run Run) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	if existing, ok := m.runs[run.ID]; ok {
		m.runs[run.ID] = finish(existing, run)
	}
	return nil
}

func (m *MemoryStore) UpdateRunIf(_ context.Context, run Run, from []RunStatus) (bool, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	existing, ok := m.runs[run.ID]
	if !ok {
		return false, nil
	}
	for _, s := range from {
		if existing.Status == s {
			m.runs[run.ID] = finish(existing, run)
			return true, nil
		}
	}
	return false, nil
}

func (m *MemoryStore) DeleteRunIf(_ context.Context, id, job string, status RunStatus) (bool, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	existing, ok := m.runs[id]
	if !ok || existing.Job != job || existing.Status != status {
		return false, nil
	}
	delete(m.runs, id)
	delete(m.order, id)
	return true, nil
}

func (m *MemoryStore) GetRun(_ context.Context, id string) (*Run, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	r, ok := m.runs[id]
	if !ok {
		return nil, nil
	}
	c := r.clone()
	return &c, nil
}

func (m *MemoryStore) ListRuns(_ context.Context, job string, limit int) ([]Run, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	out := []Run{}
	for _, r := range m.runs {
		if r.Job == job {
			out = append(out, r.clone())
		}
	}
	sort.Slice(out, func(a, b int) bool {
		if out[a].StartedAt != out[b].StartedAt {
			return out[a].StartedAt > out[b].StartedAt
		}
		return m.order[out[a].ID] > m.order[out[b].ID]
	})
	if limit < 0 {
		limit = 0
	}
	if len(out) > limit {
		out = out[:limit]
	}
	return out, nil
}

func (m *MemoryStore) LastRun(ctx context.Context, job string) (*Run, error) {
	list, err := m.ListRuns(ctx, job, 1)
	if err != nil || len(list) == 0 {
		return nil, err
	}
	return &list[0], nil
}

func (m *MemoryStore) RunningRuns(context.Context) ([]Run, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	out := []Run{}
	for _, r := range m.runs {
		if r.Status == StatusRunning {
			out = append(out, r.clone())
		}
	}
	sort.Slice(out, func(a, b int) bool {
		if out[a].StartedAt != out[b].StartedAt {
			return out[a].StartedAt < out[b].StartedAt
		}
		return m.order[out[a].ID] < m.order[out[b].ID]
	})
	return out, nil
}

func (m *MemoryStore) GetState(_ context.Context, job string) (*JobState, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	s, ok := m.states[job]
	if !ok {
		return nil, nil
	}
	c := s.clone()
	return &c, nil
}

func (m *MemoryStore) SetState(_ context.Context, state JobState) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.states[state.Job] = state.clone()
	return nil
}

func (m *MemoryStore) CompareAndSetState(_ context.Context, state JobState, expected int64) (bool, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	if m.states[state.Job].version() != expected {
		return false, nil
	}
	m.states[state.Job] = state.clone()
	return true, nil
}

// Prune keeps each job's newest run whatever its age: without it, a job
// that runs less often than the retention looks like it never ran.
func (m *MemoryStore) Prune(_ context.Context, before int64) (int, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	newest := map[string]int64{}
	for _, r := range m.runs {
		if at, ok := newest[r.Job]; !ok || r.StartedAt > at {
			newest[r.Job] = r.StartedAt
		}
	}
	n := 0
	for id, r := range m.runs {
		if r.Status != StatusRunning && r.StartedAt < before && r.StartedAt < newest[r.Job] {
			delete(m.runs, id)
			delete(m.order, id)
			n++
		}
	}
	return n, nil
}
