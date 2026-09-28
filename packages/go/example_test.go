package cronwatch_test

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"net/http/httptest"
	"time"

	cronwatch "cronwatch.dev/go"
)

// A job declared once and run: the failure is recorded, judged and alerted.
func Example() {
	ctx := context.Background()
	now := time.Date(2026, 1, 5, 2, 0, 0, 0, time.UTC).UnixMilli()
	alerts := cronwatch.ChannelFunc("print", func(_ context.Context, a cronwatch.Alert) error {
		fmt.Println(a.Title)
		fmt.Println(a.Message)
		return nil
	})
	cw := cronwatch.MustNew(cronwatch.WithAlerts(alerts), cronwatch.WithClock(func() int64 { return now }))
	nightly := cw.MustJob("nightly-report", cronwatch.Schedule("0 2 * * *"), cronwatch.Timezone("UTC"), cronwatch.Grace("15m"))

	err := nightly.Run(ctx, func(ctx context.Context, job *cronwatch.JobContext) error {
		job.Log("connecting to postgres://app:" + "hunter" + "2@db.internal/app")
		return errors.New("connection refused")
	})
	fmt.Println("returned:", err)

	runs, _ := cw.Runs(ctx, "nightly-report", 1)
	fmt.Println(runs[0].Status, *runs[0].Output)
	// Output:
	// nightly-report failed
	// Started 2026-01-05 02:00:00 UTC (now), ran 0ms.
	// Error: connection refused
	// Output (tail):
	// connecting to postgres://app:[redacted]@db.internal/app
	// returned: connection refused
	// failed connecting to postgres://app:[redacted]@db.internal/app
}

// Options keep the order they are given in, as the SDK's object literal
// does, so the stored definition is the same JSON a Node process writes.
func ExampleClient_Job() {
	cw := cronwatch.MustNew()
	job := cw.MustJob("sync", cronwatch.Schedule("every 5m"), cronwatch.Timeout(90*time.Second),
		cronwatch.Budget("tokens", 5000), cronwatch.Expect("synced"))
	out, _ := job.Definition().MarshalJSON()
	fmt.Println(string(out))
	// Output:
	// {"schedule":"every 5m","timeout":90000,"budget":{"tokens":5000},"name":"sync","expect":"contains \"synced\""}
}

// The dashboard and its JSON API, mounted under a prefix: the base path
// its links use is found from the mount.
func ExampleClient_Routes() {
	cw := cronwatch.MustNew(cronwatch.WithoutCronSecret())
	routes, err := cw.Routes(cronwatch.WithToken("a-long-random-token"))
	if err != nil {
		panic(err)
	}
	mux := http.NewServeMux()
	mux.Handle("/ops/cron/", http.StripPrefix("/ops/cron", routes))

	req := httptest.NewRequest("GET", "/ops/cron/api/jobs", nil)
	req.Header.Set("Authorization", "Bearer a-long-random-token")
	rec := httptest.NewRecorder()
	mux.ServeHTTP(rec, req)
	fmt.Println(rec.Code, rec.Body.String())
	// Output:
	// 200 {"ok":true,"jobs":[]}
}

// A run that starts in one call and ends in another, as the README shows:
// work handed to a queue, a webhook that reports back later.
func ExampleJob_Start() {
	ctx := context.Background()
	cw := cronwatch.MustNew(cronwatch.WithoutCronSecret())
	nightly := cw.MustJob("nightly-report")
	h, err := nightly.Start(ctx, cronwatch.WithRunID("delivery-42"))
	if err != nil {
		panic(err)
	}
	// ... later, perhaps in another process:
	h, err = nightly.Resume(ctx, "delivery-42")
	if err != nil {
		panic(err)
	}
	h.Log("done")
	run := h.Finish(ctx)
	fmt.Println(run.ID, run.Status, *run.Output)
	// Output:
	// delivery-42 ok done
}

// A job run by a platform cron that calls a URL with the cron secret.
func ExampleJob_Handler() {
	cw := cronwatch.MustNew(cronwatch.WithCronSecret("the-cron-secret"))
	nightly := cw.MustJob("nightly-report")
	handler := nightly.Handler(func(ctx context.Context, job *cronwatch.JobContext, w http.ResponseWriter, r *http.Request) error {
		job.Log("Report written")
		return nil
	})

	req := httptest.NewRequest("POST", "/api/cron/nightly", nil)
	req.Header.Set("Authorization", "Bearer the-cron-secret")
	rec := httptest.NewRecorder()
	handler.ServeHTTP(rec, req)
	var answer struct {
		OK     bool   `json:"ok"`
		Status string `json:"status"`
	}
	_ = json.Unmarshal(rec.Body.Bytes(), &answer)
	fmt.Println(rec.Code, answer.OK, answer.Status)
	// Output:
	// 200 true ok
}
