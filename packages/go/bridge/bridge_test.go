package bridge_test

import (
	"context"
	"errors"
	"regexp"
	"strings"
	"testing"
	"time"

	cronwatch "cronwatch.dev/go"
	"cronwatch.dev/go/bridge"
	"cronwatch.dev/go/storetest"
)

func TestAppTagIsThePHPPorts(t *testing.T) {
	// What the PHP port's Bridge\Unscheduled::appTag() gives for each name.
	for app, want := range map[string]string{
		"Billing":                    "laravel-scheduler:billing",
		"  My App! v2 ":              "laravel-scheduler:my-app-v2",
		"acme_web.prod-1":            "laravel-scheduler:acme_web.prod-1",
		"!!!":                        "laravel-scheduler:6dd07555",
		strings.Repeat("x", 50):      "laravel-scheduler:" + strings.Repeat("x", 39) + "-62f01267",
		"\u00dcn\u00efcode \u00c4pp": "laravel-scheduler:n-code-pp",
		"\u212a":                     "laravel-scheduler:f7781178",
	} {
		if got := bridge.AppTag("laravel-scheduler", app); got != want {
			t.Errorf("%q: got %q, want %q", app, got, want)
		}
	}
}

func TestFieldTextAndEveryText(t *testing.T) {
	eq(t, "all", bridge.FieldText([]int{0, 1, 2, 3, 4, 5, 6}, 0, 6), "*")
	eq(t, "a step", bridge.FieldText([]int{0, 15, 30, 45}, 0, 59), "*/15")
	eq(t, "ranges", bridge.FieldText([]int{1, 2, 3, 5, 9, 10}, 0, 59), "1-3,5,9,10")
	eq(t, "one", bridge.FieldText([]int{7}, 0, 23), "7")
	eq(t, "none", bridge.FieldText(nil, 1, 31), "")
	eq(t, "every", bridge.EveryText(90*time.Minute), "every 1h30m")
	eq(t, "days", bridge.EveryText(36*time.Hour+1500*time.Millisecond), "every 1d12h1s500ms")
}

func TestFuncName(t *testing.T) {
	for full, want := range map[string]string{
		"github.com/acme/app/jobs.NightlyReport":      "jobs.NightlyReport",
		"github.com/acme/app/jobs.(*Reporter).Run-fm": "jobs.Reporter.Run",
		"main.cleanup":   "main.cleanup",
		"nightly-report": "nightly-report",
	} {
		got, err := bridge.FuncName(full)
		if err != nil || got != want {
			t.Errorf("%s: got %q %v, want %q", full, got, err, want)
		}
	}
	for _, full := range []string{"main.main.func1", "github.com/acme/app/jobs.init.0.func2", "jobs.glob..func1", "Nightly Report"} {
		if _, err := bridge.FuncName(full); err == nil {
			t.Errorf("%s: taken", full)
		}
	}
}

func newClient(t *testing.T, store cronwatch.Store) (*cronwatch.Client, *storetest.Errors) {
	t.Helper()
	errs := &storetest.Errors{}
	cw, err := cronwatch.New(cronwatch.WithStore(store), cronwatch.WithErrorHandler(errs.Add))
	if err != nil {
		t.Fatal(err)
	}
	return cw, errs
}

func stored(t *testing.T, store cronwatch.Store, name string) string {
	t.Helper()
	job, err := store.GetJob(context.Background(), name)
	if err != nil || job == nil {
		t.Fatalf("%s is not stored (%v)", name, err)
	}
	b, _ := job.Definition.MarshalJSON()
	return string(b)
}

func check(t *testing.T, cw *cronwatch.Client) {
	t.Helper()
	if _, err := cw.Check(context.Background()); err != nil {
		t.Fatal(err)
	}
}

func TestWatchDeclaresEntriesAndUnschedulesTheGone(t *testing.T) {
	store := cronwatch.NewMemoryStore()
	cw, errs := newClient(t, store)
	w := bridge.NewWatch(cw, "gocron", "billing", "gocron")
	w.Declare([]bridge.Entry{
		{Name: "nightly", Where: "entry 1", Schedule: "0 2 * * *", Timezone: "UTC",
			Defaults: []cronwatch.JobOption{cronwatch.Grace("5m")},
			Options:  []cronwatch.JobOption{cronwatch.Budget("cost", 2), cronwatch.Tags("reports")}},
		{Name: "twice", Where: "entry 2", Schedule: "0 3 * * *"},
		{Name: "twice", Where: "entry 3", Schedule: "0 4 * * *"},
		{Name: "odd", Where: "entry 4", Problem: errors.New("cronwatch: entry 4 cannot be read")},
	})
	check(t, cw)
	eq(t, "nightly", stored(t, store, "nightly"), `{"grace":"5m","schedule":"0 2 * * *","timezone":"UTC","budget":{"cost":2},"tags":["reports","gocron","gocron:billing"],"name":"nightly"}`)
	eq(t, "twice", stored(t, store, "twice"), `{"tags":["gocron","gocron:billing"],"name":"twice"}`)
	eq(t, "odd", stored(t, store, "odd"), `{"tags":["gocron","gocron:billing"],"name":"odd"}`)
	eq(t, "reported", strings.Join(errs.List(), "\n"), `declaring entry 2: cronwatch: "twice" is run by 2 gocron entries on different schedules (0 3 * * *; 0 4 * * *), so it is watched without a schedule; give each a name of its own`+"\n"+
		`declaring entry 4: cronwatch: entry 4 cannot be read`)

	// Declaring again changes nothing and reports nothing again; an entry
	// gone keeps its runs and loses its schedule.
	first := w.Job("nightly")
	w.Declare([]bridge.Entry{
		{Name: "nightly", Where: "entry 1", Schedule: "0 2 * * *", Timezone: "UTC",
			Defaults: []cronwatch.JobOption{cronwatch.Grace("5m")},
			Options:  []cronwatch.JobOption{cronwatch.Budget("cost", 2), cronwatch.Tags("reports")}},
		{Name: "twice", Where: "entry 2", Schedule: "0 3 * * *"},
		{Name: "twice", Where: "entry 3", Schedule: "0 4 * * *"},
	})
	eq(t, "the same job", w.Job("nightly") == first, true)
	eq(t, "reported once", len(errs.List()), 2)
	w.Declare(nil)
	check(t, cw)
	eq(t, "gone", stored(t, store, "nightly"), `{"description":"A scheduled task (no longer scheduled)","tags":["reports","gocron","gocron:billing"],"grace":"5m","budget":{"cost":2},"name":"nightly"}`)
}

func TestUnscheduleTakesOnlyThisAppsJobs(t *testing.T) {
	store := cronwatch.NewMemoryStore()
	ctx := context.Background()
	earlier, _ := newClient(t, store)
	for _, j := range []struct{ name, tag string }{{"invoices", "gocron:billing"}, {"dunning", "gocron:billing"}, {"reindex", "gocron:search"}} {
		if _, err := earlier.Job(j.name, cronwatch.Schedule("0 1 * * *"), cronwatch.Tags("gocron", j.tag), cronwatch.Timeout("2h"), cronwatch.Description("Bills")); err != nil {
			t.Fatal(err)
		}
	}
	check(t, earlier)

	cw, _ := newClient(t, store)
	w := bridge.NewWatch(cw, "gocron", "billing", "gocron")
	// Before the watch has seen its scheduler, it takes nothing.
	names, err := w.Unschedule(ctx)
	if err != nil || len(names) != 0 {
		t.Fatalf("a watch that saw no entry unscheduled %v (%v)", names, err)
	}
	w.Declare([]bridge.Entry{{Name: "invoices", Where: "x", Schedule: "0 1 * * *"}})
	names, err = w.Unschedule(ctx)
	if err != nil {
		t.Fatal(err)
	}
	eq(t, "names", strings.Join(names, ","), "dunning")
	check(t, cw)
	eq(t, "dunning", stored(t, store, "dunning"), `{"description":"Bills (no longer scheduled)","tags":["gocron","gocron:billing"],"timeout":"2h","name":"dunning"}`)
	eq(t, "reindex is search's", strings.Contains(stored(t, store, "reindex"), `"schedule":"0 1 * * *"`), true)
	eq(t, "invoices kept", strings.Contains(stored(t, store, "invoices"), `"schedule":"0 1 * * *"`), true)
}

func TestFallbackKeepsTheStoredDefinition(t *testing.T) {
	store := cronwatch.NewMemoryStore()
	scheduler, _ := newClient(t, store)
	if _, err := scheduler.Job("report", cronwatch.Grace("5m"), cronwatch.Schedule("0 2 * * *"), cronwatch.Timezone("UTC"), cronwatch.Timeout(7200000),
		cronwatch.MaxDuration("30m"), cronwatch.Budget("cost", 2), cronwatch.Budget("rows", 10), cronwatch.FailuresBeforeAlert(2),
		cronwatch.Description("Nightly"), cronwatch.Tags("river", "river:billing"), cronwatch.Expect("Report written")); err != nil {
		t.Fatal(err)
	}
	check(t, scheduler)
	before := stored(t, store, "report")

	worker, _ := newClient(t, store)
	w := bridge.NewWatch(worker, "river", "billing", "River")
	job := w.Fallback(context.Background(), "report", nil)
	if job == nil {
		t.Fatal("no job")
	}
	eq(t, "the same definition", string(must(job.Definition().MarshalJSON())), before)
	eq(t, "once", w.Fallback(context.Background(), "report", nil) == job, true)
	check2(t, job.Run(context.Background(), func(ctx context.Context, j *cronwatch.JobContext) error { return nil }))
	eq(t, "the expect rule holds in the worker too", func() string {
		runs, _ := worker.Runs(context.Background(), "report", 1)
		return *runs[0].Error
	}(), `Output did not contain "Report written"`)
	eq(t, "the stored definition is unchanged", stored(t, store, "report"), before)

	// A job of another app's is not taken for this one's.
	other := bridge.NewWatch(worker, "river", "search", "River")
	made := other.Fallback(context.Background(), "report", []cronwatch.JobOption{cronwatch.Grace("1m")})
	eq(t, "its own options", string(must(made.Definition().MarshalJSON())), `{"grace":"1m","tags":["river","river:search"],"name":"report"}`)
}

func TestOptionsOfRebuildsAnExpectPattern(t *testing.T) {
	def := cronwatch.DescribeJob("x", cronwatch.ExpectMatch(regexp.MustCompile(`(?i)done \d+`)))
	rebuilt := cronwatch.DescribeJob("x", bridge.OptionsOf(def)...)
	eq(t, "matches", string(must(rebuilt.MarshalJSON())), string(must(def.MarshalJSON())))
	custom := cronwatch.DescribeJob("x", cronwatch.ExpectFunc(func(string) bool { return false }))
	eq(t, "custom", string(must(cronwatch.DescribeJob("x", bridge.OptionsOf(custom)...).MarshalJSON())), `{"name":"x","expect":"custom function"}`)
}

func must(b []byte, err error) []byte {
	if err != nil {
		panic(err)
	}
	return b
}

func eq[T comparable](t *testing.T, what string, got, want T) {
	t.Helper()
	if got != want {
		t.Errorf("%s:\n got %v\nwant %v", what, got, want)
	}
}

func check2(t *testing.T, err error) {
	t.Helper()
	if err != nil {
		t.Fatal(err)
	}
}
