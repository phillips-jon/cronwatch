package sqltest

import (
	"database/sql"
	"path/filepath"
	"testing"

	cronwatch "cronwatch.dev/go"
	"cronwatch.dev/go/sqlstore"
	"cronwatch.dev/go/storetest"
)

// The store contract, conformance/store.json and the finish-once tests on
// every dialect: SQLite on a file and in memory, and each server that is set.

var fixturePath = filepath.Join("..", "..", "..", "conformance", "store.json")

func sqliteFile(t *testing.T) cronwatch.Store {
	return newStore(t, sqliteDB(t, tempFile(t, "cw.db")), sqlstore.SQLite, sqlstore.DefaultPrefix)
}

func sqliteMemory(t *testing.T) cronwatch.Store {
	return newStore(t, sqliteDB(t, ":memory:"), sqlstore.SQLite, sqlstore.DefaultPrefix)
}

func TestSQLiteFileContract(t *testing.T)   { storetest.Run(t, sqliteFile) }
func TestSQLiteMemoryContract(t *testing.T) { storetest.Run(t, sqliteMemory) }

func TestSQLiteConformance(t *testing.T) { storetest.ReplayFixture(t, fixturePath, sqliteFile) }

// A prefix of the SDK's other than the default works the same.
func TestSQLitePrefixContract(t *testing.T) {
	storetest.Run(t, func(t *testing.T) cronwatch.Store {
		return newStore(t, sqliteDB(t, tempFile(t, "p.db")), sqlstore.SQLite, "other_")
	})
}

func TestSQLiteFinishOnce(t *testing.T) {
	storetest.FinishOnce(t, func(t *testing.T) storetest.Shared {
		file := tempFile(t, "once.db")
		var opened []cronwatch.Store
		return storetest.Shared{
			// Each process has its own *sql.DB on the one file.
			Open: func() cronwatch.Store {
				s := newStore(t, sqliteDB(t, file), sqlstore.SQLite, sqlstore.DefaultPrefix)
				opened = append(opened, s)
				return s
			},
			Done: func() {
				for _, s := range opened {
					s.Close()
				}
			},
		}
	})
}

func TestServerContract(t *testing.T) {
	eachServer(t, func(t *testing.T, b backend) {
		db := b.open(t)
		storetest.Run(t, func(t *testing.T) cronwatch.Store { return newStore(t, db, b.dialect, prefix("contract")) })
	})
}

func TestServerConformance(t *testing.T) {
	eachServer(t, func(t *testing.T, b backend) {
		db := b.open(t)
		storetest.ReplayFixture(t, fixturePath, func(t *testing.T) cronwatch.Store { return newStore(t, db, b.dialect, prefix("fixture")) })
	})
}

func TestServerFinishOnce(t *testing.T) {
	eachServer(t, func(t *testing.T, b backend) {
		b.open(t) // skips when the server is not set
		storetest.FinishOnce(t, func(t *testing.T) storetest.Shared {
			p := prefix("once")
			var dbs []*sql.DB
			return storetest.Shared{
				// Each process has its own *sql.DB, as its own pool.
				Open: func() cronwatch.Store {
					db := b.open(t)
					dbs = append(dbs, db)
					return newStore(t, db, b.dialect, p)
				},
				Done: func() {},
			}
		})
	})
}

func TestPrefixIsChecked(t *testing.T) {
	db := sqliteDB(t, ":memory:")
	for _, bad := range []string{"Upper_", "1x_", "a-b", "", "a_very_long_prefix_that_goes_on_and_on_past_the_limit_"} {
		if _, err := sqlstore.New(db, sqlstore.SQLite, sqlstore.Prefix(bad)); err == nil {
			t.Errorf("prefix %q was taken", bad)
		}
	}
	if _, err := sqlstore.New(db, "oracle"); err == nil {
		t.Error("an unknown dialect was taken")
	}
	if _, err := sqlstore.New(nil, sqlstore.SQLite); err == nil {
		t.Error("a nil database was taken")
	}
}
