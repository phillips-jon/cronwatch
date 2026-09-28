package cronwatch

import "cronwatch.dev/go/internal/output"

// RedactSecrets is the default redaction: it blanks values that look like
// secrets (secret-named pairs, credentials in URLs, authorization headers,
// private keys, JWTs, webhook URLs, and common API key formats), exactly as
// the SDK's default does. A WithRedact function can call it and add its own
// patterns on top.
func RedactSecrets(text string) string {
	return output.RedactSecrets(text)
}
