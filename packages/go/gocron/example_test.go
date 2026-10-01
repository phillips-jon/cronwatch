package gocron_test

import (
	cronwatch "cronwatch.dev/go"
	cwgocron "cronwatch.dev/go/gocron"
	"github.com/go-co-op/gocron/v2"
)

func nightlyReport() {}

// The README's gocron example: one scheduler option.
func ExampleWatcher_Option() {
	cw := cronwatch.MustNew()
	s, err := gocron.NewScheduler(cwgocron.New(cw, cwgocron.Options{}).Option())
	if err != nil {
		panic(err)
	}
	_, _ = s.NewJob(gocron.DailyJob(1, gocron.NewAtTimes(gocron.NewAtTime(2, 0, 0))), gocron.NewTask(nightlyReport))
	s.Start()
	defer func() { _ = s.Shutdown() }()
}
