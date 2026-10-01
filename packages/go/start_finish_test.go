package cronwatch_test

// start-finish.test.ts, and the tests of finish-once.test.ts after its
// three backend loops (those are storetest.FinishOnce, in store_test.go).
// The resume-in-a-second-client case runs here on the memory store; the
// SQL stores run it in the sqltest module.

import (
	"context"
	"errors"
	"net/http"
	"regexp"
	"strconv"
	"strings"
	"sync"
	"testing"
	"testing/synctest"
	"time"

	cronwatch "cronwatch.dev/go"
)

func TestStartRecordsARunningRunAndFinishRecordsItOK(t *testing.T) {
	k := newKit(t)
	job := k.cw.MustJob("sync", cronwatch.Schedule("@hourly"))
	run := must[*cronwatch.RunHandle](t)(job.Start(bg, cronwatch.WithTrigger("queue")))
	eq(t, "job", run.Job(), "sync")
	eq(t, "active", run.Active(), true)
	stored := must[*cronwatch.Run](t)(k.cw.GetRun(bg, run.ID()))
	eq(t, "status", stored.Status, cronwatch.StatusRunning)
	eq(t, "trigger", stored.Trigger, "queue")
	run.Log("imported", 12, "rows")
	check(t, run.Metric("rows", 12))
	k.c.Advance(90_000)
	finished := run.Finish(bg)
	eq(t, "status", finished.Status, cronwatch.StatusOK)
	eq(t, "duration", *finished.DurationMs, int64(90_000))
	eq(t, "active", run.Active(), false)
	recorded := runs(t, k.cw, "sync")[0]
	eq(t, "status", recorded.Status, cronwatch.StatusOK)
	eq(t, "output", *recorded.Output, "imported 12 rows")
	eq(t, "metrics", jsonOf(recorded.Metrics), `{"rows":12}`)
	sameList(t, "alerts", k.alerts.Types(), []string{})
	eq(t, "health", summary(t, k.cw, "sync").Health, cronwatch.HealthHealthy)
}

func TestFailRecordsAFailureAndAlertsOnce(t *testing.T) {
	k := newKit(t)
	job := k.cw.MustJob("import", cronwatch.FailuresBeforeAlert(2))
	first := must[*cronwatch.RunHandle](t)(job.Start(bg))
	first.Fail(bg, errors.New("api down"))
	second := must[*cronwatch.RunHandle](t)(job.Start(bg))
	run := second.Fail(bg, errors.New("still down"))
	eq(t, "status", run.Status, cronwatch.StatusFailed)
	eq(t, "error", *run.Error, "Error: still down")
	sameList(t, "alerts", k.alerts.Types(), []string{"failed"})
	third := must[*cronwatch.RunHandle](t)(job.Start(bg, cronwatch.WithTrigger("retry")))
	third.Finish(bg)
	sameList(t, "alerts", k.alerts.Types(), []string{"failed", "recovered"})
}

func TestASecondFinishIsIgnoredAndReported(t *testing.T) {
	k := newKit(t)
	job := k.cw.MustJob("once")
	run := must[*cronwatch.RunHandle](t)(job.Start(bg))
	a := run.Fail(bg, errors.New("boom"))
	b := run.Finish(bg)
	eq(t, "fail", a.Status, cronwatch.StatusFailed)
	eq(t, "second", b == nil, true)
	eq(t, "third", run.Finish(bg) == nil, true)
	sameList(t, "alerts", k.alerts.Types(), []string{"failed"})
	eq(t, "stored", runs(t, k.cw, "once")[0].Status, cronwatch.StatusFailed)
	msgs := k.messages()
	eq(t, "errors", len(msgs), 2)
	if !strings.Contains(msgs[0], "was already finished by this handle; ignored") {
		t.Error(msgs[0])
	}
	eq(t, "where", k.wheres()[0], "finishing once")
}

func TestConcurrentFinishesOfOneHandleRecordOne(t *testing.T) {
	k := newKit(t)
	run := must[*cronwatch.RunHandle](t)(k.cw.MustJob("once").Start(bg))
	results := make([]*cronwatch.Run, 8)
	var wg sync.WaitGroup
	for i := range results {
		wg.Add(1)
		go func() { defer wg.Done(); results[i] = run.FinishWith(bg, "done") }()
	}
	wg.Wait()
	n := 0
	for _, r := range results {
		if r != nil {
			n++
		}
	}
	eq(t, "recorded", n, 1)
	eq(t, "reported", len(k.errors.List()), 7)
}

func TestStartWithAnIDTwiceRecordsOneRun(t *testing.T) {
	k := newKit(t)
	job := k.cw.MustJob("inngest-fn")
	handles := make([]*cronwatch.RunHandle, 2)
	var wg sync.WaitGroup
	for i := range handles {
		wg.Add(1)
		go func() {
			defer wg.Done()
			handles[i] = must[*cronwatch.RunHandle](t)(job.Start(bg, cronwatch.WithRunID("01HX-run")))
		}()
	}
	wg.Wait()
	one, two := handles[0], handles[1]
	eq(t, "one", one.ID(), "01HX-run")
	eq(t, "two", two.ID(), "01HX-run")
	again := must[*cronwatch.RunHandle](t)(job.Start(bg, cronwatch.WithRunID("01HX-run"), cronwatch.WithTrigger("ignored")))
	eq(t, "active", again.Active(), true)
	eq(t, "runs", len(runs(t, k.cw, "inngest-fn")), 1)
	eq(t, "trigger", must[*cronwatch.Run](t)(k.cw.GetRun(bg, "01HX-run")).Trigger, "start")
	again.FinishWith(bg, "done")
	// Finished elsewhere: this handle's finish is a reported no-op.
	eq(t, "no-op", one.Finish(bg) == nil, true)
	msgs := k.messages()
	if !strings.Contains(msgs[len(msgs)-1], "already finished as ok; ignored") {
		t.Error(msgs)
	}
	late := must[*cronwatch.RunHandle](t)(job.Start(bg, cronwatch.WithRunID("01HX-run")))
	eq(t, "late", late.Active(), false)
	eq(t, "late finish", late.Finish(bg) == nil, true)
	eq(t, "runs", len(runs(t, k.cw, "inngest-fn")), 1)
	if _, err := k.cw.MustJob("other").Start(bg, cronwatch.WithRunID("01HX-run")); err == nil || !strings.Contains(err.Error(), `belongs to job "inngest-fn"`) {
		t.Error(err)
	}
	if _, err := job.Start(bg, cronwatch.WithRunID("")); err == nil || err.Error() != `job "inngest-fn": start() needs a run id of 1 to 200 characters (got 0 characters)` {
		t.Error(err)
	}
	if err := job.Run(bg, ok, cronwatch.WithRunID("x")); err == nil || !strings.Contains(err.Error(), "WithRunID is for Start") {
		t.Error(err)
	}
	// No store could hold a NUL (Postgres refuses it), so such an id is refused wherever one is taken.
	if _, err := job.Start(bg, cronwatch.WithRunID("01HX\x00run")); err == nil || err.Error() != `job "inngest-fn": start() cannot take a run id containing a NUL character` {
		t.Error(err)
	}
	if _, err := job.Resume(bg, "01HX\x00run"); err == nil || err.Error() != `job "inngest-fn": resume() cannot take a run id containing a NUL character` {
		t.Error(err)
	}
	nul := cronwatch.Run{ID: "x\x00y", Job: "inngest-fn", Status: cronwatch.StatusOK, StartedAt: 1, FinishedAt: ptr(int64(2)), DurationMs: ptr(int64(1)), Metrics: cronwatch.Metrics{}, Trigger: "run"}
	if _, err := k.cw.RecordRun(bg, nul); err == nil || err.Error() != `recordRun: run ids cannot contain a NUL character (job "inngest-fn")` {
		t.Error(err)
	}
	eq(t, "runs", len(runs(t, k.cw, "inngest-fn")), 1)
}

func TestResumeInASecondClientAppendsAndFinishes(t *testing.T) {
	store := cronwatch.NewMemoryStore()
	c := storeClock()
	alerts := &captureOf{}
	var mu sync.Mutex
	var errs []error
	onError := func(err error, _ string) { mu.Lock(); errs = append(errs, err); mu.Unlock() }
	first := cronwatch.MustNew(cronwatch.WithStore(store), cronwatch.WithClock(c.Now), cronwatch.WithAlerts(alerts), cronwatch.WithoutCronSecret(), cronwatch.WithErrorHandler(onError))
	second := cronwatch.MustNew(cronwatch.WithStore(store), cronwatch.WithClock(c.Now), cronwatch.WithAlerts(alerts), cronwatch.WithoutCronSecret(), cronwatch.WithErrorHandler(onError))
	options := []cronwatch.JobOption{cronwatch.Expect("sent"), cronwatch.Budget("emails", 100)}
	started := must[*cronwatch.RunHandle](t)(first.MustJob("digest", options...).Start(bg, cronwatch.WithRunID("evt-1")))
	started.Log("loaded 40 recipients")
	started.Log("token=abc123")
	check(t, started.Metric("recipients", 40))
	started.Flush(bg)
	midway := must[*cronwatch.Run](t)(first.GetRun(bg, "evt-1"))
	eq(t, "status", midway.Status, cronwatch.StatusRunning)
	eq(t, "output", *midway.Output, "loaded 40 recipients\ntoken=[redacted]")

	c.Advance(5 * MIN)
	second.MustJob("digest", options...)
	resumed := must[*cronwatch.RunHandle](t)(second.ResumeRun(bg, "digest", "evt-1"))
	eq(t, "active", resumed.Active(), true)
	at, known := resumed.StartedAt()
	eq(t, "startedAt", at, midway.StartedAt)
	eq(t, "known", known, true)
	resumed.Log("sent 40 emails")
	check(t, resumed.Metric("emails", 40))
	run := resumed.Finish(bg)
	eq(t, "status", run.Status, cronwatch.StatusOK)
	eq(t, "duration", *run.DurationMs, 5*MIN)
	stored := must[*cronwatch.Run](t)(first.GetRun(bg, "evt-1"))
	eq(t, "status", stored.Status, cronwatch.StatusOK)
	eq(t, "output", *stored.Output, "loaded 40 recipients\ntoken=[redacted]\nsent 40 emails")
	eq(t, "metrics", jsonOf(stored.Metrics), `{"recipients":40,"emails":40}`)
	sameList(t, "alerts", alerts.types(), []string{})
	eq(t, "errors", len(errs), 0)
	check(t, first.Close())
	check(t, second.Close())
}

func TestResumeOfAnUnknownOrFinishedRun(t *testing.T) {
	k := newKit(t)
	job := k.cw.MustJob("webhook")
	missing := must[*cronwatch.RunHandle](t)(job.Resume(bg, "nope"))
	eq(t, "active", missing.Active(), false)
	_, known := missing.StartedAt()
	eq(t, "startedAt", known, false)
	missing.Log("dropped")
	missing.Flush(bg)
	eq(t, "finish", missing.Finish(bg) == nil, true)
	if msgs := k.messages(); !strings.Contains(msgs[0], "run nope of webhook was not found; ignored") {
		t.Error(msgs)
	}
	check(t, job.Run(bg, ok))
	done := runs(t, k.cw, "webhook")[0]
	finished := must[*cronwatch.RunHandle](t)(job.Resume(bg, done.ID))
	eq(t, "active", finished.Active(), false)
	eq(t, "fail", finished.Fail(bg, errors.New("late")) == nil, true)
	if msgs := k.messages(); !strings.Contains(msgs[1], "already finished as ok; ignored") {
		t.Error(msgs)
	}
	eq(t, "status", runs(t, k.cw, "webhook")[0].Status, cronwatch.StatusOK)
	if _, err := k.cw.ResumeRun(bg, "undeclared", "x"); err == nil || !strings.Contains(err.Error(), "not declared") {
		t.Error(err)
	}
}

func TestARunNeverFinishedIsMarkedStuck(t *testing.T) {
	k := newKit(t)
	job := k.cw.MustJob("callback", cronwatch.Timeout("30m"))
	run := must[*cronwatch.RunHandle](t)(job.Start(bg))
	k.c.Advance(29 * MIN)
	checkNow(t, k.cw)
	eq(t, "still running", must[*cronwatch.Run](t)(k.cw.GetRun(bg, run.ID())).Status, cronwatch.StatusRunning)
	k.c.Advance(2 * MIN)
	checkNow(t, k.cw)
	stored := must[*cronwatch.Run](t)(k.cw.GetRun(bg, run.ID()))
	eq(t, "status", stored.Status, cronwatch.StatusTimeout)
	if !strings.Contains(*stored.Error, "Still running after 30m") {
		t.Error(*stored.Error)
	}
	sameList(t, "alerts", k.alerts.Types(), []string{"stuck"})
}

func TestLinesFlushedWhileACheckMarksEarlierRunsStuckAreKept(t *testing.T) {
	entered, gate := make(chan struct{}), make(chan struct{})
	var once sync.Once
	held := cronwatch.ChannelFunc("held", func(context.Context, cronwatch.Alert) error {
		once.Do(func() { close(entered); <-gate })
		return nil
	})
	k := newKit(t, cronwatch.WithAlerts(held))
	first := must[*cronwatch.RunHandle](t)(k.cw.MustJob("first", cronwatch.Timeout("30m")).Start(bg))
	k.c.Advance(1000)
	second := must[*cronwatch.RunHandle](t)(k.cw.MustJob("second", cronwatch.Timeout("30m")).Start(bg))
	second.Log("early line")
	check(t, second.Metric("rows", 1))
	second.Flush(bg)
	k.c.Advance(31 * MIN)
	done := make(chan struct{})
	go func() { defer close(done); _, _ = k.cw.Check(bg) }()
	// The first stuck run's alert is being sent; the second is still running, and flushes.
	<-entered
	second.Log("important progress line")
	check(t, second.Metric("rows", 2))
	second.Flush(bg)
	close(gate)
	<-done
	stored := must[*cronwatch.Run](t)(k.cw.GetRun(bg, second.ID()))
	eq(t, "status", stored.Status, cronwatch.StatusTimeout)
	eq(t, "output", *stored.Output, "early line\nimportant progress line")
	eq(t, "metrics", jsonOf(stored.Metrics), `{"rows":2}`)
	eq(t, "first", must[*cronwatch.Run](t)(k.cw.GetRun(bg, first.ID())).Status, cronwatch.StatusTimeout)
}

// closeWatched is a memory store that notes when it is closed.
type closeWatched struct {
	*cronwatch.MemoryStore
	note func(string)
}

func (s *closeWatched) Close() error {
	s.note("close")
	return s.MemoryStore.Close()
}

func TestCloseWaitsForACheckUnderWayBeforeItClosesTheStore(t *testing.T) {
	for _, by := range []string{"a caller", "the interval"} {
		t.Run(by, func(t *testing.T) {
			synctest.Test(t, func(t *testing.T) {
				var mu sync.Mutex
				order := []string{}
				note := func(what string) {
					mu.Lock()
					defer mu.Unlock()
					order = append(order, what)
				}
				entered, gate := make(chan struct{}), make(chan struct{})
				var once sync.Once
				held := cronwatch.ChannelFunc("held", func(context.Context, cronwatch.Alert) error {
					once.Do(func() { close(entered); <-gate })
					note("send")
					return nil
				})
				store := &closeWatched{MemoryStore: cronwatch.NewMemoryStore(), note: note}
				k := newKit(t, cronwatch.WithStore(store), cronwatch.WithAlerts(held))
				must[*cronwatch.RunHandle](t)(k.cw.MustJob("callback", cronwatch.Timeout("30m")).Start(bg))
				k.c.Advance(31 * MIN)
				var wg sync.WaitGroup
				if by == "a caller" {
					wg.Go(func() { _, _ = k.cw.Check(bg) })
				} else {
					k.cw.StartChecking(time.Minute)
					time.Sleep(2 * time.Second)
				}
				<-entered
				closed := make(chan error, 1)
				wg.Go(func() { closed <- k.cw.Close() })
				synctest.Wait()
				select {
				case <-closed:
					t.Fatal("Close returned while the check was sending")
				default:
				}
				mu.Lock()
				sameList(t, "nothing yet", order, []string{})
				mu.Unlock()
				close(gate)
				wg.Wait()
				check(t, <-closed)
				sameList(t, "order", order, []string{"send", "close"})
			})
		})
	}
}

func TestALateSuccessAfterATimeoutMarkRecovers(t *testing.T) {
	k := newKit(t)
	job := k.cw.MustJob("slowpoke", cronwatch.Timeout("10m"), cronwatch.FailuresBeforeAlert(2))
	first := must[*cronwatch.RunHandle](t)(job.Start(bg))
	k.c.Advance(11 * MIN)
	checkNow(t, k.cw)
	sameList(t, "under the threshold", k.alerts.Types(), []string{})
	failed := first.Fail(bg, errors.New("gave up"))
	eq(t, "status", failed.Status, cronwatch.StatusFailed)
	eq(t, "the run keeps its real error", strings.Split(*must[*cronwatch.Run](t)(k.cw.GetRun(bg, first.ID())).Error, "\n")[0], "Error: gave up")
	sameList(t, "the late failure did not count as a second one", k.alerts.Types(), []string{})

	second := must[*cronwatch.RunHandle](t)(job.Start(bg))
	k.c.Advance(11 * MIN)
	checkNow(t, k.cw)
	sameList(t, "stuck", k.alerts.Types(), []string{"stuck"})
	resumed := must[*cronwatch.RunHandle](t)(k.cw.ResumeRun(bg, "slowpoke", second.ID()))
	eq(t, "a run marked timeout can still be finished late", resumed.Active(), true)
	late := resumed.Finish(bg)
	eq(t, "late", late.Status, cronwatch.StatusOK)
	sameList(t, "recovered", k.alerts.Types(), []string{"stuck", "recovered"})
	eq(t, "the handle that started it sees it finished elsewhere", second.Finish(bg) == nil, true)
}

func TestExpectIsAppliedAtFinish(t *testing.T) {
	k := newKit(t)
	job := k.cw.MustJob("export", cronwatch.ExpectMatch(regexp.MustCompile(`wrote \d+ files`)))
	quiet := must[*cronwatch.RunHandle](t)(job.Start(bg))
	run := quiet.FinishWith(bg, "nothing to do")
	eq(t, "status", run.Status, cronwatch.StatusFailed)
	eq(t, "output", *run.Output, "nothing to do")
	eq(t, "error", *run.Error, `Output did not match /wrote \d+ files/`)
	sameList(t, "alerts", k.alerts.Types(), []string{"failed"})

	busy := must[*cronwatch.RunHandle](t)(job.Start(bg))
	busy.Log("wrote 3 files")
	busy.Flush(bg)
	resumed := must[*cronwatch.RunHandle](t)(job.Resume(bg, busy.ID()))
	eq(t, "lines flushed earlier count toward expect", resumed.FinishWith(bg, "uploaded").Status, cronwatch.StatusOK)
	sameList(t, "alerts", k.alerts.Types(), []string{"failed", "recovered"})

	h := must[*cronwatch.RunHandle](t)(job.Start(bg))
	bad := h.FinishWith(bg, &http.Response{StatusCode: 502})
	eq(t, "error", *bad.Error, "HTTP 502")
	h2 := must[*cronwatch.RunHandle](t)(job.Start(bg))
	bad2 := h2.FinishWith(bg, &http.Response{StatusCode: 503, Status: "503 Service Unavailable"})
	eq(t, "error with its reason", *bad2.Error, "HTTP 503 Service Unavailable")
}

func TestAStoreFailingDuringStartDoesNotThrow(t *testing.T) {
	store := newTestStore()
	store.breaks("InsertRun")
	k := newKit(t, cronwatch.WithStore(store))
	job := k.cw.MustJob("backup", cronwatch.Schedule("@hourly"))
	run := must[*cronwatch.RunHandle](t)(job.Start(bg))
	eq(t, "active", run.Active(), true)
	eq(t, "where", k.wheres()[0], "recording backup")
	eq(t, "not stored", must[*cronwatch.Run](t)(k.cw.GetRun(bg, run.ID())) == nil, true)
	run.Log("copied")
	run.Flush(bg) // nothing stored to append to; kept for finish
	store.mends()
	k.c.Advance(HOUR / 2)
	finished := run.Finish(bg)
	eq(t, "status", finished.Status, cronwatch.StatusOK)
	stored := must[*cronwatch.Run](t)(k.cw.GetRun(bg, run.ID()))
	eq(t, "status", stored.Status, cronwatch.StatusOK)
	eq(t, "output", *stored.Output, "copied")
	eq(t, "duration", *stored.DurationMs, HOUR/2)
	sameList(t, "alerts", k.alerts.Types(), []string{})
}

func TestAStoreFailingAtFinishLeavesTheHandleToFinishAgain(t *testing.T) {
	store := newTestStore()
	k := newKit(t, cronwatch.WithStore(store))
	job := k.cw.MustJob("flaky")
	run := must[*cronwatch.RunHandle](t)(job.Start(bg))
	run.Log("working")
	store.breaks("GetRun", "UpdateRun", "UpdateRunIf")
	run.Flush(bg)
	wheres := k.wheres()
	eq(t, "flush", wheres[len(wheres)-1], "flushing flaky")
	eq(t, "nothing recorded", run.Finish(bg) == nil, true)
	sameList(t, "finish", k.wheres()[len(wheres):], []string{"finishing flaky"})
	eq(t, "still active, to finish again", run.Active(), true)
	// The read works but the write fails: still retryable.
	store.mends("GetRun")
	eq(t, "still nothing", run.Finish(bg) == nil, true)
	eq(t, "active", run.Active(), true)
	store.mends()
	eq(t, "nothing written yet", must[*cronwatch.Run](t)(k.cw.GetRun(bg, run.ID())).Status, cronwatch.StatusRunning)
	finished := run.Finish(bg)
	eq(t, "status", finished.Status, cronwatch.StatusOK)
	eq(t, "the lines logged before the failures are kept", *finished.Output, "working")
	eq(t, "active", run.Active(), false)
	eq(t, "finished once only", run.Finish(bg) == nil, true)
}

// ---- finish-once.test.ts, after its backend loops

func TestAStoreWithoutUpdateRunIfFallsBackToAReadAndAWrite(t *testing.T) {
	inner := cronwatch.NewMemoryStore()
	k := newKit(t, cronwatch.WithStore(noRunIf{inner, inner}))
	job := k.cw.MustJob("plain")
	h := must[*cronwatch.RunHandle](t)(job.Start(bg, cronwatch.WithRunID("p1")))
	eq(t, "status", h.FinishWith(bg, "done").Status, cronwatch.StatusOK)
	again := must[*cronwatch.RunHandle](t)(job.Resume(bg, "p1")).FinishWith(bg, "again")
	eq(t, "ignored", again == nil, true)
	found := false
	for _, m := range k.messages() {
		found = found || strings.Contains(m, "already finished")
	}
	eq(t, "reported", found, true)
}

func TestRecordRunTakesTheLateFinishOfARunMarkedTimeout(t *testing.T) {
	k := newKit(t)
	k.c.Set(1767236400000) // 2026-01-01 03:00Z
	k.cw.MustJob("db:vacuum", cronwatch.Schedule("0 3 * * *"), cronwatch.Timeout("30m"))
	base := func(id string, at int64, status cronwatch.RunStatus) cronwatch.Run {
		return cronwatch.Run{ID: id, Job: "db:vacuum", Status: status, StartedAt: at, Metrics: cronwatch.Metrics{}, Trigger: "pg_cron"}
	}
	start := k.c.Now()
	must[[]cronwatch.Alert](t)(k.cw.RecordRun(bg, base("pgcron:77", start, cronwatch.StatusRunning)))
	k.c.Advance(45 * MIN)
	checkNow(t, k.cw)
	eq(t, "timeout", must[*cronwatch.Run](t)(k.cw.GetRun(bg, "pgcron:77")).Status, cronwatch.StatusTimeout)
	k.c.Advance(15 * MIN)
	done := base("pgcron:77", start, cronwatch.StatusOK)
	done.FinishedAt, done.DurationMs, done.Output = ptr(k.c.Now()-5*MIN), ptr(55*MIN), ptr("VACUUM")
	must[[]cronwatch.Alert](t)(k.cw.RecordRun(bg, done))
	checkNow(t, k.cw)
	run := must[*cronwatch.Run](t)(k.cw.GetRun(bg, "pgcron:77"))
	eq(t, "status", run.Status, cronwatch.StatusOK)
	eq(t, "output", *run.Output, "VACUUM")
	eq(t, "health", summary(t, k.cw, "db:vacuum").Health, cronwatch.HealthHealthy)
	sameList(t, "alerts", k.alerts.Types(), []string{"stuck", "recovered"})

	// A late failure is written but not counted twice.
	other := base("pgcron:78", k.c.Now(), cronwatch.StatusRunning)
	must[[]cronwatch.Alert](t)(k.cw.RecordRun(bg, other))
	k.c.Advance(45 * MIN)
	checkNow(t, k.cw)
	other.Status, other.FinishedAt, other.DurationMs, other.Error = cronwatch.StatusFailed, ptr(k.c.Now()), ptr(45*MIN), ptr("ERROR: canceled")
	must[[]cronwatch.Alert](t)(k.cw.RecordRun(bg, other))
	eq(t, "status", must[*cronwatch.Run](t)(k.cw.GetRun(bg, "pgcron:78")).Status, cronwatch.StatusFailed)
	eq(t, "failures", state(t, k.cw, "db:vacuum").ConsecutiveFailures, 1)
	sameList(t, "alerts", k.alerts.Types(), []string{"stuck", "recovered", "stuck"})
}

func TestRecordRunLeavesAStoredRunOfAnotherJobAlone(t *testing.T) {
	k := newKit(t)
	a := k.cw.MustJob("webhook-job")
	k.cw.MustJob("db:nightly")
	h := must[*cronwatch.RunHandle](t)(a.Start(bg, cronwatch.WithRunID("run-43")))
	sent := must[[]cronwatch.Alert](t)(k.cw.RecordRun(bg, cronwatch.Run{ID: "run-43", Job: "db:nightly", Status: cronwatch.StatusOK, StartedAt: T0 - 1000,
		FinishedAt: ptr(T0), DurationMs: ptr(int64(1000)), Metrics: cronwatch.Metrics{}, Trigger: "pg_cron"}))
	eq(t, "sent", len(sent), 0)
	stored := must[*cronwatch.Run](t)(k.cw.GetRun(bg, "run-43"))
	eq(t, "job", stored.Job, "webhook-job")
	eq(t, "status", stored.Status, cronwatch.StatusRunning)
	found := false
	for _, m := range k.messages() {
		found = found || strings.Contains(m, `run-43 of db:nightly belongs to job "webhook-job"; ignored`)
	}
	eq(t, "reported", found, true)
	eq(t, "finish", h.Finish(bg).Status, cronwatch.StatusOK)
	sameList(t, "alerts", k.alerts.Types(), []string{})
	if _, err := k.cw.RecordRun(bg, cronwatch.Run{ID: "x", Job: "undeclared", Status: cronwatch.StatusOK}); err == nil || !strings.Contains(err.Error(), "not declared") {
		t.Error(err)
	}
}

func TestStartAndResumeRefuseThePgCronNamespace(t *testing.T) {
	k := newKit(t)
	job := k.cw.MustJob("webhook-job")
	want := `cannot take a run id starting with "pgcron:"`
	if _, err := job.Start(bg, cronwatch.WithRunID("pgcron:42")); err == nil || !strings.Contains(err.Error(), want) {
		t.Error(err)
	}
	if _, err := job.Resume(bg, "pgcron:42"); err == nil || !strings.Contains(err.Error(), want) {
		t.Error(err)
	}
	if _, err := k.cw.ResumeRun(bg, "webhook-job", "pgcron:db:42"); err == nil || !strings.Contains(err.Error(), "pgcron:") {
		t.Error(err)
	}
	eq(t, "only the prefix with its colon is reserved", must[*cronwatch.RunHandle](t)(job.Start(bg, cronwatch.WithRunID("pgcron-42"))).Active(), true)
}

func TestStartWithAnIDAnotherJobHoldsFails(t *testing.T) {
	k := newKit(t)
	a := k.cw.MustJob("import-a")
	b := k.cw.MustJob("import-b")
	var wg sync.WaitGroup
	errs := make([]error, 2)
	for i, j := range []*cronwatch.Job{a, b} {
		wg.Add(1)
		go func() { defer wg.Done(); _, errs[i] = j.Start(bg, cronwatch.WithRunID("evt_123")) }()
	}
	wg.Wait()
	// The SDK's first call always wins; goroutines may start in either
	// order, so whichever inserted first holds the id, and the other fails.
	owner := must[*cronwatch.Run](t)(k.cw.GetRun(bg, "evt_123")).Job
	loser := map[string]string{"import-a": "import-b", "import-b": "import-a"}[owner]
	want := `belongs to job "` + owner + `", not "` + loser + `"`
	failed := 0
	for _, err := range errs {
		if err != nil {
			failed++
			if !strings.Contains(err.Error(), want) {
				t.Error(err)
			}
		}
	}
	eq(t, "one start failed", failed, 1)
	if _, err := k.cw.MustJob(loser).Start(bg, cronwatch.WithRunID("evt_123")); err == nil || !strings.Contains(err.Error(), want) {
		t.Error(err)
	}
	// The same job at once still shares one start.
	handles := make([]*cronwatch.RunHandle, 2)
	for i := range handles {
		wg.Add(1)
		go func() {
			defer wg.Done()
			handles[i] = must[*cronwatch.RunHandle](t)(a.Start(bg, cronwatch.WithRunID("evt_9")))
		}()
	}
	wg.Wait()
	eq(t, "one run", handles[0].ID(), handles[1].ID())
	eq(t, "runs", len(runs(t, k.cw, "import-a"))+len(runs(t, k.cw, "import-b")), 2)
}

func TestAHandleResumedWhileTheStoreFailedCannotTouchAnotherJobsRun(t *testing.T) {
	store := newTestStore()
	k := newKit(t, cronwatch.WithStore(store))
	billing := k.cw.MustJob("billing")
	webhook := k.cw.MustJob("webhook")
	must[*cronwatch.RunHandle](t)(billing.Start(bg, cronwatch.WithRunID("run-7")))
	store.breaks("GetRun")
	store.hook("GetRun", func() { store.mends("GetRun") }) // this read fails, the next ones work
	h := must[*cronwatch.RunHandle](t)(webhook.Resume(bg, "run-7"))
	eq(t, "unknown yet: the read failed", h.Active(), true)
	h.Log("attacker line")
	h.Flush(bg)
	found := false
	for _, m := range k.messages() {
		found = found || strings.Contains(m, `run-7 of webhook belongs to job "billing"; ignored`)
	}
	eq(t, "reported", found, true)
	eq(t, "finish", h.FinishWith(bg, "ok") == nil, true)
	stored := must[*cronwatch.Run](t)(store.inner.GetRun(bg, "run-7"))
	eq(t, "job", stored.Job, "billing")
	eq(t, "status", stored.Status, cronwatch.StatusRunning)
	eq(t, "output", stored.Output == nil, true)
}

func TestExpectAtFinishSeesAnEarlyLineAfterFlushes(t *testing.T) {
	k := newKit(t)
	job := k.cw.MustJob("export", cronwatch.Expect("connected to warehouse"))
	batch := func(i int) string {
		s := "row batch " + strconv.Itoa(i) + " "
		return s + strings.Repeat(".", 60-len(s))
	}
	check(t, job.Run(bg, func(_ context.Context, j *cronwatch.JobContext) error {
		j.Log("connected to warehouse")
		for i := 0; i < 400; i++ {
			j.Log(batch(i))
		}
		return nil
	}))
	eq(t, "run", runs(t, k.cw, "export")[0].Status, cronwatch.StatusOK)
	h := must[*cronwatch.RunHandle](t)(job.Start(bg))
	h.Log("connected to warehouse")
	for i := 0; i < 400; i++ {
		h.Log(batch(i))
		if i%100 == 99 {
			h.Flush(bg)
		}
	}
	run := h.Finish(bg)
	if run.Status != cronwatch.StatusOK {
		t.Fatal(*run.Error)
	}
	if strings.Contains(*run.Output, "connected to warehouse") {
		t.Error("the stored output kept only the tail")
	}
}

func TestAFlushNeverUndoesAFinishWrittenWhileItRead(t *testing.T) {
	store := newTestStore()
	k := newKit(t, cronwatch.WithStore(store))
	job := k.cw.MustJob("sync")
	h := must[*cronwatch.RunHandle](t)(job.Start(bg, cronwatch.WithRunID("s1")))
	h.Log("halfway")
	other := must[*cronwatch.RunHandle](t)(job.Resume(bg, "s1"))
	// The finish lands between the flush's read and its write.
	store.hookAfter("GetRun", func() { other.FinishWith(bg, "done elsewhere") })
	h.Flush(bg)
	stored := must[*cronwatch.Run](t)(store.inner.GetRun(bg, "s1"))
	eq(t, "still finished", stored.Status, cronwatch.StatusOK)
	eq(t, "output", *stored.Output, "done elsewhere")
}

func TestARunFinishedWhileACheckMarksItTimeoutIsJudgedOnce(t *testing.T) {
	store := newTestStore()
	k := newKit(t, cronwatch.WithStore(store))
	job := k.cw.MustJob("long", cronwatch.Timeout("5m"))
	h := must[*cronwatch.RunHandle](t)(job.Start(bg))
	k.c.Advance(10 * MIN)
	store.hook("RunningRuns", func() { h.FinishWith(bg, "finally") })
	checkNow(t, k.cw)
	eq(t, "status", must[*cronwatch.Run](t)(k.cw.GetRun(bg, h.ID())).Status, cronwatch.StatusOK)
	sameList(t, "not marked stuck over a finish", k.alerts.Types(), []string{})
}
