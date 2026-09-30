package river_test

import (
	"context"
	"encoding/json"
	"strings"
	"testing"
	"time"

	cronwatch "cronwatch.dev/go"
	cwriver "cronwatch.dev/go/river"
	"cronwatch.dev/go/storetest"
	"github.com/riverqueue/river"
	"github.com/robfig/cron/v3"
)

func mustCron(t *testing.T, spec string) cron.Schedule {
	t.Helper()
	s, err := cron.ParseStandard(spec)
	if err != nil {
		t.Fatal(err)
	}
	return s
}

// irregular is a schedule of an app's own that is not a fixed interval.
type irregular struct{}

func (irregular) Next(t time.Time) time.Time {
	return t.Add(time.Duration(1+t.Nanosecond()%3) * time.Hour)
}

func TestConvertReadsRiversSchedules(t *testing.T) {
	cases := []struct {
		schedule river.PeriodicSchedule
		text     string
		zone     string
	}{
		{mustCron(t, "CRON_TZ=UTC 0 2 * * *"), "0 2 * * *", "UTC"},
		{mustCron(t, "CRON_TZ=Europe/London @hourly"), "0 * * * *", "Europe/London"},
		{mustCron(t, "@every 10m"), "every 10m", ""},
		{river.PeriodicInterval(15 * time.Minute), "every 15m", ""},
		{river.PeriodicInterval(36 * time.Hour), "every 1d12h", ""},
	}
	for _, c := range cases {
		got, err := cwriver.Convert(c.schedule, "cronwatch: x")
		if err != nil {
			t.Errorf("%T: %v", c.schedule, err)
			continue
		}
		if got.Schedule != c.text || got.Timezone != c.zone {
			t.Errorf("%T: got %q in %q, want %q in %q", c.schedule, got.Schedule, got.Timezone, c.text, c.zone)
		}
	}
	for _, c := range []struct {
		schedule river.PeriodicSchedule
		want     string
	}{
		{river.NeverSchedule(), "has a *river.neverSchedule schedule, which CronWatch cannot read"},
		{irregular{}, "has a river_test.irregular schedule"},
		{river.PeriodicInterval(500 * time.Millisecond), "runs every 500ms; CronWatch watches intervals of one second or more"},
	} {
		if _, err := cwriver.Convert(c.schedule, "cronwatch: x"); err == nil || !strings.Contains(err.Error(), c.want) {
			t.Errorf("want %q, got %v", c.want, err)
		}
	}
}

type ReportArgs struct{ Day string }

func (ReportArgs) Kind() string { return "report" }

func TestPeriodicJobsAreDeclaredAndMarked(t *testing.T) {
	t.Setenv("CRONWATCH_APP_ID", "billing")
	cw, err := cronwatch.New(cronwatch.WithErrorHandler(func(error, string) {}))
	if err != nil {
		t.Fatal(err)
	}
	w := cwriver.New(cw, cwriver.Options{Defaults: []cronwatch.JobOption{cronwatch.Grace("5m")}})
	byID := w.PeriodicJob(mustCron(t, "CRON_TZ=UTC 0 2 * * *"), func() (river.JobArgs, *river.InsertOpts) {
		return ReportArgs{}, &river.InsertOpts{Queue: "reports", Metadata: []byte(`{"team":"ops"}`)}
	}, &river.PeriodicJobOpts{ID: "nightly-report"}, cronwatch.Timeout("2h"))
	if byID == nil {
		t.Fatal("no periodic job")
	}
	w.PeriodicJob(river.PeriodicInterval(time.Hour), func() (river.JobArgs, *river.InsertOpts) { return ReportArgs{}, nil }, nil)
	defs := map[string]string{}
	for _, d := range cw.DefinedJobs() {
		b, _ := d.MarshalJSON()
		defs[d.Name()] = string(b)
	}
	eq(t, "by ID", defs["nightly-report"], `{"grace":"5m","schedule":"0 2 * * *","timezone":"UTC","timeout":"2h","tags":["river","river:billing"],"name":"nightly-report"}`)
	eq(t, "by kind", defs["report"], `{"grace":"5m","schedule":"every 1h","tags":["river","river:billing"],"name":"report"}`)
}

// The review: PeriodicJob only appended, so a job remade with its ID and a
// new interval was two entries on different schedules (watched without
// one), and one River removed kept its schedule and was reported missed.
func TestPeriodicJobsChangedAtRuntimeAreFollowed(t *testing.T) {
	t.Setenv("CRONWATCH_APP_ID", "billing")
	ctx := context.Background()
	errs := &storetest.Errors{}
	store := cronwatch.NewMemoryStore()
	cw, err := cronwatch.New(cronwatch.WithStore(store), cronwatch.WithErrorHandler(errs.Add))
	if err != nil {
		t.Fatal(err)
	}
	w := cwriver.New(cw, cwriver.Options{})
	args := func() (river.JobArgs, *river.InsertOpts) { return ReportArgs{}, nil }
	schedule := func(name string) string {
		t.Helper()
		w.Wait()
		if _, err := cw.Check(ctx); err != nil {
			t.Fatal(err)
		}
		job, err := store.GetJob(ctx, name)
		if err != nil || job == nil {
			t.Fatalf("%s is not stored (%v)", name, err)
		}
		return job.Definition.Schedule()
	}

	w.PeriodicJob(river.PeriodicInterval(time.Hour), args, &river.PeriodicJobOpts{ID: "nightly"})
	daily := w.PeriodicJob(river.PeriodicInterval(24*time.Hour), args, &river.PeriodicJobOpts{ID: "daily"})
	w.PeriodicJob(river.PeriodicInterval(time.Hour), args, &river.PeriodicJobOpts{ID: "weekly"})
	// Remade with the same ID and a new interval: the new one stands.
	w.PeriodicJob(river.PeriodicInterval(2*time.Hour), args, &river.PeriodicJobOpts{ID: "nightly"})
	if err := w.Sync(ctx); err != nil {
		t.Fatal(err)
	}
	eq(t, "remade", schedule("nightly"), "every 2h")
	eq(t, "nothing reported", len(errs.List()), 0)

	// Taken out of River's bundle, and so out of the watcher's.
	w.Remove(daily)
	eq(t, "removed", schedule("daily"), "")
	w.RemoveByID("weekly")
	eq(t, "removed by ID", schedule("weekly"), "")
	if err := w.Sync(ctx); err != nil {
		t.Fatal(err)
	}
	eq(t, "kept", schedule("nightly"), "every 2h")
	w.Clear()
	eq(t, "cleared", schedule("nightly"), "")
}

func TestTheConstructorsMetadataIsKept(t *testing.T) {
	var metadata map[string]any
	if err := json.Unmarshal(cwriver.MarkForTest(func() (river.JobArgs, *river.InsertOpts) {
		return ReportArgs{}, &river.InsertOpts{Metadata: []byte(`{"team":"ops"}`)}
	}, "nightly-report"), &metadata); err != nil {
		t.Fatal(err)
	}
	eq(t, "ours", metadata["cronwatch"], any("nightly-report"))
	eq(t, "theirs", metadata["team"], any("ops"))
}

// The audit: metadata of JSON null panicked in River's enqueuer, and
// metadata that is not an object was replaced.
func TestMetadataOfAnotherShape(t *testing.T) {
	mark := func(metadata string) string {
		return string(cwriver.MarkForTest(func() (river.JobArgs, *river.InsertOpts) {
			return ReportArgs{}, &river.InsertOpts{Metadata: []byte(metadata)}
		}, "nightly-report"))
	}
	eq(t, "null", mark(`null`), `{"cronwatch":"nightly-report"}`)
	eq(t, "an array is the app's", mark(`[1,2]`), `[1,2]`)
}

func eq[T comparable](t *testing.T, what string, got, want T) {
	t.Helper()
	if got != want {
		t.Errorf("%s: got %v, want %v", what, got, want)
	}
}
