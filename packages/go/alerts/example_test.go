package alerts_test

import (
	"os"

	cronwatch "cronwatch.dev/go"
	"cronwatch.dev/go/alerts"
)

// The README's channels: Slack and email through Resend.
func Example() {
	slack, err := alerts.Slack(alerts.SlackOptions{WebhookURL: os.Getenv("SLACK_WEBHOOK_URL")})
	if err != nil {
		panic(err)
	}
	email, err := alerts.Resend(alerts.ResendOptions{
		APIKey:       os.Getenv("RESEND_API_KEY"),
		EmailOptions: alerts.EmailOptions{From: "CronWatch <alerts@example.com>", To: []string{"ops@example.com"}},
	})
	if err != nil {
		panic(err)
	}
	cw, err := cronwatch.New(cronwatch.WithAlerts(slack, email))
	if err != nil {
		panic(err)
	}
	defer cw.Close()
}
