package cronwatch_test

import (
	"context"
	"errors"
	"fmt"
	"time"

	cronwatch "cronwatch.dev/go"
)

// A job declared once and run: the failure is recorded, judged and alerted.
func Example() {
	ctx := context.Background()
	now := time.Date(2026, 1, 5, 2, 0, 0, 0, time.UTC).UnixMilli()
	alerts := cronwatch.ChannelFunc("print", func(_ context.Context, a cronwatch.Alert) error {
		fmt.Println(a.Title)
		fmt.Println(a.Message)
		return nil
	})
	cw := cronwatch.MustNew(cronwatch.WithAlerts(alerts), cronwatch.WithClock(func() int64 { return now }))
	nightly := cw.MustJob("nightly-report", cronwatch.Schedule("0 2 * * *"), cronwatch.Timezone("UTC"), cronwatch.Grace("15m"))

	err := nightly.Run(ctx, func(ctx context.Context, job *cronwatch.JobContext) error {
		job.Log("connecting to postgres://app:" + "hunter" + "2@db.internal/app")
		return errors.New("connection refused")
	})
	fmt.Println("returned:", err)

	runs, _ := cw.Runs(ctx, "nightly-report", 1)
	fmt.Println(runs[0].Status, *runs[0].Output)
	// Output:
	// nightly-report failed
	// Started 2026-01-05 02:00:00 UTC (now), ran 0ms.
	// Error: connection refused
	// Output (tail):
	// connecting to postgres://app:[redacted]@db.internal/app
	// returned: connection refused
	// failed connecting to postgres://app:[redacted]@db.internal/app
}

// Options keep the order they are given in, as the SDK's object literal
// does, so the stored definition is the same JSON a Node process writes.
func ExampleClient_Job() {
	cw := cronwatch.MustNew()
	job := cw.MustJob("sync", cronwatch.Schedule("every 5m"), cronwatch.Timeout(90*time.Second),
		cronwatch.Budget("tokens", 5000), cronwatch.Expect("synced"))
	out, _ := job.Definition().MarshalJSON()
	fmt.Println(string(out))
	// Output:
	// {"schedule":"every 5m","timeout":90000,"budget":{"tokens":5000},"name":"sync","expect":"contains \"synced\""}
}
