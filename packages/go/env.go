package cronwatch

import (
	"os"
	"strings"
)

// envVariables name the environment, first set wins. The SDK reads
// NODE_ENV; Go has no one convention, so CronWatch's own variable comes
// first, then APP_ENV (as the PHP port reads it) and GO_ENV.
var envVariables = []string{"CRONWATCH_ENV", "APP_ENV", "GO_ENV"}

// environment is the environment's name, lowercased, or "" when no
// variable names one. "development", "dev", "local", "test" and "testing"
// count as development and "prod" as "production", as in the PHP port.
func environment() string {
	for _, name := range envVariables {
		if v := strings.ToLower(strings.TrimSpace(os.Getenv(name))); v != "" {
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
