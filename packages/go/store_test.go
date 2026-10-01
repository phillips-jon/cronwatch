package cronwatch_test

//lint:file-ignore SA1019 storetest's helpers are this module's own test kit, deprecated only for apps

import (
	"context"
	"encoding/json"
	"path/filepath"
	"testing"

	cronwatch "cronwatch.dev/go"
	"cronwatch.dev/go/storetest"
)

// The memory store passes the contract test every store passes, and
// replays conformance/store.json. The SQL stores run both in the sqltest
// module, which holds the database drivers.

func TestMemoryStoreContract(t *testing.T) {
	storetest.Run(t, func(*testing.T) cronwatch.Store { return cronwatch.NewMemoryStore() })
}

func TestMemoryFinishOnce(t *testing.T) {
	storetest.FinishOnce(t, func(*testing.T) storetest.Shared {
		store := cronwatch.NewMemoryStore()
		return storetest.Shared{Open: func() cronwatch.Store { return store }, Done: func() {}}
	})
}

func TestMemoryStoreConformance(t *testing.T) {
	storetest.ReplayFixture(t, filepath.Join("..", "..", "conformance", "store.json"), func(*testing.T) cronwatch.Store {
		return cronwatch.NewMemoryStore()
	})
}

// A foreign version reads as none on the way in (JobState's JSON), so the
// memory store holds the state as read and counts it as 0.
func TestMemoryStoreForeignVersions(t *testing.T) {
	store := cronwatch.NewMemoryStore()
	storetest.ReplayForeignVersions(t, filepath.Join("..", "..", "conformance", "store.json"), store, func(text string) error {
		var st cronwatch.JobState
		if err := json.Unmarshal([]byte(text), &st); err != nil {
			return err
		}
		return store.SetState(context.Background(), st)
	})
}
