package cronwatch

import (
	"os"
	"strings"

	"cronwatch.dev/go/internal/js"
)

// envVariables name the environment, the first one set to more than
// spaces wins (trimmed as JavaScript trims). The SDK reads
// NODE_ENV; Go has no one convention, so CronWatch's own variable comes
// first, then APP_ENV (as the PHP port reads it) and GO_ENV.
var envVariables = []string{"CRONWATCH_ENV", "APP_ENV", "GO_ENV"}

// environment is the environment's name, lowercased, or "" when no
// variable names one. "development", "dev", "local", "test", and "testing"
// count as development and "prod" as "production", as in the PHP port.
func environment() string {
	for _, name := range envVariables {
		if v := strings.ToLower(js.Trim(os.Getenv(name))); v != "" {
			switch v {
			case "prod":
				return "production"
			case "dev", "local", "test", "testing":
				return "development"
			}
			return v
		}
	}
	return ""
}

// blank is whether a token or secret is empty or only whitespace, as
// String.prototype.trim sees it. Such a value counts as not set, so the
// routes and handlers fail closed instead of taking it as a password.
func blank(s string) bool { return js.Trim(s) == "" }

// secretEnv is a secret from the environment (CRONWATCH_TOKEN,
// CRON_SECRET): "" when the variable is unset, empty, or blank, else its
// value as it is, untrimmed.
func secretEnv(name string) string {
	if v := os.Getenv(name); !blank(v) {
		return v
	}
	return ""
}
