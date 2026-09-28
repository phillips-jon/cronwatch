package river_test

import (
	"time"

	cronwatch "cronwatch.dev/go"
	cwriver "cronwatch.dev/go/river"
	"github.com/riverqueue/river"
	"github.com/riverqueue/river/rivertype"
	"github.com/robfig/cron/v3"
)

type NightlyReportArgs struct{}

func (NightlyReportArgs) Kind() string { return "nightly_report" }

// The README's River example: periodic jobs through the watcher, and its
// middleware and check worker in the client's config.
func ExampleWatcher_PeriodicJob() {
	cw := cronwatch.MustNew()
	w := cwriver.New(cw, cwriver.Options{Kinds: map[string][]cronwatch.JobOption{"send_invoice": nil}})
	workers := river.NewWorkers()
	river.AddWorker(workers, w.CheckWorker())
	nightly, err := cron.ParseStandard("0 2 * * *") // github.com/robfig/cron/v3, as River's docs use
	if err != nil {
		panic(err)
	}
	config := &river.Config{
		Workers:    workers,
		Middleware: []rivertype.Middleware{w.Middleware()},
		PeriodicJobs: []*river.PeriodicJob{
			w.PeriodicJob(nightly, func() (river.JobArgs, *river.InsertOpts) {
				return NightlyReportArgs{}, nil
			}, &river.PeriodicJobOpts{ID: "nightly-report"}, cronwatch.Grace("15m")),
			w.CheckPeriodicJob(5 * time.Minute),
		},
	}
	_ = config // river.NewClient(riverpgxv5.New(pool), config)
}
