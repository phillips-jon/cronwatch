package cronwatch_test

import (
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
