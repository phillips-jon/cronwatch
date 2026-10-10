package cronwatch

// conformance/format.json: alert titles and messages, numbers as
// toLocaleString writes them, the output cap, stored definitions, and
// expect rules.

import (
	"crypto/sha256"
	"encoding/hex"
	"regexp"
	"strings"
	"testing"

	"cronwatch.dev/go/internal/js"
	"cronwatch.dev/go/internal/output"
)

// draftFrom reads an alert draft, { type, run, details }.
func draftFrom(t *testing.T, v any) alertDraft {
	o := v.(*js.Object)
	d := alertDraft{Type: AlertType(field(o, "type").(string))}
	if r := field(o, "run"); r != nil {
		run, err := runFrom(r)
		if err != nil {
			t.Fatal(err)
		}
		d.Run = &run
	}
	details, _ := field(o, "details").(*js.Object)
	d.Details = detailsFrom(d.Type, details)
	return d
}

// JSValue is the draft as the SDK writes one.
func (d alertDraft) JSValue() any {
	var run any
	if d.Run != nil {
		run = d.Run.JSValue()
	}
	return js.NewObject("type", string(d.Type), "run", run, "details", d.Details.jsValue())
}

// jsRule is an expect rule from a fixture: a string, a JavaScript RegExp
// as { regex: { source, flags } }, or a function as { callable: true }.
func jsRule(t *testing.T, v any) expectRule {
	switch x := v.(type) {
	case string:
		return containsRule(x)
	case *js.Object:
		if re, ok := field(x, "regex").(*js.Object); ok {
			source, flags := field(re, "source").(string), field(re, "flags").(string)
			goSource := source
			if strings.Contains(flags, "i") {
				goSource = "(?i)" + source
			}
			return jsRegexpRule{source, flags, regexp.MustCompile(goSource)}
		}
		return funcRule(func(o string) bool { return js.Length16(o) > 3 })
	}
	t.Fatalf("not an expect rule: %v", v)
	return nil
}

func TestConformanceFormat(t *testing.T) {
	f := fixture(t, "format")
	for i, c := range objects(f, "alerts") {
		def, _ := definitionFrom(field(c, "definition"))
		got := composeAlert(draftFrom(t, field(c, "draft")), def, int64(field(c, "now").(float64)))
		sameJSON(t, "alert "+string(rune('a'+i)), got.JSValue(), field(c, "alert"))
	}
	for _, c := range objects(f, "numbers") {
		n := field(c, "n").(float64)
		if got := formatNumber(n); got != field(c, "text") {
			t.Errorf("formatNumber(%s) = %q, want %q", js.FormatNumber(n), got, field(c, "text"))
		}
	}
	for _, c := range objects(f, "capOutput") {
		text := field(c, "prefix").(string) + strings.Repeat(field(c, "piece").(string), int(field(c, "times").(float64)))
		out := output.CapOutput(text)
		sum := sha256.Sum256([]byte(out))
		if float64(js.Length16(out)) != field(c, "length") || hex.EncodeToString(sum[:]) != field(c, "sha256") {
			t.Errorf("capOutput(%q x %v): length %d", field(c, "piece"), field(c, "times"), js.Length16(out))
		}
	}
	for _, c := range objects(f, "toStored") {
		in := field(c, "definition").(*js.Object)
		var rule expectRule
		if v, ok := in.Get("expect"); ok {
			rule = jsRule(t, v)
		}
		sameJSON(t, "toStored", toStored(in, rule).JSValue(), field(c, "stored"))
	}
	for _, c := range objects(f, "checkExpectation") {
		out, _ := field(c, "output").(string)
		var text *string
		if field(c, "output") != nil {
			text = &out
		}
		got := checkExpectation(jsRule(t, field(c, "expect")), text)
		sameJSON(t, "checkExpectation", strOrNull(got), field(c, "result"))
	}
}
