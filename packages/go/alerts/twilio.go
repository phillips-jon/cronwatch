package alerts

// Twilio SMS. API reference: https://www.twilio.com/docs/messaging/api/message-resource
// POST https://api.twilio.com/2010-04-01/Accounts/<AccountSid>/Messages.json,
// form encoded, with basic auth. One recipient per request.

import (
	"context"
	"errors"
	"fmt"
	"math"
	"net/http"
	"strings"
	"sync"

	cronwatch "cronwatch.dev/go"
	"cronwatch.dev/go/internal/js"
)

// TwilioOptions configure Twilio.
type TwilioOptions struct {
	// AccountSID is the account SID, "AC...". It is in the URL whichever
	// credentials sign the request.
	AccountSID string
	// AuthToken is the account's auth token. Or give APIKeySID and
	// APIKeySecret instead.
	AuthToken string
	// APIKeySID is an API key SID, "SK...", with APIKeySecret, in place of
	// the auth token.
	APIKeySID    string
	APIKeySecret string
	// From is a Twilio number in E.164 form, "+15005550006". Or give
	// MessagingServiceSID.
	From string
	// MessagingServiceSID is a messaging service SID, "MG...", in place of
	// From.
	MessagingServiceSID string
	// To is one number in E.164 form, or several; each gets its own message.
	To []string
	// Recovered also texts when a job recovers. Off by default: a text is
	// for what needs a person.
	Recovered bool
	// Segments is how many SMS segments a message may use, 1 to 10.
	// 0 is the default, 3.
	Segments int
	// Link is a link back to the job in your dashboard, kept whole at the
	// end of the text.
	Link func(cronwatch.Alert) string
	// HTTPClient sends the requests; nil for Go's default transport. It is
	// used as a copy that never follows a redirect.
	HTTPClient *http.Client
}

// MaxSegments is the most segments a message may use, which keeps it
// inside Twilio's 1600 character Body limit.
const MaxSegments = 10

// maxSMSBody is the longest Body Twilio takes.
const maxSMSBody = 1600

// Twilio texts alerts through Twilio, to every number at once. The alert
// counts as delivered when any number took it; each number that refused it
// is reported through the channel context (the client's error handler). It
// fails only when every number did.
func Twilio(o TwilioOptions) (cronwatch.Channel, error) {
	// A pasted credential often carries a stray space or newline, which the Authorization header would refuse or send.
	accountSID := trimmed(o.AccountSID)
	if accountSID == "" {
		return nil, errors.New("alerts.Twilio needs an AccountSID")
	}
	keySID := trimmed(o.APIKeySID)
	user, password := accountSID, trimmed(o.AuthToken)
	if keySID != "" {
		user, password = keySID, trimmed(o.APIKeySecret)
	}
	if password == "" {
		return nil, errors.New("alerts.Twilio needs an AuthToken, or an APIKeySID and APIKeySecret")
	}
	if o.From == "" && o.MessagingServiceSID == "" {
		return nil, errors.New("alerts.Twilio needs a From number or a MessagingServiceSID")
	}
	var to []string
	for _, n := range o.To {
		if t := js.Trim(n); t != "" {
			to = append(to, t)
		}
	}
	if len(to) == 0 {
		return nil, errors.New("alerts.Twilio needs at least one To number")
	}
	url := "https://api.twilio.com/2010-04-01/Accounts/" + encodeURIComponent(accountSID) + "/Messages.json"
	authorization := basicAuth(user, password)
	budget := math.NaN()
	if o.Segments != 0 {
		budget = float64(o.Segments)
	}
	return &channel{name: "twilio", send: func(ctx context.Context, a cronwatch.Alert, cc cronwatch.ChannelContext) error {
		if a.Type == cronwatch.AlertRecovered && !o.Recovered {
			return nil
		}
		body := smsBody(a, linkFor(o.Link, a), budget)
		errs := make([]error, len(to))
		var wg sync.WaitGroup
		for i, number := range to {
			wg.Add(1)
			go func() {
				defer wg.Done()
				// A panic here (in an app's transport, say) would end the
				// process: it is this number's failure instead, as the
				// client makes a channel's.
				defer func() {
					if p := recover(); p != nil {
						errs[i] = fmt.Errorf("panicked: %v", p)
					}
				}()
				pairs := [][2]string{{"To", number}}
				if o.MessagingServiceSID != "" {
					pairs = append(pairs, [2]string{"MessagingServiceSid", o.MessagingServiceSID})
				} else {
					pairs = append(pairs, [2]string{"From", o.From})
				}
				pairs = append(pairs, [2]string{"Body", body})
				errs[i] = send(ctx, o.HTTPClient, "Twilio", url, []header{
					{Name: "content-type", Value: "application/x-www-form-urlencoded"},
					{Name: "authorization", Value: authorization},
				}, form(pairs...), password)
			}()
		}
		wg.Wait()
		var failed []int
		for i, err := range errs {
			if err != nil {
				failed = append(failed, i)
			}
		}
		if len(failed) == 0 {
			return nil
		}
		if len(failed) == len(to) {
			message := errs[failed[0]].Error()
			if len(to) > 1 {
				return fmt.Errorf("%s (%d of %d numbers failed)", message, len(failed), len(to))
			}
			return errs[failed[0]]
		}
		// Delivered to someone: counted as sent, so a retry never texts the numbers that took it again.
		for _, i := range failed {
			cc.ReportError(fmt.Errorf("%s (to %s; %d of %d numbers took the alert)", errs[i].Error(), maskNumber(to[i]), len(to)-len(failed), len(to)))
		}
		return nil
	}}, nil
}

// maskNumber is a number with all but its last four digits hidden, for an
// error message.
func maskNumber(number string) string {
	n := js.Length16(number)
	if n <= 4 {
		return number
	}
	return strings.Repeat("*", min(n-4, 8)) + js.Tail16(number, 4)
}

// The GSM 03.38 alphabet: a message in it takes 153 characters a segment
// (when split), anything else is UCS-2 at 67. The extension table costs two.
const (
	gsm         = "@£$¥èéùìòÇ\nØø\rÅåΔ_ΦΓΛΩΠΨΣΘΞÆæßÉ !\"#¤%&'()*+,-./0123456789:;<=>?¡ABCDEFGHIJKLMNOPQRSTUVWXYZÄÖÑÜ§¿abcdefghijklmnopqrstuvwxyzäöñüà"
	gsmExtended = "^{}\\[~]|€\f"
)

// smsSegments is how many segments text takes. A character is never split
// across two: an extension character (two septets) or a surrogate pair (two
// UCS-2 units) that would straddle a boundary starts the next segment, as
// phones pack them.
func smsSegments(text string) int {
	var sizes []int
	isGSM := true
	for _, r := range text {
		switch {
		case strings.ContainsRune(gsm, r):
			sizes = append(sizes, 1)
		case strings.ContainsRune(gsmExtended, r):
			sizes = append(sizes, 2)
		default:
			isGSM = false
		}
		if !isGSM {
			break
		}
	}
	single, per := 160, 153
	if !isGSM {
		single, per = 70, 67
		sizes = sizes[:0]
		for _, r := range text {
			sizes = append(sizes, 1+boolInt(r >= 0x10000))
		}
	}
	total := 0
	for _, u := range sizes {
		total += u
	}
	if total <= single {
		return 1
	}
	count, used := 1, 0
	for _, u := range sizes {
		if used+u > per {
			count++
			used = 0
		}
		used += u
	}
	return count
}

func boolInt(b bool) int {
	if b {
		return 1
	}
	return 0
}

// fits reports whether text fits within segments SMS segments and
// Twilio's Body limit.
func fits(text string, segments int) bool {
	return js.Length16(text) <= maxSMSBody && smsSegments(text) <= segments
}

// smsBody is the title, then as many lines of the message (and the
// triage) as fit, then the link. The link is kept whole; the text before it
// is cut to make room. segments is clamped to 1 to 10; NaN is the default,
// 3.
func smsBody(a cronwatch.Alert, link string, segments float64) string {
	budget := segmentBudget(segments)
	tail := ""
	if link != "" {
		tail = "\n" + link
	}
	lines := []string{js.WellFormed(a.Title)}
	for _, l := range strings.Split(js.WellFormed(a.Message), "\n") {
		if js.Trim(l) != "" {
			lines = append(lines, l)
		}
	}
	if t := triage(a); t != "" {
		lines = append(lines, "Triage: "+js.WellFormed(t))
	}
	text := ""
	join := func(line string) string {
		if text == "" {
			return line
		}
		return text + "\n" + line
	}
	for _, line := range lines {
		if next := join(line); fits(next+tail, budget) {
			text = next
			continue
		}
		// Part of this line, cut on a code point and marked.
		chars := []rune(line)
		lo, hi := 0, len(chars)
		for lo < hi {
			mid := (lo + hi + 1) / 2
			if fits(join(string(chars[:mid])+"...")+tail, budget) {
				lo = mid
			} else {
				hi = mid - 1
			}
		}
		if lo > 0 {
			text = join(string(chars[:lo]) + "...")
		}
		break
	}
	// Only a link too long for any budget gets here too long; Twilio would refuse it whole.
	return cut(text+tail, maxSMSBody)
}

// segmentBudget is a segment count clamped to 1 to MaxSegments; 3 for
// anything not a number.
func segmentBudget(segments float64) int {
	if math.IsNaN(segments) || math.IsInf(segments, 0) {
		return 3
	}
	return int(min(MaxSegments, max(1, math.Floor(segments))))
}
