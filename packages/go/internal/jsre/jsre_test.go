package jsre

// JavaScript's semantics the redaction patterns rely on, each checked
// against what V8 answers for the same pattern and input (written beside
// each case as the JavaScript expression it mirrors).

import (
	"strings"
	"testing"

	"cronwatch.dev/go/internal/js"
)

func replace(t *testing.T, source, flags, input, template string) string {
	t.Helper()
	re, err := Compile(source, flags)
	if err != nil {
		t.Fatal(err)
	}
	return re.ReplaceString(input, template)
}

func TestSemantics(t *testing.T) {
	cases := []struct{ source, flags, input, template, want string }{
		// "abcd".replace(/ab|abc/g, "X"): the first alternative that matches wins, not the longest.
		{`ab|abc`, "g", "abcd", "X", "Xcd"},
		// "aaab".replace(/a{1,3}ab/, "X"): greedy, then walked back.
		{`a{1,3}ab`, "", "aaab", "X", "X"},
		// "xaaa".replace(/a{2}/g, "[$&]")
		{`a{2}`, "g", "xaaa", "[$&]", "x[aa]a"},
		// "a1b2".replace(/\d/g, "#"), and only the first without g.
		{`\d`, "g", "a1b2", "#", "a#b#"},
		{`\d`, "", "a1b2", "#", "a#b2"},
		// \b is between ASCII word characters and anything else.
		{`\bab`, "g", "ab xab -ab \u00e9ab", "X", "X xab -X \u00e9X"},
		{`\Bab`, "g", "ab xab", "X", "ab xX"},
		// Lookbehind: "maxtokens=1 mytoken=2".replace(/\w+(?<!tokens)=\d/g, "X")
		{`\w+(?<!tokens)=\d`, "g", "maxtokens=1 mytoken=2", "X", "maxtokens=1 X"},
		// Lookahead, negative and positive.
		{`a(?!b)`, "g", "ab ac a", "X", "ab Xc X"},
		{`a(?=b)`, "g", "ab ac", "X", "Xb ac"},
		// Groups that did not take part are "" in a template.
		{`(a)|(b)`, "g", "ab", "[$1|$2]", "[a|][|b]"},
		// Optional groups and quantified groups.
		{`passw(?:or)?d`, "g", "passwd password passwod", "X", "X X passwod"},
		{`(?:ab ){0,3}c`, "g", "ab ab ab ab c", "X", "ab X"},
		// /i folds ASCII letters only: "\u017f" (long s) and "\u212a" (Kelvin) stay themselves.
		{`secret|key`, "gi", "SECRET Key \u017fecret \u212aey", "X", "X X \u017fecret \u212aey"},
		{`[a-z]+`, "gi", "AbC\u00c9", "X", "X\u00c9"},
		// \s is JavaScript's set: no-break space, ideographic space, line separator, BOM.
		{`a\sb`, "g", "a\u00a0b a\u3000b a\u2028b a\ufeffb a\u0085b", "X", "X X X X a\u0085b"},
		// A negated class counts an emoji as two code units.
		{`x[^\s]{3}`, "g", "x\U0001F600\U0001F600", "X", "X\ufffd"},
		{`x[^\s]{1,4}`, "g", "xab\U0001F600\U0001F600", "X", "X\U0001F600"},
		// Escaped punctuation, and "-" at the edge of a class.
		{`a\/b\.c[+/=-]`, "g", "a/b.c- a/b.c=", "X", "X X"},
		// An empty match moves on one unit.
		{`x*`, "g", "ab", "-", "-a-b-"},
		// "{" that is not a quantifier is a literal (Annex B).
		{`a{b`, "g", "a{b", "X", "X"},
		// $$ is a dollar.
		{`a`, "g", "a", "$$", "$"},
	}
	for _, c := range cases {
		if got := replace(t, c.source, c.flags, c.input, c.template); got != c.want {
			t.Errorf("%q.replace(/%s/%s, %q) = %q, want %q", c.input, c.source, c.flags, c.template, got, c.want)
		}
	}
}

func TestACharacterOutsideTheBMPIsItsTwoUnitsInTurn(t *testing.T) {
	// /a😀b/.test("a😀b"), and "x😀😀y".replace(/😀{2}/g, "-"): the quantifier
	// takes the second unit alone, as V8 reads a pattern without u.
	re := MustCompile("a\U0001F600b", "")
	if !re.MatchString("a\U0001F600b") {
		t.Error("/a\U0001F600b/ should match a\U0001F600b")
	}
	if re.MatchString("ab") {
		t.Error("/a\U0001F600b/ should not match ab")
	}
	if got := replace(t, "\U0001F600+", "g", "x\U0001F600\U0001F600y", "-"); got != "x--y" {
		t.Errorf("+ got %q", got)
	}
	if got := replace(t, "\U0001F600{2}", "g", "x\U0001F600\U0001F600y", "-"); got != "x\U0001F600\U0001F600y" {
		t.Errorf("{2} got %q", got)
	}
}

func TestReplaceFunc(t *testing.T) {
	re := MustCompile(`(k)=(?:(")[^"]*"|(')[^']*'|\w+)`, "g")
	got := js.FromUnits(re.ReplaceUnits(js.Units(`k="a b" k='c' k=d`), func(m *Match) []uint16 {
		q, ok := m.Group(2)
		if !ok {
			q, _ = m.Group(3)
		}
		return js.Units(m.Text(1) + "=" + js.FromUnits(q) + "_" + js.FromUnits(q))
	}))
	if got != `k="_" k='_' k=_` {
		t.Errorf("got %s", got)
	}
}

func TestLongBoundedRuns(t *testing.T) {
	// Go's regexp refuses {0,16384}; here it is an ordinary bound, and a run
	// of it does not grow the Go stack a frame per character.
	re := MustCompile(`<(?:[a-z]|-(?!--)){0,16384}>?`, "g")
	body := strings.Repeat("ab-", 5000)
	if got := re.ReplaceString("<"+body+">", "X"); got != "X" {
		t.Errorf("long body: %.40q", got)
	}
	if got := re.ReplaceString("<ab---", "X"); got != "X---" {
		t.Errorf("stops before three dashes: %q", got)
	}
	if got := MustCompile(`a{0,4096}`, "g").ReplaceString(strings.Repeat("a", 5000), "X"); got != "XXX" {
		t.Errorf("4096, then the rest, then the empty match at the end: %q", got)
	}
}

func TestCompileErrors(t *testing.T) {
	for _, source := range []string{`(a`, `a)`, `*a`, `[a`, `a{3,1}`, `a+?`, `(?<!a+)b`, `[z-a]`,
		// JavaScript reads these as something other than the letter (the audit).
		`(a)\1`, `\cJ`, `\k<x>`, `\p{L}`, `\u{41}`, `[\2]`} {
		if _, err := Compile(source, "g"); err == nil {
			t.Errorf("/%s/ compiled", source)
		}
	}
	if _, err := Compile(`a`, "y"); err == nil {
		t.Error("an unsupported flag was taken")
	}
}
