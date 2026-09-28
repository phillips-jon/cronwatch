package alerts

// Mailgun. API reference: https://documentation.mailgun.com/docs/mailgun/api-reference/send/mailgun/messages/post-v3--domain-name--messages
// POST https://api.mailgun.net/v3/<domain>/messages (api.eu.mailgun.net for
// the EU region), form encoded, with basic auth "api:<key>".

import (
	"context"
	"errors"
	"net/http"

	cronwatch "cronwatch.dev/go"
)

// MailgunOptions configure Mailgun.
type MailgunOptions struct {
	EmailOptions
	// APIKey is a sending or account API key.
	APIKey string
	// Domain is the sending domain, "mg.example.com".
	Domain string
	// Region is "eu" for a domain in the EU region. Default "us".
	Region string
	// HTTPClient sends the request; nil for Go's default transport. It is
	// used as a copy that never follows a redirect.
	HTTPClient *http.Client
}

// Mailgun sends alerts as email through Mailgun.
func Mailgun(o MailgunOptions) (cronwatch.Channel, error) {
	// A pasted credential often carries a stray space or newline, which a header would refuse or send.
	apiKey := trimmed(o.APIKey)
	if apiKey == "" {
		return nil, errors.New("alerts.Mailgun needs an APIKey")
	}
	if o.Domain == "" {
		return nil, errors.New("alerts.Mailgun needs a Domain")
	}
	to, err := recipients("Mailgun", o.EmailOptions)
	if err != nil {
		return nil, err
	}
	host := "https://api.mailgun.net"
	if o.Region == "eu" {
		host = "https://api.eu.mailgun.net"
	}
	url := host + "/v3/" + encodeURIComponent(o.Domain) + "/messages"
	return &channel{name: "mailgun", send: func(ctx context.Context, a cronwatch.Alert, _ cronwatch.ChannelContext) error {
		m := composeEmail(a, o.EmailOptions, to)
		pairs := [][2]string{{"from", m.from}}
		for _, t := range m.to {
			pairs = append(pairs, [2]string{"to", t})
		}
		pairs = append(pairs, [2]string{"subject", m.subject}, [2]string{"text", m.text}, [2]string{"html", m.html}, [2]string{"o:tag", "cronwatch"})
		return send(ctx, o.HTTPClient, "Mailgun", url, []header{
			{Name: "content-type", Value: "application/x-www-form-urlencoded"},
			{Name: "authorization", Value: basicAuth("api", apiKey)},
		}, form(pairs...), apiKey)
	}}, nil
}
