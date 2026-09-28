package cronwatch

import (
	"fmt"
	"regexp"
	"testing"
)

func TestRedactSecretsIsTheDefault(t *testing.T) {
	in := "password=hunter2 and ok"
	if got := RedactSecrets(in); got == in {
		t.Fatalf("RedactSecrets(%q) left the secret in: %q", in, got)
	}
}

// A WithRedact function that keeps the default and adds a pattern of its own.
func ExampleRedactSecrets() {
	card := regexp.MustCompile(`\d{16}`)
	redact := func(text string) string { return card.ReplaceAllString(RedactSecrets(text), "[card]") }
	fmt.Println(redact("charged 4242424242424242"))
	// Output: charged [card]
}
