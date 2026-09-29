package storetest

import (
	"context"
	"sync"
	"testing"

	cronwatch "cronwatch.dev/go"
)

// The audit: the kept alerts could only be read through the field, which
// races with a send still under way. List takes the lock (run with -race).
func TestCaptureListWhileSending(t *testing.T) {
	c := &Capture{}
	var wg sync.WaitGroup
	for range 8 {
		wg.Go(func() {
			for range 50 {
				_ = c.Send(context.Background(), cronwatch.Alert{Type: cronwatch.AlertFailed}, cronwatch.ChannelContext{})
				_ = c.List()
			}
		})
	}
	wg.Wait()
	list := c.List()
	if len(list) != 400 {
		t.Fatalf("%d kept", len(list))
	}
	list[0].Job = "changed"
	if c.List()[0].Job == "changed" {
		t.Fatal("List handed out the kept slice")
	}
}
