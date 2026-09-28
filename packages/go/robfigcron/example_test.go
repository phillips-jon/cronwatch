package robfigcron_test

import (
	"log"
	"os"

	cronwatch "cronwatch.dev/go"
	"cronwatch.dev/go/robfigcron"
	"github.com/robfig/cron/v3"
)

func nightlyReport() {}

type syncInvoices struct{}

func (syncInvoices) Run() {}

// The README's robfig/cron example: one option on cron.New.
func ExampleWatch() {
	cw := cronwatch.MustNew()
	logger := cron.VerbosePrintfLogger(log.New(os.Stdout, "cron: ", log.LstdFlags))
	c := cron.New(robfigcron.Watch(cw, robfigcron.Options{Chain: []cron.JobWrapper{cron.Recover(logger)}}))
	_, _ = c.AddFunc("0 2 * * *", nightlyReport)
	_, _ = c.AddJob("*/15 * * * *", robfigcron.Named("sync-invoices", syncInvoices{}, cronwatch.Grace("5m")))
	c.Start()
	defer c.Stop()
}
