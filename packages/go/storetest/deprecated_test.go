package storetest

import (
	"go/ast"
	"go/doc"
	"go/parser"
	"go/token"
	"path/filepath"
	"strings"
	"testing"
)

// Run is the one name of this package the 1.x releases promise (the
// Stability page); every other exported name is the module's own test kit,
// deprecated, and goes in 1.0 (the Deprecations page). A new exported name
// must say so too.
func TestOnlyRunIsNotDeprecated(t *testing.T) {
	fset := token.NewFileSet()
	names, err := filepath.Glob("*.go")
	if err != nil {
		t.Fatal(err)
	}
	var list []*ast.File
	for _, name := range names {
		if strings.HasSuffix(name, "_test.go") {
			continue
		}
		f, err := parser.ParseFile(fset, name, nil, parser.ParseComments)
		if err != nil {
			t.Fatal(err)
		}
		list = append(list, f)
	}
	p, err := doc.NewFromFiles(fset, list, "cronwatch.dev/go/storetest")
	if err != nil {
		t.Fatal(err)
	}
	deprecated := func(text string) bool {
		return strings.Contains(text, "\nDeprecated: ") || strings.HasPrefix(text, "Deprecated: ")
	}
	check := func(name, text string) {
		t.Helper()
		if name == "Run" {
			if deprecated(text) {
				t.Error("Run is the promised entry point, not deprecated")
			}
			return
		}
		if !deprecated(text) {
			t.Errorf("%s is exported without a Deprecated: paragraph", name)
		}
	}
	for _, f := range p.Funcs {
		check(f.Name, f.Doc)
	}
	for _, typ := range p.Types {
		check(typ.Name, typ.Doc)
		for _, f := range typ.Funcs {
			check(f.Name, f.Doc)
		}
	}
	for _, v := range append(p.Consts, p.Vars...) {
		for _, n := range v.Names {
			if ast.IsExported(n) {
				check(n, v.Doc)
			}
		}
	}
}
