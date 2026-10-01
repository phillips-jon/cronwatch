package pgcron_test

import (
	"database/sql"
	"os"
	"time"

	cronwatch "cronwatch.dev/go"
	"cronwatch.dev/go/pgcron"
	"cronwatch.dev/go/sqlstore"
)

// The README's pg_cron source: each check reads pg_cron's jobs and runs
// through the app's *sql.DB, whatever Postgres driver opened it.
func ExampleNew() {
	db, err := sql.Open("pgx", os.Getenv("DATABASE_URL")) // github.com/jackc/pgx/v5/stdlib
	if err != nil {
		panic(err)
	}
	store, err := sqlstore.New(db, sqlstore.Postgres)
	if err != nil {
		panic(err)
	}
	cw, err := cronwatch.New(cronwatch.WithStore(store), cronwatch.WithSources(pgcron.New(db, pgcron.Options{Prefix: "db:"})))
	if err != nil {
		panic(err)
	}
	cw.StartChecking(time.Minute)
	defer cw.Close()
}
