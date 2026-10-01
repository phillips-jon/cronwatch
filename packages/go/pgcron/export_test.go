package pgcron

// Hooks for the tests in package pgcron_test, which replay
// conformance/pgcron.json through the source's internals.

var (
	ScheduleOf     = scheduleOf
	DefaultJobName = defaultJobName
	RunOfRow       = runOf
)

const HoldFor = hold
