package pgcron_test

// An app's Pick, JobName or OptionsFor that fails, as the SDK's
// pgcron.test.ts has it.

import (
	"errors"
	"regexp"
	"strconv"
	"sync"
	"testing"

	cronwatch "cronwatch.dev/go"
	"cronwatch.dev/go/internal/js"
	"cronwatch.dev/go/pgcron"
	"cronwatch.dev/go/storetest"
)

func TestACallbackThatFailsFailsOnlyItsJobReportedOnce(t *testing.T) {
	c := storetest.NewClock(T0)
	cron := newFakeCron()
	cron.job(1, name("one"), "0 * * * *", true)
	cron.job(2, name("two"), "0 * * * *", true)
	cron.job(3, name("three"), "0 * * * *", true)
	cron.job(4, name("four"), "0 * * * *", true)
	var mu sync.Mutex
	broken := map[string]bool{}
	fault := func(what string, jobid int64) bool {
		mu.Lock()
		defer mu.Unlock()
		return broken[what+":"+strconv.FormatInt(jobid, 10)]
	}
	set := func(keys ...string) {
		mu.Lock()
		defer mu.Unlock()
		broken = map[string]bool{}
		for _, k := range keys {
			broken[k] = true
		}
	}
	store := cronwatch.NewMemoryStore()
	k := newKit(t, cron, c, store, pgcron.Options{
		Pick: func(j pgcron.Job) bool {
			if fault("pick", j.JobID) {
				panic("pick broke")
			}
			return true
		},
		JobName: func(j pgcron.Job) string {
			if fault("panic", j.JobID) {
				panic(errors.New("name broke"))
			}
			if fault("empty", j.JobID) {
				return ""
			}
			return "j-" + *j.JobName
		},
		OptionsFor: func(j pgcron.Job) []cronwatch.JobOption {
			if fault("options", j.JobID) {
				panic("options broke")
			}
			return nil
		},
	})
	jobNames := func() []string {
		jobs, err := store.ListJobs(bg)
		if err != nil {
			t.Fatal(err)
		}
		out := []string{}
		for _, j := range jobs {
			out = append(out, j.Name)
		}
		return out
	}
	id := func(d *detail) string { return "pgcron:" + js.FormatNumber(float64(d.runid)) }
	notice := func(n int, what string) string {
		return "source pg_cron: pg_cron job " + strconv.Itoa(n) + ": " + what + "; it keeps its last declaration until that works"
	}

	// First sight, with job 1's name callback panicking and job 2's giving no name: only those two are skipped.
	set("panic:1", "empty:2")
	first := cron.add(3, "succeeded", T0-60_000, T0-59_000, "ok")
	k.check(t)
	sameList(t, "declared", jobNames(), []string{"j-four", "j-three"})
	same(t, "copied", k.run(t, id(first)).Job, "j-three")
	sameList(t, "reported", k.others(), []string{notice(1, "JobName panicked: name broke"), notice(2, "JobName returned no name")})

	// Once they work, both are declared; then every callback fails in turn for jobs already declared.
	set()
	k.check(t)
	sameList(t, "declared", jobNames(), []string{"j-four", "j-one", "j-three", "j-two"})
	set("pick:1", "empty:2", "options:3", "panic:4")
	before := len(k.others())
	later := []*detail{cron.add(1, "failed", T0+1000, T0+2000, "ERROR:  one"), cron.add(3, "succeeded", T0+1000, T0+2000, "ok")}
	c.Advance(5000)
	k.check(t)
	k.check(t)
	sameList(t, "each reported once, over two syncs", k.others()[before:], []string{
		notice(1, "Pick panicked: pick broke"),
		notice(2, "JobName returned no name"),
		notice(3, "OptionsFor panicked: options broke"),
		notice(4, "JobName panicked: name broke"),
	})
	// Each keeps its name and schedule, is not retired, and its runs are still copied.
	jobs, err := store.ListJobs(bg)
	if err != nil {
		t.Fatal(err)
	}
	for _, j := range jobs {
		same(t, j.Name+" schedule", j.Definition.Schedule(), "0 * * * *")
		description, _ := j.Definition.Get("description")
		if text, _ := description.(string); regexp.MustCompile(`no longer|renamed`).MatchString(text) {
			t.Errorf("%s retired: %s", j.Name, text)
		}
	}
	same(t, "job 1's run", k.run(t, id(later[0])).Job, "j-one")
	same(t, "job 3's run", k.run(t, id(later[1])).Job, "j-three")

	// Working again and then failing again is reported again.
	set()
	k.check(t)
	set("pick:1")
	k.check(t)
	all := k.others()
	same(t, "reports", len(all), 7)
	same(t, "again", all[len(all)-1], notice(1, "Pick panicked: pick broke"))
}
