package river_test

import (
	"context"
	"errors"
	"testing"

	cronwatch "cronwatch.dev/go"
	cwriver "cronwatch.dev/go/river"
	"github.com/riverqueue/river"
	"github.com/riverqueue/river/rivertype"
)

// TestAWorkerKeepsTheSchedulersDefinition: a process that works a periodic
// job's jobs without making the periodic job records their runs under the
// job the scheduling process declared, and leaves its definition as it is.
func TestAWorkerKeepsTheSchedulersDefinition(t *testing.T) {
	t.Setenv("CRONWATCH_APP_ID", "billing")
	store := cronwatch.NewMemoryStore()
	ctx := context.Background()
	scheduling, err := cronwatch.New(cronwatch.WithStore(store))
	if err != nil {
		t.Fatal(err)
	}
	cwriver.New(scheduling, cwriver.Options{}).PeriodicJob(mustCron(t, "CRON_TZ=UTC 0 2 * * *"), func() (river.JobArgs, *river.InsertOpts) {
		return ReportArgs{}, nil
	}, &river.PeriodicJobOpts{ID: "nightly-report"}, cronwatch.Grace("5m"))
	if _, err := scheduling.Check(ctx); err != nil {
		t.Fatal(err)
	}
	before, _ := store.GetJob(ctx, "nightly-report")
	want, _ := before.Definition.MarshalJSON()

	working, err := cronwatch.New(cronwatch.WithStore(store))
	if err != nil {
		t.Fatal(err)
	}
	middleware := cwriver.New(working, cwriver.Options{}).Middleware()
	row := &rivertype.JobRow{ID: 1, Kind: "report", Attempt: 1, Metadata: []byte(`{"cronwatch":"nightly-report","periodic":true}`)}
	err = middleware.Work(ctx, row, func(ctx context.Context) error {
		cronwatch.Current(ctx).Log("Report written")
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
	runs, _ := working.Runs(ctx, "nightly-report", 5)
	eq(t, "recorded", len(runs), 1)
	eq(t, "logged", *runs[0].Output, "Report written")
	if _, err := working.Check(ctx); err != nil {
		t.Fatal(err)
	}
	after, _ := store.GetJob(ctx, "nightly-report")
	got, _ := after.Definition.MarshalJSON()
	eq(t, "the definition kept", string(got), string(want))

	// A job of a kind nobody watches passes through, its error untouched.
	boom := errors.New("boom")
	if err := middleware.Work(ctx, &rivertype.JobRow{Kind: "other", Metadata: []byte(`{}`)}, func(context.Context) error { return boom }); err != boom {
		t.Errorf("passed through: %v", err)
	}
	if runs, _ := working.Runs(ctx, "other", 5); len(runs) != 0 {
		t.Error("an unwatched kind was recorded")
	}
}
