package asynq

import "time"

// NoteUnknownForTest remembers a task type as not a job, as of now.
func (w *Watcher) NoteUnknownForTest(taskType string, now time.Time) { w.noteUnknown(taskType, now) }

// UnknownForTest is how many task types are remembered as not jobs.
func (w *Watcher) UnknownForTest() int {
	w.mu.Lock()
	defer w.mu.Unlock()
	return len(w.unknown)
}

// MaxUnknown is maxUnknown.
const MaxUnknown = maxUnknown
