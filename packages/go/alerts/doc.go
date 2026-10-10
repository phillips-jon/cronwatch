// Package alerts holds the SDK's alert channels, request for request, on
// net/http alone: Slack, Discord, and a signed Webhook; the email providers
// Resend, Postmark, Sendgrid, Mailgun, and SES (signed with SigV4, no AWS
// SDK); Twilio for SMS; and the trackers Sentry, Honeybadger, Datadog,
// Rollbar, Bugsnag, and NewRelic. Each is made from an options struct and
// returns a cronwatch.Channel:
//
//	slack, err := alerts.Slack(alerts.SlackOptions{WebhookURL: os.Getenv("SLACK_WEBHOOK_URL")})
//	cw, err := cronwatch.New(cronwatch.WithAlerts(slack))
//
// Every request is the SDK's (the same URL, headers, and body bytes, so a
// provider sees the same alert whichever port sent it) and made the way the
// SDK makes it: one ten second deadline for the whole request, a redirect
// refused rather than followed (its 3xx is a failure, so credentials never
// go where it points), at most 1 MiB of an answer read, TLS verified, and
// an error that names the provider and the URL's origin only, with every
// secret the channel holds cut out of any answer it quotes. Ids are
// deterministic (the first 32 hex characters of SHA-256 over job, type, and
// time), so Resend's idempotency key, Sentry's event id, and Rollbar's UUID
// let a provider drop an alert it already took.
//
// Each options struct has an HTTPClient: nil for Go's default transport,
// or a client of yours (a proxy, a test's transport). It is used as a copy
// that never follows a redirect.
package alerts
