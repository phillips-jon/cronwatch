package cronwatch

import (
	"os"
	"testing"
	"time"
)

// TestMain reads a schedule without a timezone in UTC, as the conformance
// fixtures were made (scripts/conformance.mjs runs with TZ=UTC).
func TestMain(m *testing.M) {
	time.Local = time.UTC
	os.Exit(m.Run())
}
