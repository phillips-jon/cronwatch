package cronwatch

// conformance/store.json's foreignRows jobs, as the client reads a stored
// job (readStoredJob): a definition that is not a JSON object (the zero
// Definition a store reads it as) becomes {name} and is unreadable, and
// tags are kept only as a list of strings. sqltest replays the rows
// through the SQLite store, and the check and pages over them.

import (
	"fmt"
	"testing"

	"cronwatch.dev/go/internal/js"
)

func TestConformanceForeignJobRows(t *testing.T) {
	f := field(fixture(t, "store"), "foreignRows").(*js.Object)
	count := 0
	for i, c := range objects(f, "rows") {
		if field(c, "table") != "jobs" {
			continue
		}
		row := field(c, "row").(*js.Object)
		read := field(c, "read").(*js.Object)
		stored := StoredJob{Name: field(row, "name").(string), CreatedAt: toInt(field(read, "createdAt")), UpdatedAt: toInt(field(read, "updatedAt"))}
		if text, ok := field(row, "definition").(string); ok {
			if v, err := js.Parse(text); err == nil {
				if o, ok := v.(*js.Object); ok {
					stored.Definition = Definition{o: o}
				}
			}
		}
		got := readStoredJob(stored)
		sameJSON(t, fmt.Sprintf("foreign job %d", i), sorted(js.NewObject("name", got.Name, "definition", got.Definition.JSValue(),
			"createdAt", got.CreatedAt, "updatedAt", got.UpdatedAt)), sorted(read))
		if readable := evaluable(got) == nil; readable != field(c, "readable") {
			t.Errorf("foreign job %d: readable %v", i, readable)
		}
		count++
	}
	if count < 8 {
		t.Errorf("only %d foreign job rows", count)
	}
}
