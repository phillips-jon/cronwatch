package cronwatch_test

//lint:file-ignore SA1019 storetest's helpers are this module's own test kit, deprecated only for apps

// outbox.test.ts: an alert is written with the state that opens its
// condition, sent by the process that wrote it, and by a later check only
// when that process stopped before it recorded how the send went.

import (
	"context"
	"errors"
	"strings"
	"sync"
	"testing"
	"testing/synctest"

	cronwatch "cronwatch.dev/go"
	"cronwatch.dev/go/storetest"
)

// sendLease is the SDK's SEND_LEASE_MS.
const sendLease = 5 * MIN

func quiet(error, string) {}

func TestTheWriteThatOpensAConditionHoldsItsAlert(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		clock := storetest.NewClock(T0)
		shared := cronwatch.NewMemoryStore()
		store := newTestStore()
		store.inner = shared
		triaging := make(chan struct{})
		// The process dies while its triage call is out: no channel was ever called.
		dying := cronwatch.MustNew(cronwatch.WithStore(store), cronwatch.WithClock(clock.Now), cronwatch.WithAlerts(&storetest.Capture{}),
			cronwatch.WithoutCronSecret(), cronwatch.WithErrorHandler(quiet),
			cronwatch.WithTriage(func(ctx context.Context, _ cronwatch.TriageContext) (string, error) {
				store.kill()
				close(triaging)
				<-ctx.Done()
				return "", ctx.Err()
			}))
		var wg sync.WaitGroup
		defer wg.Wait()
		defer store.bury()
		wg.Go(func() { _ = dying.Run(bg, "nightly", fails("disk full")) })
		<-triaging
		state := must[*cronwatch.JobState](t)(shared.GetState(bg, "nightly"))
		eq(t, "open", jsonOf(state.Open), `[{"Condition":"failed","Since":`+jsonOf(T0)+`}]`)
		if len(state.Sending) != 1 || state.Sending[0].Alert.Type != cronwatch.AlertFailed || state.Sending[0].Alert.At != T0 || state.Sending[0].Until != T0+sendLease {
			t.Fatalf("sending: %s", jsonOf(state.Sending))
		}
		if a := state.Sending[0].Alert; a.Triage != nil || a.TriageTried {
			t.Error("triage is made at send time, never stored here")
		}
		eq(t, "undelivered", len(state.Undelivered), 0)

		// Another process's checks leave it alone while its sender's lease runs.
		sent := &storetest.Capture{}
		server := cronwatch.MustNew(cronwatch.WithStore(shared), cronwatch.WithClock(clock.Now), cronwatch.WithAlerts(sent), cronwatch.WithoutCronSecret(),
			cronwatch.WithTriage(func(context.Context, cronwatch.TriageContext) (string, error) { return "The disk is full.", nil }))
		clock.Advance(MIN)
		checkNow(t, server)
		sameList(t, "nothing while the lease runs", sent.Types(), []string{})

		// Once it has run out, the next check sends it, triaged, once.
		clock.Set(T0 + sendLease + 1)
		sameList(t, "sent", alertTypes(checkNow(t, server).Alerts), []string{"failed"})
		got := sent.List()
		if len(got) != 1 || got[0].At != T0 || got[0].Triage == nil || *got[0].Triage != "The disk is full." {
			t.Fatalf("sent: %s", jsonOf(got))
		}
		after := must[*cronwatch.JobState](t)(shared.GetState(bg, "nightly"))
		if after.Sending != nil || len(after.Undelivered) != 0 {
			t.Errorf("after: %s", jsonOf(after))
		}
		if strings.Contains(jsonOf(after), `"sending"`) {
			t.Error("the key stays once nothing is being sent")
		}
		checkNow(t, server)
		if err := server.Run(bg, "nightly", fails("again")); err == nil {
			t.Fatal("the run did not fail")
		}
		sameList(t, "the condition still alerts once", sent.Types(), []string{"failed"})
	})
}

func TestAnAlertAChannelTookJustBeforeItsProcessDiedIsSentAgain(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		clock := storetest.NewClock(T0)
		shared := cronwatch.NewMemoryStore()
		store := newTestStore()
		store.inner = shared
		first := &storetest.Capture{}
		took := make(chan struct{})
		// Accepted, then the process is gone before it records that.
		dying := cronwatch.MustNew(cronwatch.WithStore(store), cronwatch.WithClock(clock.Now), cronwatch.WithoutCronSecret(), cronwatch.WithErrorHandler(quiet),
			cronwatch.WithAlerts(cronwatch.ChannelFunc("first", func(ctx context.Context, a cronwatch.Alert) error {
				err := first.Send(ctx, a, cronwatch.ChannelContext{})
				store.kill()
				close(took)
				return err
			})))
		var wg sync.WaitGroup
		defer wg.Wait()
		defer store.bury()
		wg.Go(func() { _ = dying.Run(bg, "nightly", fails("x")) })
		<-took
		sameList(t, "first", first.Types(), []string{"failed"})
		sent := &storetest.Capture{}
		server := cronwatch.MustNew(cronwatch.WithStore(shared), cronwatch.WithClock(clock.Now), cronwatch.WithAlerts(sent), cronwatch.WithoutCronSecret())
		clock.Set(T0 + sendLease + 1)
		checkNow(t, server)
		sameList(t, "sent a second time: the one duplicate a crash can cause", sent.Types(), []string{"failed"})
	})
}

func TestWhileAnAlertIsBeingSentNoCheckAnywhereSendsItToo(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		clock := storetest.NewClock(T0)
		shared := cronwatch.NewMemoryStore()
		entered, gate := make(chan struct{}), make(chan struct{})
		var once sync.Once
		held := &storetest.Capture{}
		channel := cronwatch.ChannelFunc("held", func(ctx context.Context, a cronwatch.Alert) error {
			once.Do(func() { close(entered) })
			<-gate
			return held.Send(ctx, a, cronwatch.ChannelContext{})
		})
		worker := cronwatch.MustNew(cronwatch.WithStore(shared), cronwatch.WithClock(clock.Now), cronwatch.WithAlerts(channel), cronwatch.WithoutCronSecret())
		other := &storetest.Capture{}
		server := cronwatch.MustNew(cronwatch.WithStore(shared), cronwatch.WithClock(clock.Now), cronwatch.WithAlerts(other), cronwatch.WithoutCronSecret())
		var wg sync.WaitGroup
		wg.Go(func() { _ = worker.Run(bg, "nightly", fails("x")) })
		<-entered
		clock.Advance(MIN)
		checkNow(t, server)
		// The sending process's own check, too.
		wg.Go(func() { _, _ = worker.Check(bg) })
		synctest.Wait()
		close(gate)
		wg.Wait()
		sameList(t, "sent", held.Types(), []string{"failed"})
		sameList(t, "the other process", other.Types(), []string{})
		state := must[*cronwatch.JobState](t)(shared.GetState(bg, "nightly"))
		if state.Sending != nil || len(state.Undelivered) != 0 {
			t.Errorf("state: %s", jsonOf(state))
		}
		eq(t, "the time the run was judged, as before", *state.LastAlertAt, T0)
		clock.Set(T0 + sendLease + MIN)
		checkNow(t, server)
		checkNow(t, worker)
		sameList(t, "the other process after the lease", other.Types(), []string{})
		sameList(t, "sent after the lease", held.Types(), []string{"failed"})
	})
}

func TestAnAlertNoChannelTookMovesToTheRetryQueueWithItsTriage(t *testing.T) {
	shared := cronwatch.NewMemoryStore()
	down := cronwatch.ChannelFunc("down", func(context.Context, cronwatch.Alert) error { return errors.New("down") })
	cw := cronwatch.MustNew(cronwatch.WithStore(shared), cronwatch.WithClock(storetest.NewClock(T0).Now), cronwatch.WithAlerts(down),
		cronwatch.WithoutCronSecret(), cronwatch.WithErrorHandler(quiet),
		cronwatch.WithTriage(func(context.Context, cronwatch.TriageContext) (string, error) { return "Look at the disk.", nil }))
	if err := cw.Run(bg, "nightly", fails("x")); err == nil {
		t.Fatal("the run did not fail")
	}
	state := must[*cronwatch.JobState](t)(shared.GetState(bg, "nightly"))
	if state.Sending != nil || len(state.Undelivered) != 1 || state.Undelivered[0].Type != cronwatch.AlertFailed ||
		state.Undelivered[0].Triage == nil || *state.Undelivered[0].Triage != "Look at the disk." {
		t.Errorf("state: %s", jsonOf(state))
	}
}

func TestAProcessThatQueuesItsAlertsWritesThemWithTheStateThatOpensTheCondition(t *testing.T) {
	store := newTestStore()
	writes := 0
	var mu sync.Mutex
	store.cas = func(s cronwatch.JobState, version int64) (bool, error) {
		mu.Lock()
		writes++
		mu.Unlock()
		return store.inner.CompareAndSetState(bg, s, version)
	}
	recorder := cronwatch.MustNew(cronwatch.WithStore(store), cronwatch.WithClock(storetest.NewClock(T0).Now), cronwatch.WithDeliver(cronwatch.DeliverAtCheck), cronwatch.WithoutCronSecret())
	if err := recorder.Run(bg, "backup", fails("disk full")); err == nil {
		t.Fatal("the run did not fail")
	}
	state := must[*cronwatch.JobState](t)(store.inner.GetState(bg, "backup"))
	sameList(t, "queued", alertTypes(state.Undelivered), []string{"failed"})
	if state.Sending != nil {
		t.Error("sending")
	}
	mu.Lock()
	defer mu.Unlock()
	eq(t, "one write: the failure and its alert together", writes, 1)
}
