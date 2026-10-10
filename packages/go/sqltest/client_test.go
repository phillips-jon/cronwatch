package sqltest

//lint:file-ignore SA1019 storetest's helpers are this module's own test kit, deprecated only for apps

import (
	"context"
	"errors"
	"reflect"
	"sort"
	"testing"

	cronwatch "cronwatch.dev/go"
	"cronwatch.dev/go/sqlstore"
	"cronwatch.dev/go/storetest"
)

// A client from end to end on each dialect: jobs declared, runs that
// succeed and fail, a check that finds a stuck run and a missed one, the
// alerts sent, and the state's version moving on every write.

func endToEnd(t *testing.T, store cronwatch.Store) {
	const min = 60_000
	clock := storetest.NewClock(storetest.T0)
	p := process(t, store, clock.Now)
	cw := p.Client
	nightly := cw.MustJob("nightly", cronwatch.Schedule("every 5m"), cronwatch.Grace("1m"), cronwatch.Timeout("2m"))
	cw.MustJob("hourly", cronwatch.Schedule("every 1h"), cronwatch.Grace("1m"))

	must(t, nightly.Run(ctx, func(_ context.Context, job *cronwatch.JobContext) error {
		job.Log("rows:", 12)
		return job.Metric("rows", 12)
	}))
	clock.Advance(min)
	boom := errors.New("boom")
	if err := nightly.Run(ctx, func(context.Context, *cronwatch.JobContext) error { return boom }); err != boom {
		t.Fatalf("the job's error comes back: %v", err)
	}
	st, err := store.GetState(ctx, "nightly")
	must(t, err)
	if st.ConsecutiveFailures != 1 || st.Version == nil || *st.Version < 2 {
		t.Errorf("state after a failure: %+v", st)
	}
	before := *st.Version

	clock.Advance(min)
	h, err := nightly.Start(ctx)
	must(t, err)
	h.Log("started")
	h.Flush(ctx)
	clock.Advance(3 * min) // past nightly's timeout
	result, err := cw.Check(ctx)
	must(t, err)
	clock.Advance(61 * min) // hourly, registered at T0, is now missed
	result2, err := cw.Check(ctx)
	must(t, err)

	types := p.Alerts.Types()
	sort.Strings(types)
	for _, want := range []string{"failed", "missed", "stuck"} {
		i := sort.SearchStrings(types, want)
		if i >= len(types) || types[i] != want {
			t.Errorf("no %s alert among %v", want, types)
		}
	}
	runs, err := cw.Runs(ctx, "nightly", 10)
	must(t, err)
	var statuses []string
	for _, r := range runs {
		statuses = append(statuses, string(r.Status))
	}
	if !reflect.DeepEqual(statuses, []string{"timeout", "failed", "ok"}) {
		t.Errorf("runs %v", statuses)
	}
	if *runs[0].Output != "started" || *runs[2].Output != "rows: 12" {
		t.Errorf("outputs %q %q", *runs[0].Output, *runs[2].Output)
	}
	st, err = store.GetState(ctx, "nightly")
	must(t, err)
	if *st.Version <= before {
		t.Errorf("the version did not move: %d", *st.Version)
	}
	if len(result.Jobs) != 2 || len(result2.Jobs) != 2 {
		t.Errorf("jobs checked %d %d", len(result.Jobs), len(result2.Jobs))
	}
	if errs := p.Errors.List(); len(errs) > 0 {
		t.Errorf("errors: %v", errs)
	}
	must(t, cw.Close())
}

func TestSQLiteEndToEnd(t *testing.T) {
	endToEnd(t, newStore(t, sqliteDB(t, tempFile(t, "e2e.db")), sqlstore.SQLite, sqlstore.DefaultPrefix))
}

func TestServerEndToEnd(t *testing.T) {
	eachServer(t, func(t *testing.T, b backend) {
		endToEnd(t, newStore(t, b.open(t), b.dialect, prefix("e2e")))
	})
}
