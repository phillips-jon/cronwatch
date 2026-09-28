package triage_test

import (
	cronwatch "cronwatch.dev/go"
	"cronwatch.dev/go/triage"
)

// The README's triage: a short diagnosis of each alert from Claude, the key
// from ANTHROPIC_API_KEY.
func ExampleAnthropic() {
	diagnose, err := triage.Anthropic(triage.AnthropicOptions{Context: "A Go service on Fly.io with a Postgres database."})
	if err != nil {
		return // no ANTHROPIC_API_KEY
	}
	cw, err := cronwatch.New(cronwatch.WithTriage(diagnose))
	if err != nil {
		panic(err)
	}
	defer cw.Close()
}
