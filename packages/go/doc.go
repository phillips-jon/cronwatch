// Package cronwatch is cron and scheduled-job monitoring that lives inside
// a Go app: wrap a job once, and every run is recorded in a database the app
// already has, and alerts go out when a run is missed, fails, gets stuck,
// runs slow or goes over budget. It is the Go port of @cronwatch/sdk, with
// the same rules, alert text and stored rows, so a Go process can share a
// database with the SDK and its other ports.
//
// A client is made once, jobs are declared on it, and each run of a job is
// its function called through Run:
//
//	cw, err := cronwatch.New(cronwatch.WithStore(store))
//	nightly, err := cw.Job("nightly-report", cronwatch.Schedule("0 2 * * *"), cronwatch.Grace("15m"))
//	err = nightly.Run(ctx, func(ctx context.Context, job *cronwatch.JobContext) error {
//		job.Log("Report written")
//		return nil
//	})
//
// Missed and stuck runs are found by Check, called on an interval by Start
// in a long-running service, or from a crontab line. The sqlstore package
// keeps everything in SQLite, Postgres or MySQL over the app's own
// *sql.DB; MemoryStore, the default, forgets on restart.
//
// Every value a store holds is the SDK's JSON: each type's MarshalJSON
// writes it byte for byte, with keys in JavaScript's order.
package cronwatch
