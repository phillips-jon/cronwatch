package alerts

// Amazon SES, API v2 SendEmail. API reference: https://docs.aws.amazon.com/ses/latest/APIReference-V2/API_SendEmail.html
// POST https://email.<region>.amazonaws.com/v2/email/outbound-emails, signed
// with AWS Signature Version 4 (sigv4.go), so no AWS SDK is needed.

import (
	"context"
	"errors"
	"net/http"
	"regexp"
	"time"

	cronwatch "cronwatch.dev/go"
	"cronwatch.dev/go/internal/js"
)

// SESOptions configure SES.
type SESOptions struct {
	EmailOptions
	// Region is the SES region, "us-east-1" say. The From identity must be
	// verified there.
	Region          string
	AccessKeyID     string
	SecretAccessKey string
	// SessionToken is for temporary credentials, an assumed role say.
	SessionToken string
	// ConfigurationSetName is a configuration set for event publishing, if
	// you use one.
	ConfigurationSetName string
	// Now is the clock requests are signed with, in epoch milliseconds.
	// For tests; nil for the time now.
	Now func() int64
	// HTTPClient sends the request; nil for Go's default transport. It is
	// used as a copy that never follows a redirect.
	HTTPClient *http.Client
}

var sesRegion = regexp.MustCompile(`^[a-z0-9-]+$`)

// SES sends alerts as email through Amazon SES.
func SES(o SESOptions) (cronwatch.Channel, error) {
	if o.Region == "" {
		return nil, errors.New("alerts.SES needs a Region")
	}
	if !sesRegion.MatchString(o.Region) {
		return nil, errors.New("alerts.SES needs a Region like us-east-1")
	}
	// A pasted credential often carries a stray space or newline, which would spoil the signature.
	creds := sigV4Credentials{accessKeyID: trimmed(o.AccessKeyID), secretAccessKey: trimmed(o.SecretAccessKey), sessionToken: trimmed(o.SessionToken)}
	if creds.accessKeyID == "" || creds.secretAccessKey == "" {
		return nil, errors.New("alerts.SES needs an AccessKeyID and SecretAccessKey")
	}
	to, err := recipients("SES", o.EmailOptions)
	if err != nil {
		return nil, err
	}
	url := "https://email." + o.Region + ".amazonaws.com/v2/email/outbound-emails"
	now := o.Now
	if now == nil {
		now = func() int64 { return time.Now().UnixMilli() }
	}
	return &channel{name: "ses", send: func(ctx context.Context, a cronwatch.Alert, _ cronwatch.ChannelContext) error {
		m := composeEmail(a, o.EmailOptions, to)
		utf8 := func(data string) *js.Object { return js.NewObject("Data", data, "Charset", "UTF-8") }
		message := js.NewObject(
			"FromEmailAddress", m.from,
			"Destination", js.NewObject("ToAddresses", m.to),
			"Content", js.NewObject("Simple", js.NewObject(
				"Subject", utf8(m.subject),
				"Body", js.NewObject("Text", utf8(m.text), "Html", utf8(m.html)),
			)),
		)
		if o.ConfigurationSetName != "" {
			message.Set("ConfigurationSetName", o.ConfigurationSetName)
		}
		message.Set("EmailTags", []any{js.NewObject("Name", "source", "Value", "cronwatch")})
		body := js.Stringify(message)
		headers, err := signV4(sigV4Request{
			method: "POST", url: url, headers: []header{{Name: "content-type", Value: "application/json"}},
			body: body, region: o.Region, service: "ses", now: now(),
		}, creds)
		if err != nil {
			return err
		}
		return send(ctx, o.HTTPClient, "SES", url, headers, body, creds.secretAccessKey, creds.sessionToken)
	}}, nil
}
