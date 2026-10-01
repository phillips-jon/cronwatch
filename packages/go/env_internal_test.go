package cronwatch

import "testing"

// The SDK's cases (packages/sdk/test/env.test.ts), GO_ENV in NODE_ENV's
// place: CRONWATCH_ENV, then APP_ENV, then GO_ENV, the first one set to
// more than spaces winning, lowercased, with the aliases.
func TestEnvironmentOrder(t *testing.T) {
	cases := []struct{ cronwatch, app, own, want string }{
		{"", "", "", ""},
		{"", "", "development", "development"},
		{"", "", "test", "development"},
		{"", "", "production", "production"},
		{"", "local", "production", "development"},
		{"production", "dev", "development", "production"},
		{"staging", "", "development", "staging"},
		{"  PROD ", "", "", "production"},
		{"", "Testing", "", "development"},
		{"", "DEV", "", "development"},
		{"", "   ", "production", "production"},
		{" ", "", "development", "development"},
		{" \t", "", "", ""},
		{"\ufeffdev\u00a0", "", "", "development"},
	}
	for _, c := range cases {
		t.Setenv("CRONWATCH_ENV", c.cronwatch)
		t.Setenv("APP_ENV", c.app)
		t.Setenv("GO_ENV", c.own)
		if got := environment(); got != c.want {
			t.Errorf("CRONWATCH_ENV=%q APP_ENV=%q GO_ENV=%q: %q, want %q", c.cronwatch, c.app, c.own, got, c.want)
		}
	}
}
