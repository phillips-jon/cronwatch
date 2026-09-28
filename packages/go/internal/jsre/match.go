package jsre

import (
	"fmt"
	"strings"

	"cronwatch.dev/go/internal/js"
)

// Regexp is a compiled pattern. It is read-only once compiled, so one may
// be shared by every goroutine; each match keeps its own state.
type Regexp struct {
	source   string
	flags    string
	global   bool
	start    *node
	captures int
	loops    int
	// first holds the code units a match can start with, or nil when a
	// match can start with anything (or be empty), so the search skips
	// positions no match could start at without running the pattern.
	first *[1 << 16 / 64]uint64
}

// MustCompile is Compile for patterns known to be good.
func MustCompile(source, flags string) *Regexp {
	re, err := Compile(source, flags)
	if err != nil {
		panic(err)
	}
	return re
}

// Compile reads a JavaScript pattern's source (what goes between the
// slashes) and its flags (g and i).
func Compile(source, flags string) (*Regexp, error) {
	fold := false
	re := &Regexp{source: source, flags: flags}
	for _, f := range flags {
		switch f {
		case 'i':
			fold = true
		case 'g':
			re.global = true
		default:
			return nil, fmt.Errorf("jsre: flag %q is not supported", f)
		}
	}
	t, captures, err := parse(source, fold)
	if err != nil {
		return nil, err
	}
	re.captures = captures
	c := &compiler{re: re}
	re.start = c.compile(t, &node{op: opAccept})
	guard(re.start, map[*node]bool{})
	if c.err != nil {
		return nil, c.err
	}
	re.loops = c.loops
	if f, ok := firstSet(t); ok {
		re.first = f
	}
	return re, nil
}

// String is the pattern as JavaScript writes it: /source/flags.
func (re *Regexp) String() string { return "/" + re.source + "/" + re.flags }

type opcode int

const (
	opRep      opcode = iota // min to max code units from set, greedy
	opPredRep                // min to max repeats of a one-unit body, greedy
	opAlt                    // try each of alts in turn
	opCapOpen                // a capture starts
	opCapClose               // a capture ends
	opLoop                   // a quantified group of any width
	opLoopBack               // the end of one pass through a loop's body
	opLook                   // lookahead
	opBehind                 // lookbehind of a fixed width
	opWordB                  // \b
	opNotWordB               // \B
	opStart                  // ^
	opEnd                    // $
	opAccept                 // the whole pattern (or a lookahead's body) matched
	opAcceptAt               // a lookbehind's body matched, if it ends where the lookbehind stands
)

// node is one step of the compiled pattern. Each node knows the step after
// it (next), so the matcher runs a pattern as a chain and backtracks by
// returning false up the Go call stack.
type node struct {
	op       opcode
	set      *charSet
	min, max int
	next     *node
	alts     []*node
	body     *node
	index    int // capture number or loop number
	negate   bool
	width    int // a lookbehind's width
	loop     *node
	// guard, on a repeat, is what the step after it must start with (nil
	// when that is not known), so walking a greedy run back skips the
	// positions where the rest of the pattern cannot even begin.
	guard *charSet
	// keep, on a lookaround, says whether its body has captures to undo.
	keep bool
}

type compiler struct {
	re    *Regexp
	loops int
	err   error
}

// compile builds the chain for t, which continues with cont.
func (c *compiler) compile(t *tree, cont *node) *node {
	if t.min == 1 && t.max == 1 {
		return c.once(t, cont)
	}
	if t.kind == kChar {
		t.set.freeze()
		return &node{op: opRep, set: t.set, min: t.min, max: t.max, next: cont}
	}
	lo, hi := width(t.children[0])
	if lo == 1 && hi == 1 && !hasCapture(t) && t.kind == kGroup && t.capture == 0 {
		// Every pass takes exactly one code unit (a class, or an
		// alternation of single characters with lookarounds), so the
		// passes are counted greedily and walked back, rather than taking
		// one Go call per pass: a {0,16384} run stays shallow.
		body := c.compile(t.children[0], &node{op: opAccept})
		return &node{op: opPredRep, body: body, min: t.min, max: t.max, next: cont}
	}
	loop := &node{op: opLoop, min: t.min, max: t.max, next: cont, index: c.loops}
	c.loops++
	once := *t
	once.min, once.max = 1, 1
	loop.body = c.once(&once, &node{op: opLoopBack, loop: loop})
	return loop
}

// once builds the chain for one pass of t.
func (c *compiler) once(t *tree, cont *node) *node {
	switch t.kind {
	case kSeq:
		for i := len(t.children) - 1; i >= 0; i-- {
			cont = c.compile(t.children[i], cont)
		}
		return cont
	case kAlt:
		n := &node{op: opAlt}
		for _, child := range t.children {
			n.alts = append(n.alts, c.compile(child, cont))
		}
		return n
	case kChar:
		t.set.freeze()
		return &node{op: opRep, set: t.set, min: 1, max: 1, next: cont}
	case kGroup:
		if t.capture == 0 {
			return c.compile(t.children[0], cont)
		}
		closeNode := &node{op: opCapClose, index: t.capture, next: cont}
		return &node{op: opCapOpen, index: t.capture, next: c.compile(t.children[0], closeNode)}
	case kLook:
		if t.behind {
			lo, hi := width(t.children[0])
			if lo != hi {
				c.err = fmt.Errorf("jsre: a lookbehind must have one width, in /%s/", c.re.source)
			}
			return &node{op: opBehind, keep: hasCapture(t), negate: t.negate, width: lo, body: c.compile(t.children[0], &node{op: opAcceptAt}), next: cont}
		}
		return &node{op: opLook, keep: hasCapture(t), negate: t.negate, body: c.compile(t.children[0], &node{op: opAccept}), next: cont}
	case kWordB:
		return &node{op: opWordB, next: cont}
	case kNotWordB:
		return &node{op: opNotWordB, next: cont}
	case kStart:
		return &node{op: opStart, next: cont}
	case kEnd:
		return &node{op: opEnd, next: cont}
	}
	panic("jsre: unknown node")
}

// guard sets each repeat's guard, visiting every node once.
func guard(n *node, seen map[*node]bool) {
	if n == nil || seen[n] {
		return
	}
	seen[n] = true
	if n.op == opRep || n.op == opPredRep {
		n.guard = startSet(n.next, 0)
	}
	guard(n.next, seen)
	guard(n.body, seen)
	for _, a := range n.alts {
		guard(a, seen)
	}
}

// startSet is the set of code units a match from n must start with, or
// nil when it may start with anything or take nothing.
func startSet(n *node, depth int) *charSet {
	if n == nil || depth > 16 {
		return nil
	}
	switch n.op {
	case opRep:
		if n.min >= 1 {
			return n.set
		}
	case opAlt:
		union := &charSet{}
		for _, a := range n.alts {
			s := startSet(a, depth+1)
			if s == nil {
				return nil
			}
			for i := range union.bits {
				union.bits[i] |= s.final[i]
			}
		}
		union.freeze()
		return union
	case opCapOpen, opCapClose, opLook, opBehind, opWordB, opNotWordB:
		// These take nothing; what follows them starts the match.
		return startSet(n.next, depth+1)
	}
	return nil
}

// width is the least and most code units t can take (-1: no limit).
func width(t *tree) (int, int) {
	lo, hi := 0, 0
	switch t.kind {
	case kChar:
		lo, hi = 1, 1
	case kSeq:
		for _, c := range t.children {
			l, h := width(c)
			lo += l
			if hi >= 0 {
				if h < 0 {
					hi = -1
				} else {
					hi += h
				}
			}
		}
	case kAlt:
		lo, hi = -1, 0
		for _, c := range t.children {
			l, h := width(c)
			if lo < 0 || l < lo {
				lo = l
			}
			if hi >= 0 && (h < 0 || h > hi) {
				hi = h
			}
		}
	case kGroup:
		lo, hi = width(t.children[0])
	default:
		// Assertions and lookarounds take nothing.
		return 0, 0
	}
	// Sequences and alternations carry no quantifier (theirs is always
	// once); a quantified term repeats its own width.
	lo *= t.min
	switch {
	case t.max < 0:
		if hi != 0 {
			hi = -1
		}
	case hi >= 0:
		hi *= t.max
	}
	return lo, hi
}

func hasCapture(t *tree) bool {
	if t.kind == kGroup && t.capture > 0 {
		return true
	}
	for _, c := range t.children {
		if hasCapture(c) {
			return true
		}
	}
	return false
}

// firstSet is the set of code units a match of t must start with, when a
// match cannot be empty.
func firstSet(t *tree) (*[1 << 16 / 64]uint64, bool) {
	var set [1 << 16 / 64]uint64
	if nullable := first(t, &set); nullable {
		return nil, false
	}
	return &set, true
}

// first adds to set what t can start with, and says whether t can match
// without taking anything (so what follows it can start the match too).
func first(t *tree, set *[1 << 16 / 64]uint64) bool {
	var nullable bool
	switch t.kind {
	case kChar:
		t.set.freeze()
		for i := range set {
			set[i] |= t.set.final[i]
		}
		nullable = false
	case kSeq:
		nullable = true
		for _, c := range t.children {
			if !first(c, set) {
				nullable = false
				break
			}
		}
	case kAlt:
		for _, c := range t.children {
			if first(c, set) {
				nullable = true
			}
		}
	case kGroup:
		nullable = first(t.children[0], set)
	default:
		// Assertions and lookarounds take nothing; what follows starts the match.
		return true
	}
	return nullable || t.min == 0
}

// matcher is the state of one attempt.
type matcher struct {
	in     []uint16
	caps   []int
	loops  []loopState
	end    int
	target int
}

type loopState struct {
	count int
	start int
}

func isWord(c uint16) bool {
	return c < 128 && (c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c >= '0' && c <= '9' || c == '_')
}

func (m *matcher) wordAt(i int) bool { return i >= 0 && i < len(m.in) && isWord(m.in[i]) }

// run reports whether the chain from n matches at pos, leaving captures
// and m.end set when it does.
func (m *matcher) run(n *node, pos int) bool {
	for {
		switch n.op {
		case opRep:
			k := 0
			limit := len(m.in) - pos
			if n.max >= 0 && n.max < limit {
				limit = n.max
			}
			for k < limit && n.set.has(m.in[pos+k]) {
				k++
			}
			if k < n.min {
				return false
			}
			if k == n.min {
				pos += k
				n = n.next
				continue
			}
			for i := k; i >= n.min; i-- {
				if g := n.guard; g != nil && (pos+i >= len(m.in) || !g.has(m.in[pos+i])) {
					continue
				}
				if m.run(n.next, pos+i) {
					return true
				}
			}
			return false
		case opPredRep:
			k := 0
			limit := len(m.in) - pos
			if n.max >= 0 && n.max < limit {
				limit = n.max
			}
			saved := m.end
			for k < limit && m.run(n.body, pos+k) && m.end == pos+k+1 {
				k++
			}
			m.end = saved
			if k < n.min {
				return false
			}
			for i := k; i >= n.min; i-- {
				if g := n.guard; g != nil && (pos+i >= len(m.in) || !g.has(m.in[pos+i])) {
					continue
				}
				if m.run(n.next, pos+i) {
					return true
				}
			}
			return false
		case opAlt:
			last := len(n.alts) - 1
			for _, a := range n.alts[:last] {
				if m.run(a, pos) {
					return true
				}
			}
			n = n.alts[last]
			continue
		case opCapOpen:
			i := 2 * n.index
			oldStart, oldEnd := m.caps[i], m.caps[i+1]
			m.caps[i] = pos
			if m.run(n.next, pos) {
				return true
			}
			m.caps[i], m.caps[i+1] = oldStart, oldEnd
			return false
		case opCapClose:
			i := 2*n.index + 1
			old := m.caps[i]
			m.caps[i] = pos
			if m.run(n.next, pos) {
				return true
			}
			m.caps[i] = old
			return false
		case opLoop:
			return m.iterate(n, 0, pos)
		case opLoopBack:
			l := n.loop
			st := m.loops[l.index]
			if pos == st.start {
				// A pass that took nothing ends the loop without matching, as
				// JavaScript's RepeatMatcher refuses an empty iteration.
				return false
			}
			if m.iterate(l, st.count, pos) {
				return true
			}
			m.loops[l.index] = st
			return false
		case opLook:
			var saved []int
			if n.keep {
				saved = append(saved, m.caps...)
			}
			end := m.end
			ok := m.run(n.body, pos)
			m.end = end
			if n.keep && (ok == n.negate || n.negate) {
				copy(m.caps, saved)
			}
			if ok == n.negate {
				return false
			}
			n = n.next
			continue
		case opBehind:
			ok := false
			if pos >= n.width {
				var saved []int
				if n.keep {
					saved = append(saved, m.caps...)
				}
				target, end := m.target, m.end
				m.target = pos
				ok = m.run(n.body, pos-n.width)
				m.target, m.end = target, end
				if n.keep && (!ok || n.negate) {
					copy(m.caps, saved)
				}
			}
			if ok == n.negate {
				return false
			}
			n = n.next
			continue
		case opWordB, opNotWordB:
			at := m.wordAt(pos-1) != m.wordAt(pos)
			if at != (n.op == opWordB) {
				return false
			}
			n = n.next
			continue
		case opStart:
			if pos != 0 {
				return false
			}
			n = n.next
			continue
		case opEnd:
			if pos != len(m.in) {
				return false
			}
			n = n.next
			continue
		case opAccept:
			m.end = pos
			return true
		case opAcceptAt:
			return pos == m.target
		}
		panic("jsre: unknown opcode")
	}
}

// iterate tries one more pass of a loop that has made count passes, then
// (greedy) leaving it.
func (m *matcher) iterate(l *node, count, pos int) bool {
	st := m.loops[l.index]
	if l.max < 0 || count < l.max {
		m.loops[l.index] = loopState{count: count + 1, start: pos}
		if m.run(l.body, pos) {
			return true
		}
		m.loops[l.index] = st
	}
	if count >= l.min {
		return m.run(l.next, pos)
	}
	return false
}

// Match is one match: the code units of the whole match and each group.
type Match struct {
	in   []uint16
	caps []int
}

// Group is group i's code units (0 is the whole match), and whether the
// group took part in the match.
func (m *Match) Group(i int) ([]uint16, bool) {
	if 2*i+1 >= len(m.caps) || m.caps[2*i] < 0 || m.caps[2*i+1] < 0 {
		return nil, false
	}
	return m.in[m.caps[2*i]:m.caps[2*i+1]], true
}

// Text is group i as text, "" when it did not take part.
func (m *Match) Text(i int) string {
	g, _ := m.Group(i)
	return js.FromUnits(g)
}

// exec finds the first match starting at or after from.
func (re *Regexp) exec(m *matcher, from int) bool {
	for s := from; s <= len(m.in); s++ {
		if re.first != nil {
			if s == len(m.in) {
				return false
			}
			c := m.in[s]
			if re.first[c>>6]&(1<<(c&63)) == 0 {
				continue
			}
		}
		for i := range m.caps {
			m.caps[i] = -1
		}
		m.end = -1
		if m.run(re.start, s) {
			m.caps[0], m.caps[1] = s, m.end
			return true
		}
	}
	return false
}

func (re *Regexp) newMatcher(in []uint16) *matcher {
	return &matcher{in: in, caps: make([]int, 2*(re.captures+1)), loops: make([]loopState, re.loops)}
}

// MatchUnits reports whether the pattern matches anywhere in the units.
func (re *Regexp) MatchUnits(in []uint16) bool {
	return re.exec(re.newMatcher(in), 0)
}

// MatchString reports whether the pattern matches anywhere in s.
func (re *Regexp) MatchString(s string) bool { return re.MatchUnits(js.Units(s)) }

// ReplaceUnits is String.prototype.replace with a function: each match
// (every one with the g flag, else the first) is replaced by what fn
// returns, and the search goes on after it (one unit further after an
// empty match).
func (re *Regexp) ReplaceUnits(in []uint16, fn func(*Match) []uint16) []uint16 {
	m := re.newMatcher(in)
	var out []uint16
	last, pos := 0, 0
	replaced := false
	for pos <= len(in) && re.exec(m, pos) {
		s, e := m.caps[0], m.caps[1]
		if !replaced {
			out = make([]uint16, 0, len(in))
			replaced = true
		}
		out = append(out, in[last:s]...)
		out = append(out, fn(&Match{in: in, caps: m.caps})...)
		last = e
		if e == s {
			pos = e + 1
		} else {
			pos = e
		}
		if !re.global {
			break
		}
	}
	if !replaced {
		return in
	}
	return append(out, in[last:]...)
}

// ReplaceTemplateUnits is replace with a replacement string: $1 to $99 are
// the groups ("" for one that did not take part), $& the match, $$ a "$".
func (re *Regexp) ReplaceTemplateUnits(in []uint16, template string) []uint16 {
	return re.ReplaceUnits(in, func(m *Match) []uint16 { return js.Units(expand(template, m)) })
}

// ReplaceString is ReplaceTemplateUnits on text.
func (re *Regexp) ReplaceString(s, template string) string {
	return js.FromUnits(re.ReplaceTemplateUnits(js.Units(s), template))
}

func expand(template string, m *Match) string {
	var b strings.Builder
	for i := 0; i < len(template); i++ {
		c := template[i]
		if c != '$' || i+1 >= len(template) {
			b.WriteByte(c)
			continue
		}
		n := template[i+1]
		switch {
		case n == '$':
			b.WriteByte('$')
			i++
		case n == '&':
			b.WriteString(m.Text(0))
			i++
		case n >= '0' && n <= '9':
			group := int(n - '0')
			used := 1
			if i+2 < len(template) && template[i+2] >= '0' && template[i+2] <= '9' {
				if two := group*10 + int(template[i+2]-'0'); two >= 1 && 2*two+1 < len(m.caps) {
					group, used = two, 2
				}
			}
			if group < 1 || 2*group+1 >= len(m.caps) {
				b.WriteByte(c)
				continue
			}
			b.WriteString(m.Text(group))
			i += used
		default:
			b.WriteByte(c)
		}
	}
	return b.String()
}
