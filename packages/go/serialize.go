package cronwatch

// Expect rules and how a definition is stored (serialize.ts).

import (
	"fmt"
	"regexp"
	"strings"

	"cronwatch.dev/go/internal/js"
)

// expectRule is a job's expect option: what a successful run's output must
// satisfy, and how the rule is described in the stored definition.
type expectRule interface {
	// check is nil when the output passes, or why it does not.
	check(output string) *string
	// describe is the stored definition's "expect".
	describe() string
}

// containsRule: the output must contain the text.
type containsRule string

func (r containsRule) check(output string) *string {
	if strings.Contains(output, string(r)) {
		return nil
	}
	return ptr("Output did not contain " + js.Quote(string(r)))
}

func (r containsRule) describe() string { return "contains " + js.Quote(string(r)) }

// regexpRule: a Go regular expression must match somewhere in the output.
// It is written as /source/, as JavaScript writes a RegExp, with Go's
// syntax inside (flags are inline in Go, "(?i)").
type regexpRule struct{ re *regexp.Regexp }

func (r regexpRule) check(output string) *string {
	if r.re.MatchString(output) {
		return nil
	}
	return ptr("Output did not match " + r.text())
}

func (r regexpRule) text() string { return "/" + r.re.String() + "/" }

func (r regexpRule) describe() string { return "matches " + r.text() }

// jsRegexpRule is a JavaScript RegExp read from a fixture: matched with
// Go's engine, written as JavaScript writes it (/source/flags). Only the
// conformance tests make one.
type jsRegexpRule struct {
	source, flags string
	re            *regexp.Regexp
}

func (r jsRegexpRule) check(output string) *string {
	if r.re.MatchString(output) {
		return nil
	}
	return ptr("Output did not match /" + r.source + "/" + r.flags)
}

func (r jsRegexpRule) describe() string { return "matches /" + r.source + "/" + r.flags }

// funcRule: a function must return true for the output.
type funcRule func(output string) bool

func (r funcRule) check(output string) (why *string) {
	defer func() {
		if p := recover(); p != nil {
			why = ptr(fmt.Sprintf("Output check threw: %v", p))
		}
	}()
	if r(output) {
		return nil
	}
	return ptr("Output did not pass the expect() check")
}

func (r funcRule) describe() string { return "custom function" }

// toStored is a definition as a store can hold it (serialize.ts toStored):
// the fields as given, less expect, which goes last as a description.
func toStored(fields *js.Object, rule expectRule) Definition {
	out := &js.Object{}
	for _, k := range fields.Keys() {
		if k == "expect" {
			continue
		}
		v, _ := fields.Get(k)
		out.Set(k, js.CloneValue(v))
	}
	if rule != nil {
		out.Set("expect", rule.describe())
	}
	return Definition{o: out}
}

// checkExpectation is serialize.ts checkExpectation: nil when there is no
// rule or the output satisfies it, otherwise why not.
func checkExpectation(rule expectRule, output *string) *string {
	if rule == nil {
		return nil
	}
	text := ""
	if output != nil {
		text = *output
	}
	return rule.check(text)
}
