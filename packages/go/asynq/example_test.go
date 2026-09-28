package asynq_test

import (
	"time"

	cronwatch "cronwatch.dev/go"
	cwasynq "cronwatch.dev/go/asynq"
	"github.com/hibiken/asynq"
)

// The README's Asynq example: a scheduler that declares its entries, and
// the server's middleware and check handler.
func ExampleWatcher_NewScheduler() {
	cw := cronwatch.MustNew()
	redisOpt := asynq.RedisClientOpt{Addr: "127.0.0.1:6379"}
	w := cwasynq.New(cw, cwasynq.Options{})
	scheduler := w.NewScheduler(redisOpt, &asynq.SchedulerOpts{Location: time.UTC})
	_, _ = scheduler.Register("0 2 * * *", asynq.NewTask("report:nightly", nil))
	_, _ = scheduler.Register("*/5 * * * *", cwasynq.CheckTask())

	mux := asynq.NewServeMux()
	mux.Use(w.Middleware())
	mux.Handle(cwasynq.CheckType, w.CheckHandler())
}
