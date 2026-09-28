// Package jsre is a small backtracking regular expression engine with
// JavaScript's semantics, for the SDK's secret redaction patterns.
//
// Go's regexp cannot run them: it refuses a repeat count past 1000 (the
// patterns bound runs at 4096 and 16384), has no lookahead or lookbehind,
// and matches over runes, where JavaScript (without the u flag) matches
// over UTF-16 code units, so an emoji counts as two characters to a
// bounded quantifier and to a negated class. This engine matches over
// code units, as V8 does, so the SDK's patterns can be written here
// verbatim and match exactly what they match there.
//
// It reads the subset of JavaScript's syntax those patterns use, in
// non-unicode mode: literals and escapes (\d \s \w \b and their negations,
// \n \t \r \f \v \0 \xHH \uHHHH, and any escaped punctuation), character
// classes with ranges and negation, capturing and non-capturing groups,
// lookahead, fixed-length lookbehind, alternation, greedy quantifiers
// (? * + {n} {n,} {n,m}), and the flags g and i. The i flag folds ASCII
// letters only. JavaScript's /i without u canonicalizes with toUpperCase
// but never maps a character outside ASCII onto one inside it (so the long s, U+017F,
// never matches "s" and the Kelvin sign never matches "k"), which for
// patterns whose letters are all ASCII is exactly ASCII folding.
package jsre

import (
	"fmt"
	"strconv"
	"strings"
	"unicode/utf16"
)

// kinds of syntax tree node.
type kind int

const (
	kAlt      kind = iota // children: the alternatives
	kSeq                  // children: the terms in order
	kChar                 // one code unit from set
	kGroup                // children[0] inside; capture > 0 captures
	kLook                 // lookahead or lookbehind around children[0]
	kWordB                // \b
	kNotWordB             // \B
	kStart                // ^
	kEnd                  // $
)

// tree is a parsed pattern.
type tree struct {
	kind     kind
	children []*tree
	set      *charSet
	capture  int
	behind   bool
	negate   bool
	min, max int // the quantifier; max < 0 is unbounded
}

type parser struct {
	src      []rune
	i        int
	fold     bool
	captures int
}

func parse(source string, fold bool) (*tree, int, error) {
	p := &parser{src: []rune(source), fold: fold}
	t, err := p.disjunction()
	if err != nil {
		return nil, 0, err
	}
	if p.i < len(p.src) {
		return nil, 0, p.fail("unmatched ')'")
	}
	return t, p.captures, nil
}

func (p *parser) fail(what string) error {
	return fmt.Errorf("jsre: %s at %d in /%s/", what, p.i, string(p.src))
}

func (p *parser) more() bool { return p.i < len(p.src) }

func (p *parser) peek() rune { return p.src[p.i] }

func (p *parser) disjunction() (*tree, error) {
	alt := &tree{kind: kAlt}
	for {
		seq, err := p.alternative()
		if err != nil {
			return nil, err
		}
		alt.children = append(alt.children, seq)
		if p.more() && p.peek() == '|' {
			p.i++
			continue
		}
		break
	}
	if len(alt.children) == 1 {
		return alt.children[0], nil
	}
	alt.min, alt.max = 1, 1
	return alt, nil
}

func (p *parser) alternative() (*tree, error) {
	seq := &tree{kind: kSeq, min: 1, max: 1}
	for p.more() && p.peek() != '|' && p.peek() != ')' {
		t, err := p.term()
		if err != nil {
			return nil, err
		}
		seq.children = append(seq.children, t)
	}
	return seq, nil
}

func (p *parser) term() (*tree, error) {
	c := p.peek()
	var t *tree
	switch c {
	case '^':
		p.i++
		return &tree{kind: kStart, min: 1, max: 1}, nil
	case '$':
		p.i++
		return &tree{kind: kEnd, min: 1, max: 1}, nil
	case '(':
		p.i++
		g := &tree{kind: kGroup, min: 1, max: 1}
		switch {
		case p.has("?:"):
			p.i += 2
		case p.has("?="), p.has("?!"):
			g.kind, g.negate = kLook, p.src[p.i+1] == '!'
			p.i += 2
		case p.has("?<="), p.has("?<!"):
			g.kind, g.behind, g.negate = kLook, true, p.src[p.i+2] == '!'
			p.i += 3
		case p.has("?"):
			return nil, p.fail("unsupported group")
		default:
			p.captures++
			g.capture = p.captures
		}
		inner, err := p.disjunction()
		if err != nil {
			return nil, err
		}
		if !p.more() || p.peek() != ')' {
			return nil, p.fail("missing ')'")
		}
		p.i++
		g.children = []*tree{inner}
		t = g
		if g.kind == kLook && g.behind {
			// A lookbehind cannot be quantified.
			return t, nil
		}
	case '[':
		p.i++
		set, err := p.class()
		if err != nil {
			return nil, err
		}
		t = &tree{kind: kChar, set: set, min: 1, max: 1}
	case '.':
		p.i++
		set := newSet()
		set.addRange(0, 0xffff)
		set.remove('\n')
		set.remove('\r')
		set.remove(0x2028)
		set.remove(0x2029)
		t = &tree{kind: kChar, set: set, min: 1, max: 1}
	case '\\':
		p.i++
		if !p.more() {
			return nil, p.fail("\\ at end of pattern")
		}
		switch p.peek() {
		case 'b':
			p.i++
			return &tree{kind: kWordB, min: 1, max: 1}, nil
		case 'B':
			p.i++
			return &tree{kind: kNotWordB, min: 1, max: 1}, nil
		}
		set := newSet()
		if err := p.escape(set, false); err != nil {
			return nil, err
		}
		t = &tree{kind: kChar, set: p.folded(set), min: 1, max: 1}
	case '*', '+', '?':
		return nil, p.fail("nothing to repeat")
	case ')':
		return nil, p.fail("unmatched ')'")
	default:
		p.i++
		set := newSet()
		set.add(c)
		t = &tree{kind: kChar, set: p.folded(set), min: 1, max: 1}
	}
	return p.quantifier(t)
}

func (p *parser) has(prefix string) bool {
	return strings.HasPrefix(string(p.src[p.i:min(len(p.src), p.i+len(prefix))]), prefix)
}

func (p *parser) quantifier(t *tree) (*tree, error) {
	if !p.more() {
		return t, nil
	}
	lo, hi := 1, 1
	switch p.peek() {
	case '*':
		lo, hi = 0, -1
		p.i++
	case '+':
		lo, hi = 1, -1
		p.i++
	case '?':
		lo, hi = 0, 1
		p.i++
	case '{':
		// {n}, {n,} or {n,m}; anything else is a literal "{" (Annex B).
		j := p.i + 1
		num := func() (int, bool) {
			start := j
			for j < len(p.src) && p.src[j] >= '0' && p.src[j] <= '9' {
				j++
			}
			if j == start {
				return 0, false
			}
			n, err := strconv.Atoi(string(p.src[start:j]))
			return n, err == nil
		}
		n, ok := num()
		if !ok {
			return t, nil
		}
		m := n
		if j < len(p.src) && p.src[j] == ',' {
			j++
			if j < len(p.src) && p.src[j] == '}' {
				m = -1
			} else if m, ok = num(); !ok {
				return t, nil
			}
		}
		if j >= len(p.src) || p.src[j] != '}' {
			return t, nil
		}
		if m >= 0 && m < n {
			return nil, p.fail("numbers out of order in {} quantifier")
		}
		p.i = j + 1
		lo, hi = n, m
	default:
		return t, nil
	}
	if p.more() && p.peek() == '?' {
		return nil, p.fail("lazy quantifiers are not supported")
	}
	if t.kind == kLook && t.behind {
		return nil, p.fail("a lookbehind cannot be quantified")
	}
	// A quantified term is wrapped, so its own min and max stay 1.
	if t.min != 1 || t.max != 1 {
		t = &tree{kind: kGroup, children: []*tree{t}, min: 1, max: 1}
	}
	t.min, t.max = lo, hi
	return t, nil
}

// folded is the set with the other case of every ASCII letter in it, when
// the pattern has the i flag.
func (p *parser) folded(s *charSet) *charSet {
	if !p.fold {
		return s
	}
	for c := 'A'; c <= 'Z'; c++ {
		if s.hasRaw(uint16(c)) || s.hasRaw(uint16(c+32)) {
			s.add(c)
			s.add(c + 32)
		}
	}
	return s
}

func (p *parser) class() (*charSet, error) {
	set := newSet()
	negate := false
	if p.more() && p.peek() == '^' {
		negate = true
		p.i++
	}
	for {
		if !p.more() {
			return nil, p.fail("missing ']'")
		}
		if p.peek() == ']' {
			p.i++
			break
		}
		lo, loIsChar, err := p.classAtom(set)
		if err != nil {
			return nil, err
		}
		// A range a-b, unless "-" ends the class or either end is a class
		// escape such as \s (then "-" is literal, as Annex B reads it).
		if p.i+1 < len(p.src) && p.peek() == '-' && p.src[p.i+1] != ']' {
			save := p.i
			p.i++
			probe := newSet()
			hi, hiIsChar, err := p.classAtom(probe)
			if err != nil {
				return nil, err
			}
			if loIsChar && hiIsChar {
				if hi < lo {
					return nil, p.fail("range out of order in character class")
				}
				set.addRange(lo, hi)
				continue
			}
			// Not a range: the "-" and what follows are members on their own.
			if loIsChar {
				set.add(lo)
			}
			set.add('-')
			p.i = save + 1
			continue
		}
		if loIsChar {
			set.add(lo)
		}
	}
	set = p.folded(set)
	set.negate = negate
	return set, nil
}

// classAtom reads one member of a class: a character (returned, with
// true), or a class escape added to set (false).
func (p *parser) classAtom(set *charSet) (rune, bool, error) {
	c := p.peek()
	if c != '\\' {
		p.i++
		return c, true, nil
	}
	p.i++
	if !p.more() {
		return 0, false, p.fail("\\ at end of pattern")
	}
	if p.peek() == 'b' {
		p.i++
		return '\b', true, nil
	}
	single := newSet()
	if err := p.escape(single, true); err != nil {
		return 0, false, err
	}
	if r, ok := single.single(); ok {
		return r, true, nil
	}
	set.union(single)
	return 0, false, nil
}

// escape reads what follows a backslash into set.
func (p *parser) escape(set *charSet, inClass bool) error {
	c := p.peek()
	p.i++
	switch c {
	case 'd':
		set.addRange('0', '9')
	case 'D':
		set.addRange(0, 0xffff)
		for r := '0'; r <= '9'; r++ {
			set.remove(r)
		}
	case 'w':
		addWord(set)
	case 'W':
		set.addRange(0, 0xffff)
		w := newSet()
		addWord(w)
		for r := rune(0); r < 128; r++ {
			if w.hasRaw(uint16(r)) {
				set.remove(r)
			}
		}
	case 's':
		set.space = true
	case 'S':
		set.addRange(0, 0xffff)
		set.notSpace = true
	case 'n':
		set.add('\n')
	case 't':
		set.add('\t')
	case 'r':
		set.add('\r')
	case 'f':
		set.add('\f')
	case 'v':
		set.add('\v')
	case '0':
		set.add(0)
	case 'x', 'u':
		width := 2
		if c == 'u' {
			width = 4
		}
		if p.i+width <= len(p.src) {
			if n, err := strconv.ParseUint(string(p.src[p.i:p.i+width]), 16, 32); err == nil {
				p.i += width
				set.add(rune(n))
				return nil
			}
		}
		set.add(c)
	default:
		if c >= 0x10000 {
			// Written as its two code units, as JavaScript holds it.
			return fmt.Errorf("jsre: escape of a character outside the BMP is not supported")
		}
		set.add(c)
	}
	return nil
}

func addWord(s *charSet) {
	s.addRange('a', 'z')
	s.addRange('A', 'Z')
	s.addRange('0', '9')
	s.add('_')
}

// charSet is a set of UTF-16 code units: a bitmap of the whole range,
// built once at compile time so a test is one lookup.
type charSet struct {
	bits     [1 << 16 / 64]uint64
	space    bool // JavaScript's \s
	notSpace bool // everything but \s (with bits holding all)
	negate   bool
	final    *[1 << 16 / 64]uint64
}

func newSet() *charSet { return &charSet{} }

func (s *charSet) add(r rune) {
	if r >= 0x10000 {
		// A character outside the BMP in a pattern would be two code units;
		// the redaction patterns hold none.
		hi, lo := utf16.EncodeRune(r)
		s.add(hi)
		s.add(lo)
		return
	}
	s.bits[r>>6] |= 1 << (uint(r) & 63)
}

func (s *charSet) addRange(lo, hi rune) {
	for r := lo; r <= hi && r < 0x10000; r++ {
		s.add(r)
	}
}

func (s *charSet) remove(r rune) { s.bits[r>>6] &^= 1 << (uint(r) & 63) }

func (s *charSet) hasRaw(c uint16) bool { return s.bits[c>>6]&(1<<(c&63)) != 0 }

func (s *charSet) union(o *charSet) {
	for i := range s.bits {
		s.bits[i] |= o.bits[i]
	}
	s.space = s.space || o.space
	if o.notSpace {
		s.notSpace = true
	}
}

// single is the one character in a set holding exactly one plain character.
func (s *charSet) single() (rune, bool) {
	if s.space || s.notSpace || s.negate {
		return 0, false
	}
	found := rune(-1)
	for i, w := range s.bits {
		for w != 0 {
			if found >= 0 {
				return 0, false
			}
			b := 0
			for w&(1<<uint(b)) == 0 {
				b++
			}
			found = rune(i*64 + b)
			w &^= 1 << uint(b)
		}
	}
	return found, found >= 0
}

// freeze works out the final membership bitmap: \s, "everything but \s"
// and negation folded in.
func (s *charSet) freeze() {
	if s.final != nil {
		return
	}
	f := s.bits
	for i := range f {
		if s.space {
			f[i] |= spaceBits[i]
		}
		if s.notSpace {
			f[i] &^= spaceBits[i]
		}
		if s.negate {
			f[i] = ^f[i]
		}
	}
	s.final = &f
}

// spaceBits is \s as a bitmap.
var spaceBits = func() (b [1 << 16 / 64]uint64) {
	for c := 0; c < 1<<16; c++ {
		if isSpace(uint16(c)) {
			b[c>>6] |= 1 << (uint(c) & 63)
		}
	}
	return b
}()

func (s *charSet) has(c uint16) bool { return s.final[c>>6]&(1<<(c&63)) != 0 }

// isSpace is JavaScript's \s: WhiteSpace and LineTerminator.
func isSpace(c uint16) bool {
	switch c {
	case '\t', '\n', '\v', '\f', '\r', ' ', 0xa0, 0x1680, 0x2028, 0x2029, 0x202f, 0x205f, 0x3000, 0xfeff:
		return true
	}
	return c >= 0x2000 && c <= 0x200a
}
