package cronwatch_test

// Replays conformance/client.json, which the SDK writes by driving its
// client through the public API: the run ids Start, Resume, and RecordRun
// take (runIds), and what the client keeps of stored data a newer release
// wrote (unknownFields, over the memory store here and over the SQL store
// in sqltest).

import (
	"context"
	"os"
	"path/filepath"
	"testing"

	cronwatch "cronwatch.dev/go"
	"cronwatch.dev/go/internal/clientreplay"
	"cronwatch.dev/go/internal/js"
)

var clientFixture = filepath.Join("..", "..", "conformance", "client.json")

func TestConformanceClientRunIDs(t *testing.T) {
	root := readJS(t, clientFixture)
	const t0 = 1767605400000
	ctx := context.Background()
	clients := map[string]*cronwatch.Client{}
	for i, c := range jsList(jsGet(root, "runIds")) {
		method, id := jsGet(c, "method").(string), jsGet(c, "id").(string)
		cw := clients[method]
		if cw == nil {
			var err error
			cw, err = cronwatch.New(cronwatch.WithStore(cronwatch.NewMemoryStore()), cronwatch.WithClock(func() int64 { return t0 }),
				cronwatch.WithErrorHandler(func(error, string) {}))
			if err != nil {
				t.Fatal(err)
			}
			defer cw.Close()
			clients[method] = cw
		}
		job := cw.MustJob("j")
		var err error
		switch method {
		case "start":
			var h *cronwatch.RunHandle
			if h, err = job.Start(ctx, cronwatch.WithRunID(id)); err == nil {
				h.Finish(ctx)
			}
		case "resume":
			_, err = job.Resume(ctx, id)
		case "recordRun":
			finished, duration := int64(t0), int64(1000)
			_, err = cw.RecordRun(ctx, cronwatch.Run{
				ID: id, Job: "j", Status: cronwatch.StatusOK, StartedAt: t0 - 1000, FinishedAt: &finished,
				DurationMs: &duration, Metrics: cronwatch.Metrics{}, Trigger: "run",
			})
		default:
			t.Fatalf("case %d: unknown method %q", i, method)
		}
		want, _ := jsGet(c, "error").(string)
		got := ""
		if err != nil {
			got = err.Error()
		}
		if got != want {
			t.Errorf("case %d %s(%s): got error %q, want %q", i, method, js.Quote(id), got, want)
		}
	}
}

// readJS reads a JSON file in JavaScript's key order.
func readJS(t *testing.T, path string) *js.Object {
	t.Helper()
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	v, err := js.Parse(string(data))
	if err != nil {
		t.Fatal(err)
	}
	return v.(*js.Object)
}

// jsGet is o[key] for a parsed object.
func jsGet(o any, key string) any {
	v, _ := o.(*js.Object).Get(key)
	return v
}

// jsList is a parsed array.
func jsList(v any) []any { list, _ := v.([]any); return list }

func TestConformanceClientUnknownFields(t *testing.T) {
	clientreplay.UnknownFields(t, clientFixture, cronwatch.NewMemoryStore())
}
