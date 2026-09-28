package alerts

// What every email channel sends (alerts/email.ts): one subject, a plain
// text body and a small HTML body, so an alert reads the same whichever
// provider carries it.

import (
	"fmt"
	"regexp"
	"strings"

	cronwatch "cronwatch.dev/go"
	"cronwatch.dev/go/internal/js"
)

// EmailOptions are what every email channel takes.
type EmailOptions struct {
	// From is the sender, "alerts@example.com" or "CronWatch
	// <alerts@example.com>". The provider must allow it.
	From string
	// To is one address or several.
	To []string
	// SubjectPrefix goes in front of the title in the subject, "[prod]" say.
	SubjectPrefix string
	// Link is a link back to the job in your dashboard. Only an http or
	// https link is put in a mail.
	Link func(cronwatch.Alert) string
}

// email is one alert as a mail.
type email struct {
	from, subject, text, html string
	to                        []string
}

// recipients checks the shared options once, when the channel is made:
// the to addresses, blanks dropped, each trimmed.
func recipients(name string, o EmailOptions) ([]string, error) {
	if o.From == "" {
		return nil, fmt.Errorf("alerts.%s needs a From address", name)
	}
	var to []string
	for _, a := range o.To {
		if t := js.Trim(a); t != "" {
			to = append(to, t)
		}
	}
	if len(to) == 0 {
		return nil, fmt.Errorf("alerts.%s needs at least one To address", name)
	}
	return to, nil
}

var lineBreaks = regexp.MustCompile(`[\r\n]+`)

// composeEmail is the mail for an alert.
func composeEmail(a cronwatch.Alert, o EmailOptions, to []string) email {
	link := safeLink(linkFor(o.Link, a))
	prefix := ""
	if o.SubjectPrefix != "" {
		prefix = o.SubjectPrefix + " "
	}
	// One line: a newline in a subject is a header injection or a rejected send.
	subject := cut(lineBreaks.ReplaceAllString(js.WellFormed(prefix+a.Title), " "), 250)
	return email{from: o.From, to: to, subject: subject, text: plainText(a, link), html: emailHTML(a, link)}
}

// escapeHTML escapes text for HTML content and double quoted attributes.
func escapeHTML(text string) string {
	return strings.NewReplacer("&", "&amp;", "<", "&lt;", ">", "&gt;", `"`, "&quot;", "'", "&#39;").Replace(text)
}

var httpLink = regexp.MustCompile(`^(?i)https?://`)

// safeLink keeps only an http or https link.
func safeLink(link string) string {
	if httpLink.MatchString(link) {
		return link
	}
	return ""
}

func emailHTML(a cronwatch.Alert, link string) string {
	parts := []string{
		`<!doctype html>`,
		`<html><body style="margin:0;padding:16px;font-family:Georgia,serif;color:#1d1b16;background:#ffffff">`,
		`<p style="margin:0 0 12px;font-size:18px"><strong>` + escapeHTML(a.Title) + `</strong></p>`,
		`<pre style="margin:0 0 12px;padding:12px;background:#f6f3ec;white-space:pre-wrap;word-break:break-word;font:13px/1.45 Menlo,Consolas,monospace">` + escapeHTML(a.Message) + `</pre>`,
	}
	if t := triage(a); t != "" {
		parts = append(parts, `<p style="margin:0 0 12px"><em>Triage:</em> `+escapeHTML(t)+`</p>`)
	}
	if link != "" {
		parts = append(parts, `<p style="margin:0"><a href="`+escapeHTML(link)+`">Open `+escapeHTML(a.Job)+`</a></p>`)
	}
	parts = append(parts, `</body></html>`)
	return strings.Join(parts, "\n")
}

// address is "Name <a@b.c>" split into its parts; a bare address has no
// name.
type address struct{ email, name string }

func (a address) jsValue() any {
	o := js.NewObject("email", a.email)
	if a.name != "" {
		o.Set("name", a.name)
	}
	return o
}

// parseAddress is email.ts's parseAddress: /^\s*(.*?)\s*<([^<>]+)>\s*$/,
// then the name without the double quotes around it.
func parseAddress(text string) address {
	bare := address{email: js.Trim(text)}
	s := js.TrimEnd(text)
	if !strings.HasSuffix(s, ">") {
		return bare
	}
	inner := s[:len(s)-1]
	at := strings.LastIndexByte(inner, '<')
	if at < 0 || at == len(inner)-1 || strings.ContainsRune(inner[at+1:], '>') {
		return bare
	}
	name := js.Trim(inner[:at])
	// JavaScript's . matches no line terminator.
	if strings.ContainsAny(name, "\n\r\u2028\u2029") {
		return bare
	}
	if len(name) >= 2 && strings.HasPrefix(name, `"`) && strings.HasSuffix(name, `"`) {
		name = name[1 : len(name)-1]
	}
	return address{email: js.Trim(inner[at+1:]), name: name}
}
