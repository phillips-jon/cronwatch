package main

import (
	"context"
	"path/filepath"
	"strings"
	"testing"
)

// TestReportThenCheck runs the two crontab lines, as two processes would,
// on one SQLite file.
func TestReportThenCheck(t *testing.T) {
	t.Setenv("CRONWATCH_DB", filepath.Join(t.TempDir(), "cronwatch.db"))
	ctx := context.Background()
	var out strings.Builder
	if err := run(ctx, []string{"check"}, &out); err != nil {
		t.Fatal(err)
	}
	if got := out.String(); got != "cronwatch: checked 1 job, sent 0 alerts\n" {
		t.Errorf("a check before any run: %q", got)
	}
	if err := run(ctx, []string{"report"}, &out); err != nil {
		t.Fatal(err)
	}
	out.Reset()
	if err := run(ctx, []string{"check"}, &out); err != nil {
		t.Fatal(err)
	}
	if got := out.String(); got != "cronwatch: checked 1 job, sent 0 alerts\n" {
		t.Errorf("a check after the run: %q", got)
	}
	if err := run(ctx, []string{"nope"}, &out); err == nil {
		t.Error("an unknown command ran")
	}
}
