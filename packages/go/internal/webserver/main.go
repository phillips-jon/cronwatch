// Command webserver serves the dashboard over HTTP for
// packages/mcp/test/go-web.test.ts, which drives @cronwatch/mcp against it.
// Seeded like the MCP tests' own end to end case: a "nightly" job with one
// good run and one failed one, and a fixed clock. Mounted under /cronwatch
// with http.StripPrefix, so the routes find their base path from it.
// Standard library only.
//
//	go run ./internal/webserver PORT    (in packages/go)
//
// Alerts are printed as "alert <job> <type>" lines.
package main

import (
	"context"
	"errors"
	"fmt"
	"net/http"
	"os"
	"sync/atomic"
	"time"

	cronwatch "cronwatch.dev/go"
)

func main() {
	if len(os.Args) != 2 {
		fmt.Fprintln(os.Stderr, "usage: webserver PORT")
		os.Exit(2)
	}
	var now atomic.Int64
	now.Store(time.Date(2026, 1, 5, 2, 0, 0, 0, time.UTC).UnixMilli())
	channel := cronwatch.ChannelFunc("test", func(_ context.Context, alert cronwatch.Alert) error {
		fmt.Printf("alert %s %s\n", alert.Job, alert.Type)
		return nil
	})
	cw, err := cronwatch.New(cronwatch.WithAlerts(channel), cronwatch.WithoutCronSecret(), cronwatch.WithClock(now.Load))
	if err != nil {
		fail(err)
	}
	ctx := context.Background()
	nightly, err := cw.Job("nightly", cronwatch.Schedule("0 2 * * *"), cronwatch.Timezone("UTC"), cronwatch.Grace("15m"))
	if err != nil {
		fail(err)
	}
	if err := nightly.Run(ctx, func(_ context.Context, job *cronwatch.JobContext) error {
		job.Log("step 1")
		return nil
	}); err != nil {
		fail(err)
	}
	now.Add(60_000)
	_ = nightly.Run(ctx, func(_ context.Context, job *cronwatch.JobContext) error {
		job.Log("step 2")
		return errors.New("db down")
	})

	routes, err := cw.Routes(cronwatch.WithToken("tok"))
	if err != nil {
		fail(err)
	}
	mux := http.NewServeMux()
	mux.Handle("/cronwatch/", http.StripPrefix("/cronwatch", routes))
	fmt.Printf("serving on %s\n", os.Args[1])
	server := &http.Server{Addr: "127.0.0.1:" + os.Args[1], Handler: mux, ReadHeaderTimeout: 10 * time.Second}
	fail(server.ListenAndServe())
}

func fail(err error) {
	fmt.Fprintln(os.Stderr, err)
	os.Exit(1)
}
