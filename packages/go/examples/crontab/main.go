// Command crontab is a job a crontab runs, watched by CronWatch, and the
// check a second line of the same crontab runs:
//
//	# m  h  dom mon dow  command
//	0    2  *   *   *    /usr/local/bin/crontab report
//	*/5  *  *   *   *    /usr/local/bin/crontab check
//
// Each line starts a process of its own, so the runs and the job's state
// live in a database both reach: a SQLite file here ($CRONWATCH_DB, else
// ./cronwatch.db), or the app's Postgres or MySQL through sqlstore. Both
// commands declare the job, so the check knows its schedule even before
// its first run. "report" records its run as it ends; "check" finds the
// report missed when 02:00 passes without one (after the grace), a run
// that started and never ended stuck after its timeout, and sends the
// alerts, printing what it did.
//
// A program that stays up (a server, a worker) checks in itself instead:
//
//	cw.StartChecking(time.Minute) // a goroutine that checks every minute, until cw.Stop or cw.Close
//
// Only one process needs to check; running Start in every replica of a
// service is harmless, since a check judges each run once.
package main

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"io"
	"log"
	"os"
	"time"

	cronwatch "cronwatch.dev/go"
	"cronwatch.dev/go/sqlstore"
	_ "modernc.org/sqlite"
)

func main() {
	if err := run(context.Background(), os.Args[1:], os.Stdout); err != nil {
		log.Fatal(err)
	}
}

// run is the command: "report" or "check".
func run(ctx context.Context, args []string, out io.Writer) error {
	if len(args) != 1 || (args[0] != "report" && args[0] != "check") {
		return errors.New("usage: crontab report|check")
	}
	path := os.Getenv("CRONWATCH_DB")
	if path == "" {
		path = "cronwatch.db"
	}
	db, err := sql.Open("sqlite", "file:"+path)
	if err != nil {
		return err
	}
	defer db.Close()
	store, err := sqlstore.New(db, sqlstore.SQLite)
	if err != nil {
		return err
	}
	// Alerts go to the console unless channels are given (cronwatch.dev/go/alerts).
	cw, err := cronwatch.New(cronwatch.WithStore(store))
	if err != nil {
		return err
	}
	defer cw.Close()

	// The same declaration in both commands: the crontab's line, as a schedule.
	nightly, err := cw.Job("nightly-report",
		cronwatch.Schedule("0 2 * * *"), cronwatch.Timezone("UTC"),
		cronwatch.Grace("15m"), cronwatch.Timeout(30*time.Minute),
		cronwatch.Expect("Report written"))
	if err != nil {
		return err
	}

	if args[0] == "check" {
		result, err := cw.Check(ctx)
		if err != nil {
			return err
		}
		fmt.Fprintf(out, "cronwatch: checked %d job%s, sent %d alert%s\n", len(result.Jobs), plural(len(result.Jobs)), len(result.Alerts), plural(len(result.Alerts)))
		return nil
	}
	// A returned error fails the run and is returned here, so the process
	// exits non-zero, as cron expects.
	return nightly.Run(ctx, func(ctx context.Context, job *cronwatch.JobContext) error {
		job.Log("Report written: 42 rows")
		return job.Metric("rows", 42)
	})
}

func plural(n int) string {
	if n == 1 {
		return ""
	}
	return "s"
}
