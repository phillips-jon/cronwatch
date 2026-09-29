package cronwatch

import (
	"encoding/json"
	"testing"
)

// The Rust audit: a queued alert's metric that is not a number, or a queued
// entry that is not an alert, failed every read of the job's state.
func TestAQueuedAlertOfAnotherShapeDoesNotFailTheState(t *testing.T) {
	text := `{"job":"k","version":1,"undelivered":[{"type":"failed","job":"k","run":{"id":"x","metrics":{"a":null,"b":2}}},7]}`
	var s JobState
	if err := json.Unmarshal([]byte(text), &s); err != nil {
		t.Fatal(err)
	}
	if len(s.Undelivered) != 1 {
		t.Fatalf("queued %d, want 1", len(s.Undelivered))
	}
	got, _ := json.Marshal(s.Undelivered[0].Run.Metrics)
	if string(got) != `{"b":2}` {
		t.Fatalf("metrics %s", got)
	}
}
