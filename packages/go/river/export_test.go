package river

import "github.com/riverqueue/river"

// MarkForTest is the metadata the marked constructor gives a job.
func MarkForTest(constructor river.PeriodicJobConstructor, name string) []byte {
	_, opts := marked(constructor, name)()
	return opts.Metadata
}
