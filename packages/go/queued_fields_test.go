package cronwatch_test

// A queued alert is kept as the object it was read as: a field a newer
// release adds to its alerts or to their details, and an alert of a type
// this release does not know, are written back and retried as they were,
// as the SDK carries them.

import (
	"context"
	"encoding/json"
	"errors"
	"strconv"
	"strings"
	"sync"
	"testing"

	cronwatch "cronwatch.dev/go"
)

// refusing keeps the bodies sent to it and refuses every one.
type refusing struct {
	mu     sync.Mutex
	bodies []string
}

func (r *refusing) Name() string { return "refusing" }

func (r *refusing) Send(_ context.Context, a cronwatch.Alert, _ cronwatch.ChannelContext) error {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.bodies = append(r.bodies, jsonOf(a))
	return errors.New("refused")
}

func (r *refusing) list() []string {
	r.mu.Lock()
	defer r.mu.Unlock()
	return append([]string(nil), r.bodies...)
}

func queuedAlert(typ, details string, at int64) string {
	return `{"type":"` + typ + `","futureAlertField":{"a":1},"run":null,"details":` + details +
		`,"job":"keep","definition":{"name":"keep"},"title":"t","message":"m","at":` + strconv.FormatInt(at, 10) + `,"later":[1,"x"]}`
}

func TestQueuedAlertsKeepFieldsTheyDoNotKnow(t *testing.T) {
	at := strconv.FormatInt(T0, 10)
	future := queuedAlert("future_condition", `{"futureDetail":7,"nested":{}}`, T0)
	failed := queuedAlert("failed", `{"consecutiveFailures":3,"a_b":1,"threshold":2,"futureDetail":true}`, T0)
	over := queuedAlert("over_budget", `{"breaches":[{"metric":"cost","value":2,"limit":1,"basis":"budget","unit":"usd"}],"futureDetail":1}`, T0)
	slow := queuedAlert("slow", `{"durationMs":5,"thresholdMs":4,"basis":"maxDuration","futureDetail":7}`, T0)
	text := `{"job":"keep","open":{"future_condition":` + at + `,"failed":` + at + `,"over_budget":` + at + `,"slow":` + at +
		`},"consecutiveFailures":3,"silencedUntil":null,"lastAlertAt":null,"pendingRecovery":[],"undelivered":[` + future + `,` + failed + `,` + over +
		`],"sending":[{"until":` + strconv.FormatInt(T0+10*MIN, 10) + `,"futureEntryKey":"e","alert":` + slow + `}],"version":3}`
	var seed cronwatch.JobState
	check(t, json.Unmarshal([]byte(text), &seed))
	// Read and written straight back, the state is the same bytes.
	eq(t, "round trip", jsonOf(seed), text)

	channel := &refusing{}
	k := newKit(t, cronwatch.WithAlerts(channel))
	k.cw.MustJob("keep")
	check(t, k.cw.Store().SetState(bg, seed))
	k.c.Advance(MIN)
	checkNow(t, k.cw)
	if _, err := k.cw.Silence(bg, "keep", hour); err != nil {
		t.Fatal(err)
	}
	got := state(t, k.cw, "keep")
	byType := map[string]string{}
	for _, a := range got.Undelivered {
		byType[string(a.Type)] = jsonOf(a)
	}
	eq(t, "the unknown alert, kept", byType["future_condition"], future)
	eq(t, "the failed alert, kept", byType["failed"], failed)
	eq(t, "the over_budget alert, kept", byType["over_budget"], over)
	// The entry of sending still leased is held as it was.
	if len(got.Sending) != 1 {
		t.Fatalf("sending: %s", jsonOf(got))
	}
	whole := jsonOf(got)
	want := `"sending":[{"until":` + strconv.FormatInt(T0+10*MIN, 10) + `,"futureEntryKey":"e","alert":` + slow + `}]`
	if !strings.Contains(whole, want) {
		t.Errorf("sending entry: %s", whole)
	}

	sent := map[string]bool{}
	for _, b := range channel.list() {
		sent[b] = true
	}
	for _, body := range []string{future, failed, over} {
		if !sent[body] {
			t.Errorf("not retried as stored: %s\nsent: %v", body, channel.list())
		}
	}
}
