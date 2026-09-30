package output

// Replays conformance/output.json, written by scripts/conformance.mjs from
// the TypeScript SDK: the cap, every redaction case, error text and what an
// expect rule sees.

import (
	"crypto/sha256"
	"encoding/hex"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"cronwatch.dev/go/internal/js"
)

func loadOutput(t *testing.T) *js.Object {
	t.Helper()
	data, err := os.ReadFile(filepath.Join("..", "..", "..", "..", "conformance", "output.json"))
	if err != nil {
		t.Fatal(err)
	}
	v, err := js.Parse(string(data))
	if err != nil {
		t.Fatal(err)
	}
	return v.(*js.Object)
}

func get(o *js.Object, key string) any {
	v, _ := o.Get(key)
	return v
}

// expand is the fixture's recipe for long text: a string, or
// { parts: [[piece, times], ...] } joined.
func expand(spec any) string {
	if s, ok := spec.(string); ok {
		return s
	}
	var b strings.Builder
	parts, _ := get(spec.(*js.Object), "parts").([]any)
	for _, p := range parts {
		pair := p.([]any)
		b.WriteString(strings.Repeat(pair[0].(string), int(pair[1].(float64))))
	}
	return b.String()
}

// digest is the fixture's form of a result: the text when it is 400 code
// units or fewer, else its length and the SHA-256 of its UTF-8.
func digest(text *string) any {
	if text == nil {
		return nil
	}
	if js.Length16(*text) <= 400 {
		return js.NewObject("text", *text)
	}
	sum := sha256.Sum256([]byte(*text))
	return js.NewObject("length", js.Length16(*text), "sha256", hex.EncodeToString(sum[:]))
}

func same(t *testing.T, what string, got, want any) {
	t.Helper()
	if g, w := js.Stringify(got), js.Stringify(want); g != w {
		t.Errorf("%s:\n got %.300s\nwant %.300s", what, g, w)
	}
}

func TestConformanceOutputCap(t *testing.T) {
	if n := get(loadOutput(t), "outputCap").(float64); int(n) != OutputCap {
		t.Fatalf("outputCap %v", n)
	}
}

func TestConformanceRedact(t *testing.T) {
	cases, _ := get(loadOutput(t), "redact").([]any)
	if len(cases) < 200 {
		t.Fatalf("only %d redact cases", len(cases))
	}
	for i, c := range cases {
		o := c.(*js.Object)
		input := expand(get(o, "input"))
		got := RedactSecrets(input)
		same(t, "redact case "+js.FormatNumber(float64(i))+" "+js.Quote(js.Head16(input, 60)), digest(&got), get(o, "result"))
	}
}

func TestConformanceRedactAndCap(t *testing.T) {
	f := loadOutput(t)
	if n := get(f, "redactEdge").(float64); int(n) != RedactEdge {
		t.Fatalf("redactEdge %v", n)
	}
	cases, _ := get(f, "redactAndCap").([]any)
	if len(cases) == 0 {
		t.Fatal("no redactAndCap cases")
	}
	for i, c := range cases {
		o := c.(*js.Object)
		got := RedactAndCap(expand(get(o, "input")), RedactSecrets)
		same(t, "redactAndCap case "+js.FormatNumber(float64(i)), digest(&got), get(o, "result"))
	}
}

func TestConformanceErrorMessage(t *testing.T) {
	cases, _ := get(loadOutput(t), "errorMessage").([]any)
	for i, c := range cases {
		o := c.(*js.Object)
		var text string
		if o.Has("value") {
			v := get(o, "value")
			if vo, ok := v.(*js.Object); ok && vo.Has("parts") {
				v = expand(vo)
			}
			text = ErrorMessage(v)
		} else {
			var frames []string
			list, _ := get(o, "frames").([]any)
			for _, f := range list {
				frames = append(frames, f.(string))
			}
			text = CapOutput(Describe(get(o, "name").(string), expand(get(o, "message")), frames))
		}
		same(t, "errorMessage case "+js.FormatNumber(float64(i)), digest(&text), get(o, "result"))
	}
	if len(cases) != 16 {
		t.Errorf("%d errorMessage cases", len(cases))
	}
}

// lines expands a recorder case's lines: plain strings, recipes, and
// { numbered, count, width } runs of numbered lines padded to a width.
func lines(spec []any) []string {
	var out []string
	for _, line := range spec {
		if o, ok := line.(*js.Object); ok && o.Has("numbered") {
			prefix := get(o, "numbered").(string)
			count, width := int(get(o, "count").(float64)), int(get(o, "width").(float64))
			for i := 0; i < count; i++ {
				head := prefix + js.FormatNumber(float64(i)) + " "
				out = append(out, head+strings.Repeat("x", max(0, width-js.Length16(head))))
			}
			continue
		}
		out = append(out, expand(line))
	}
	return out
}

func TestConformanceExpectText(t *testing.T) {
	cases, _ := get(loadOutput(t), "expectText").([]any)
	for _, c := range cases {
		o := c.(*js.Object)
		name := get(o, "name").(string)
		rec := NewRecorder()
		spec, _ := get(o, "lines").([]any)
		for _, line := range lines(spec) {
			rec.Log(line)
		}
		text := rec.ExpectText()
		same(t, name+": expectText", digest(text), get(o, "expectText"))
		same(t, name+": output", digest(rec.Output()), get(o, "output"))
		checks, _ := get(o, "checks").([]any)
		for _, ch := range checks {
			co := ch.(*js.Object)
			needle := get(co, "expect").(string)
			var result any
			if text == nil || !strings.Contains(*text, needle) {
				result = "Output did not contain " + js.Quote(needle)
			}
			same(t, name+": expect "+needle, result, get(co, "result"))
		}
	}
	if len(cases) != 11 {
		t.Errorf("%d expectText cases", len(cases))
	}
}
