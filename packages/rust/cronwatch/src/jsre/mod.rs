//! A small backtracking regular expression engine with JavaScript's
//! semantics, for the SDK's secret redaction patterns.
//!
//! The `regex` crate cannot run them: it has no lookahead or lookbehind, and
//! it matches over code points, where JavaScript (without the `u` flag)
//! matches over UTF-16 code units, so an emoji counts as two characters to
//! a bounded quantifier and to a negated class. This engine matches over
//! code units, as V8 does, so the SDK's patterns can be written here
//! verbatim and match exactly what they match there. It is the Go port's
//! `internal/jsre`, carried over.
//!
//! It reads the subset of JavaScript's syntax those patterns use, in
//! non-unicode mode: literals and escapes (`\d \s \w \b` and their
//! negations, `\n \t \r \f \v \0 \xHH \uHHHH`, and any escaped
//! punctuation), character classes with ranges and negation, capturing and
//! non-capturing groups, lookahead, fixed-length lookbehind, alternation,
//! greedy quantifiers (`? * + {n} {n,} {n,m}`), and the flags `g` and `i`.
//! The `i` flag folds ASCII letters only. JavaScript's `/i` without `u`
//! canonicalizes with `toUpperCase` but never maps a character outside
//! ASCII onto one inside it (so the long s, U+017F, never matches "s" and
//! the Kelvin sign never matches "k"), which for patterns whose letters are
//! all ASCII is exactly ASCII folding. What it does not implement it
//! refuses rather than read as something else: lazy quantifiers, named
//! groups, backreferences, `\c`, `\p{...}` and `\u{...}`.

mod parse;

use parse::{Bits, CharSet, Kind, Tree};

#[cfg(test)]
use crate::js;

/// No node: the end of a chain that never continues.
const NONE: usize = usize::MAX;

/// The longest pattern `Regexp::new` reads, in characters.
const MAX_SOURCE: usize = 4096;

/// How deep one match may recurse. A loop whose passes are not one code
/// unit wide (`(?:ab)*`) recurses three frames a pass, so a stored pattern
/// over a long output could otherwise overflow a thread's stack and abort
/// the process; past this (some 170 such passes) the match gives up
/// (`try_is_match` answers `None`). It fits a tokio worker's 2 MiB stack in
/// a debug build with room to spare. V8 keeps its own backtracking stack and
/// throws past its limit; the SDK's redaction patterns never come near it.
const MAX_DEPTH: usize = 512;

/// How much work `try_is_match` does before it gives up: each attempt at a
/// node (a call to `run`) is a step, and so is each code unit a repeat
/// scans. A stored pattern of stars back to back (`\n*\n*\n*\n*\n*x`) or a
/// dot star (`.*x`) backtracks polynomially over an output it does not
/// match, as V8 does; past this, a tenth of a second in a release build,
/// the match gives up, where a pattern that does not backtrack so takes a
/// small part of it over the 32 KB an expect rule sees. Replacement
/// (redaction) runs only the SDK's own bounded patterns and has no budget.
const MAX_STEPS: u64 = 50_000_000;

/// A compiled pattern. It is read-only once compiled, so one may be shared
/// by every thread; each match keeps its own state.
#[derive(Debug)]
pub(crate) struct Regexp {
    source: String,
    flags: String,
    global: bool,
    nodes: Vec<Node>,
    sets: Vec<CharSet>,
    start: usize,
    captures: usize,
    loops: usize,
    /// The code units a match can start with, or `None` when a match can
    /// start with anything (or be empty), so the search skips positions no
    /// match could start at without running the pattern.
    first: Option<Box<Bits>>,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Op {
    /// min to max code units from set, greedy.
    Rep,
    /// min to max repeats of a one-unit body, greedy.
    PredRep,
    /// Try each of alts in turn.
    Alt,
    /// A capture starts.
    CapOpen,
    /// A capture ends.
    CapClose,
    /// A quantified group of any width.
    Loop,
    /// The end of one pass through a loop's body.
    LoopBack,
    /// Lookahead.
    Look,
    /// Lookbehind of a fixed width.
    Behind,
    /// `\b`
    WordB,
    /// `\B`
    NotWordB,
    /// `^`
    Start,
    /// `$`
    End,
    /// The whole pattern (or a lookahead's body) matched.
    Accept,
    /// A lookbehind's body matched, if it ends where the lookbehind stands.
    AcceptAt,
}

/// One step of the compiled pattern. Each node knows the step after it
/// (`next`), so the matcher runs a pattern as a chain and backtracks by
/// returning false up the call stack. Nodes refer to each other by index.
#[derive(Clone, Debug)]
struct Node {
    op: Op,
    set: usize,
    min: usize,
    max: Option<usize>,
    next: usize,
    alts: Vec<usize>,
    body: usize,
    /// Capture number or loop number.
    index: usize,
    negate: bool,
    /// A lookbehind's width.
    width: usize,
    lp: usize,
    /// On a repeat, what the step after it must start with (`None` when that
    /// is not known), so walking a greedy run back skips the positions where
    /// the rest of the pattern cannot even begin.
    guard: Option<usize>,
    /// On a lookaround, whether its body has captures to undo.
    keep: bool,
}

impl Node {
    fn new(op: Op) -> Node {
        Node {
            op,
            set: NONE,
            min: 1,
            max: Some(1),
            next: NONE,
            alts: Vec::new(),
            body: NONE,
            index: 0,
            negate: false,
            width: 0,
            lp: NONE,
            guard: None,
            keep: false,
        }
    }
}

struct Compiler {
    nodes: Vec<Node>,
    sets: Vec<CharSet>,
    loops: usize,
    err: Option<String>,
    source: String,
}

impl Compiler {
    fn push(&mut self, n: Node) -> usize {
        self.nodes.push(n);
        self.nodes.len() - 1
    }

    fn set_of(&mut self, t: &mut Tree) -> usize {
        let set = t.set.as_mut().expect("a character node has a set");
        set.freeze();
        self.sets.push(set.clone());
        self.sets.len() - 1
    }

    fn accept(&mut self) -> usize {
        self.push(Node::new(Op::Accept))
    }

    /// Builds the chain for `t`, which continues with `cont`.
    fn compile(&mut self, t: &mut Tree, cont: usize) -> usize {
        if t.once() {
            return self.once(t, cont);
        }
        if t.kind == Kind::Char {
            let set = self.set_of(t);
            return self.push(Node { set, min: t.min, max: t.max, next: cont, ..Node::new(Op::Rep) });
        }
        let (lo, hi) = width(&t.children[0]);
        if lo == 1 && hi == Some(1) && !has_capture(t) && t.kind == Kind::Group && t.capture == 0 {
            // Every pass takes exactly one code unit (a class, or an
            // alternation of single characters with lookarounds), so the
            // passes are counted greedily and walked back, rather than taking
            // one call per pass: a {0,16384} run stays shallow.
            let accept = self.accept();
            let body = self.compile(&mut t.children[0], accept);
            return self.push(Node { body, min: t.min, max: t.max, next: cont, ..Node::new(Op::PredRep) });
        }
        let lp = self.push(Node { min: t.min, max: t.max, next: cont, index: self.loops, ..Node::new(Op::Loop) });
        self.loops += 1;
        let back = self.push(Node { lp, ..Node::new(Op::LoopBack) });
        let (min, max) = (t.min, t.max);
        t.min = 1;
        t.max = Some(1);
        let body = self.once(t, back);
        t.min = min;
        t.max = max;
        self.nodes[lp].body = body;
        lp
    }

    /// Builds the chain for one pass of `t`.
    fn once(&mut self, t: &mut Tree, cont: usize) -> usize {
        match t.kind {
            Kind::Seq => {
                let mut cont = cont;
                for child in t.children.iter_mut().rev() {
                    cont = self.compile(child, cont);
                }
                cont
            }
            Kind::Alt => {
                let alts = t.children.iter_mut().map(|child| self.compile(child, cont)).collect();
                self.push(Node { alts, ..Node::new(Op::Alt) })
            }
            Kind::Char => {
                let set = self.set_of(t);
                self.push(Node { set, next: cont, ..Node::new(Op::Rep) })
            }
            Kind::Group => {
                if t.capture == 0 {
                    return self.compile(&mut t.children[0], cont);
                }
                let close = self.push(Node { index: t.capture, next: cont, ..Node::new(Op::CapClose) });
                let next = self.compile(&mut t.children[0], close);
                self.push(Node { index: t.capture, next, ..Node::new(Op::CapOpen) })
            }
            Kind::Look => {
                let keep = has_capture(t);
                if t.behind {
                    let (lo, hi) = width(&t.children[0]);
                    if hi != Some(lo) {
                        self.err = Some(format!("jsre: a lookbehind must have one width, in /{}/", self.source));
                    }
                    let at = self.push(Node::new(Op::AcceptAt));
                    let body = self.compile(&mut t.children[0], at);
                    return self.push(Node {
                        keep,
                        negate: t.negate,
                        width: lo,
                        body,
                        next: cont,
                        ..Node::new(Op::Behind)
                    });
                }
                let accept = self.accept();
                let body = self.compile(&mut t.children[0], accept);
                self.push(Node { keep, negate: t.negate, body, next: cont, ..Node::new(Op::Look) })
            }
            Kind::WordB => self.push(Node { next: cont, ..Node::new(Op::WordB) }),
            Kind::NotWordB => self.push(Node { next: cont, ..Node::new(Op::NotWordB) }),
            Kind::Start => self.push(Node { next: cont, ..Node::new(Op::Start) }),
            Kind::End => self.push(Node { next: cont, ..Node::new(Op::End) }),
        }
    }

    /// Sets each repeat's guard, visiting every node once.
    fn guard(&mut self, n: usize, seen: &mut Vec<bool>) {
        if n == NONE || seen[n] {
            return;
        }
        seen[n] = true;
        if matches!(self.nodes[n].op, Op::Rep | Op::PredRep) {
            let next = self.nodes[n].next;
            self.nodes[n].guard = self.start_set(next, 0);
        }
        let (next, body, alts) = (self.nodes[n].next, self.nodes[n].body, self.nodes[n].alts.clone());
        self.guard(next, seen);
        self.guard(body, seen);
        for a in alts {
            self.guard(a, seen);
        }
    }

    /// The set of code units a match from `n` must start with, or `None`
    /// when it may start with anything or take nothing.
    fn start_set(&mut self, n: usize, depth: usize) -> Option<usize> {
        if n == NONE || depth > 16 {
            return None;
        }
        let node = &self.nodes[n];
        match node.op {
            Op::Rep if node.min >= 1 => Some(node.set),
            Op::Alt => {
                let mut union: Box<Bits> = Box::new([0; 1 << 16 >> 6]);
                for a in node.alts.clone() {
                    let s = self.start_set(a, depth + 1)?;
                    let fin = self.sets[s].fin.as_ref().expect("a frozen set");
                    for (u, f) in union.iter_mut().zip(fin.iter()) {
                        *u |= f;
                    }
                }
                self.sets.push(CharSet::frozen(union));
                Some(self.sets.len() - 1)
            }
            // These take nothing; what follows them starts the match.
            Op::CapOpen | Op::CapClose | Op::Look | Op::Behind | Op::WordB | Op::NotWordB => {
                let next = node.next;
                self.start_set(next, depth + 1)
            }
            _ => None,
        }
    }
}

/// The least and most code units `t` can take (`None`: no limit).
fn width(t: &Tree) -> (usize, Option<usize>) {
    let (lo, hi) = match t.kind {
        Kind::Char => (1, Some(1)),
        Kind::Seq => {
            let (mut lo, mut hi) = (0, Some(0));
            for c in &t.children {
                let (l, h) = width(c);
                lo += l;
                hi = match (hi, h) {
                    (Some(a), Some(b)) => Some(a + b),
                    _ => None,
                };
            }
            (lo, hi)
        }
        Kind::Alt => {
            let mut lo = None;
            let mut hi = Some(0);
            for c in &t.children {
                let (l, h) = width(c);
                if lo.is_none_or(|lo| l < lo) {
                    lo = Some(l);
                }
                hi = match (hi, h) {
                    (Some(a), Some(b)) => Some(a.max(b)),
                    _ => None,
                };
            }
            (lo.unwrap_or(0), hi)
        }
        Kind::Group => width(&t.children[0]),
        // Assertions and lookarounds take nothing.
        _ => return (0, Some(0)),
    };
    // Sequences and alternations carry no quantifier (theirs is always
    // once); a quantified term repeats its own width.
    let lo = lo * t.min;
    let hi = match (t.max, hi) {
        (None, Some(0)) => Some(0),
        (None, _) => None,
        (Some(m), Some(h)) => Some(h * m),
        (Some(_), None) => None,
    };
    (lo, hi)
}

fn has_capture(t: &Tree) -> bool {
    (t.kind == Kind::Group && t.capture > 0) || t.children.iter().any(has_capture)
}

/// The set of code units a match of `t` must start with, when a match
/// cannot be empty.
fn first_set(t: &mut Tree) -> Option<Box<Bits>> {
    let mut set: Box<Bits> = Box::new([0; 1 << 16 >> 6]);
    if first(t, &mut set) { None } else { Some(set) }
}

/// Adds to `set` what `t` can start with, and says whether `t` can match
/// without taking anything (so what follows it can start the match too).
fn first(t: &mut Tree, set: &mut Bits) -> bool {
    let nullable = match t.kind {
        Kind::Char => {
            let s = t.set.as_mut().expect("a character node has a set");
            s.freeze();
            for (a, b) in set.iter_mut().zip(s.fin.as_ref().expect("frozen").iter()) {
                *a |= b;
            }
            false
        }
        Kind::Seq => {
            let mut nullable = true;
            for c in t.children.iter_mut() {
                if !first(c, set) {
                    nullable = false;
                    break;
                }
            }
            nullable
        }
        Kind::Alt => {
            let mut nullable = false;
            for c in t.children.iter_mut() {
                if first(c, set) {
                    nullable = true;
                }
            }
            nullable
        }
        Kind::Group => first(&mut t.children[0], set),
        // Assertions and lookarounds take nothing; what follows starts the match.
        _ => return true,
    };
    nullable || t.min == 0
}

impl Regexp {
    /// Reads a JavaScript pattern's source (what goes between the slashes)
    /// and its flags (`g` and `i`).
    pub(crate) fn new(source: &str, flags: &str) -> Result<Regexp, String> {
        // Each character of a pattern is a set of 8 KiB until it is
        // frozen, so a pattern's length bounds what compiling it takes.
        if source.chars().count() > MAX_SOURCE {
            return Err(format!("jsre: a pattern of more than {MAX_SOURCE} characters is not supported"));
        }
        let mut fold = false;
        let mut global = false;
        for f in flags.chars() {
            match f {
                'i' => fold = true,
                'g' => global = true,
                _ => return Err(format!("jsre: flag {f:?} is not supported")),
            }
        }
        let (mut t, captures) = parse::parse(source, fold)?;
        let mut c = Compiler { nodes: Vec::new(), sets: Vec::new(), loops: 0, err: None, source: source.to_string() };
        let accept = c.accept();
        let start = c.compile(&mut t, accept);
        let mut seen = vec![false; c.nodes.len()];
        c.guard(start, &mut seen);
        if let Some(err) = c.err {
            return Err(err);
        }
        let first = first_set(&mut t);
        Ok(Regexp {
            source: source.to_string(),
            flags: flags.to_string(),
            global,
            nodes: c.nodes,
            sets: c.sets,
            start,
            captures,
            loops: c.loops,
            first,
        })
    }

    /// `new` for patterns known to be good.
    pub(crate) fn must(source: &str, flags: &str) -> Regexp {
        match Regexp::new(source, flags) {
            Ok(re) => re,
            Err(err) => panic!("{err}"),
        }
    }

    /// Finds the first match starting at or after `from`.
    fn exec(&self, m: &mut Matcher<'_>, from: usize) -> bool {
        for s in from..=m.input.len() {
            if let Some(first) = &self.first {
                if s == m.input.len() {
                    return false;
                }
                let c = m.input[s];
                if first[(c >> 6) as usize] & (1 << (c & 63)) == 0 {
                    continue;
                }
            }
            m.caps.fill(-1);
            m.end = -1;
            if m.run(self.start, s) {
                m.caps[0] = s as isize;
                m.caps[1] = m.end;
                return true;
            }
            if m.gave_up {
                return false;
            }
        }
        false
    }

    fn matcher<'a>(&'a self, input: &'a [u16], budget: u64) -> Matcher<'a> {
        Matcher {
            re: self,
            input,
            caps: vec![-1; 2 * (self.captures + 1)],
            loops: vec![LoopState::default(); self.loops],
            end: -1,
            target: 0,
            depth: 0,
            steps: budget,
            gave_up: false,
        }
    }

    /// Whether the pattern matches anywhere in `s` (a stored expect pattern
    /// read back by `bridge::options_of`), or `None` when the match gave up
    /// (see `MAX_DEPTH` and `MAX_STEPS`).
    pub(crate) fn try_is_match(&self, s: &str) -> Option<bool> {
        let units = crate::js::units(s);
        let mut m = self.matcher(&units, MAX_STEPS);
        let found = self.exec(&mut m, 0);
        (!m.gave_up).then_some(found)
    }

    /// `String.prototype.replace` with a function: each match (every one
    /// with the `g` flag, else the first) is replaced by what `f` returns,
    /// and the search goes on after it (one unit further after an empty
    /// match).
    pub(crate) fn replace_units(&self, input: &[u16], f: impl FnMut(&Match<'_>) -> Vec<u16>) -> Vec<u16> {
        self.replace_within(input, u64::MAX, f).0
    }

    /// `replace_units` within `MAX_STEPS`, or `None` when it gave up: an
    /// arbitrary pattern's replacement, for the fuzz target.
    #[cfg(fuzzing)]
    pub(crate) fn try_replace_units(&self, input: &[u16], f: impl FnMut(&Match<'_>) -> Vec<u16>) -> Option<Vec<u16>> {
        let (out, gave_up) = self.replace_within(input, MAX_STEPS, f);
        (!gave_up).then_some(out)
    }

    /// The replacement, and whether a match gave up part way (what follows
    /// it is then left as it was).
    fn replace_within(
        &self,
        input: &[u16],
        budget: u64,
        mut f: impl FnMut(&Match<'_>) -> Vec<u16>,
    ) -> (Vec<u16>, bool) {
        let mut m = self.matcher(input, budget);
        let mut out: Vec<u16> = Vec::new();
        let (mut last, mut pos) = (0, 0);
        let mut replaced = false;
        while pos <= input.len() && self.exec(&mut m, pos) {
            let (s, e) = (m.caps[0] as usize, m.caps[1] as usize);
            if !replaced {
                out.reserve(input.len());
                replaced = true;
            }
            out.extend_from_slice(&input[last..s]);
            out.extend(f(&Match { input, caps: &m.caps }));
            last = e;
            pos = if e == s { e + 1 } else { e };
            if !self.global {
                break;
            }
        }
        if !replaced {
            return (input.to_vec(), m.gave_up);
        }
        out.extend_from_slice(&input[last..]);
        (out, m.gave_up)
    }

    /// `replace` with a replacement string: `$1` to `$99` are the groups
    /// ("" for one that did not take part), `$&` the match, `$$` a "$".
    #[cfg(test)]
    pub(crate) fn replace_template_units(&self, input: &[u16], template: &str) -> Vec<u16> {
        self.replace_units(input, |m| js::units(&expand(template, m)))
    }

    /// `replace_template_units` on text.
    #[cfg(test)]
    pub(crate) fn replace(&self, s: &str, template: &str) -> String {
        js::from_units(&self.replace_template_units(&js::units(s), template))
    }
}

impl std::fmt::Display for Regexp {
    /// The pattern as JavaScript writes it: `/source/flags`.
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "/{}/{}", self.source, self.flags)
    }
}

#[cfg(test)]
fn expand(template: &str, m: &Match<'_>) -> String {
    let t = template.as_bytes();
    let mut b: Vec<u8> = Vec::with_capacity(t.len());
    let mut i = 0;
    while i < t.len() {
        let c = t[i];
        if c != b'$' || i + 1 >= t.len() {
            b.push(c);
            i += 1;
            continue;
        }
        let n = t[i + 1];
        match n {
            b'$' => {
                b.push(b'$');
                i += 2;
            }
            b'&' => {
                b.extend_from_slice(m.text(0).as_bytes());
                i += 2;
            }
            b'0'..=b'9' => {
                let mut group = (n - b'0') as usize;
                let mut used = 1;
                if i + 2 < t.len() && t[i + 2].is_ascii_digit() {
                    let two = group * 10 + (t[i + 2] - b'0') as usize;
                    if two >= 1 && 2 * two + 1 < m.caps.len() {
                        group = two;
                        used = 2;
                    }
                }
                if group < 1 || 2 * group + 1 >= m.caps.len() {
                    b.push(c);
                    i += 1;
                    continue;
                }
                b.extend_from_slice(m.text(group).as_bytes());
                i += 1 + used;
            }
            _ => {
                b.push(c);
                i += 1;
            }
        }
    }
    String::from_utf8(b).unwrap_or_default()
}

/// The state of one attempt.
struct Matcher<'a> {
    re: &'a Regexp,
    input: &'a [u16],
    caps: Vec<isize>,
    loops: Vec<LoopState>,
    end: isize,
    target: usize,
    /// How deep `run` is, the steps it has left (see `MAX_STEPS`), and
    /// whether it went past either.
    depth: usize,
    steps: u64,
    gave_up: bool,
}

#[derive(Clone, Copy, Debug, Default)]
struct LoopState {
    count: usize,
    start: usize,
}

fn is_word(c: u16) -> bool {
    c < 128 && (c as u8).is_ascii_alphanumeric() || c == b'_' as u16
}

impl Matcher<'_> {
    fn word_at(&self, i: isize) -> bool {
        i >= 0 && (i as usize) < self.input.len() && is_word(self.input[i as usize])
    }

    fn guarded(&self, n: &Node, at: usize) -> bool {
        match n.guard {
            Some(g) => at < self.input.len() && self.re.sets[g].has(self.input[at]),
            None => true,
        }
    }

    /// Whether the chain from `n` matches at `pos`, leaving captures and
    /// `end` set when it does. Past `MAX_DEPTH`, or out of steps, the match
    /// gives up: this and every call after it answers false, and `gave_up`
    /// is set.
    fn run(&mut self, n: usize, pos: usize) -> bool {
        if self.gave_up {
            return false;
        }
        if self.depth >= MAX_DEPTH || self.steps == 0 {
            self.gave_up = true;
            return false;
        }
        self.depth += 1;
        self.steps -= 1;
        let matched = self.run_chain(n, pos);
        self.depth -= 1;
        matched
    }

    fn run_chain(&mut self, mut n: usize, mut pos: usize) -> bool {
        let re = self.re;
        loop {
            let node = &re.nodes[n];
            match node.op {
                Op::Rep => {
                    let set = &re.sets[node.set];
                    let mut limit = self.input.len() - pos;
                    if let Some(max) = node.max {
                        limit = limit.min(max);
                    }
                    let mut k = 0;
                    while k < limit && set.has(self.input[pos + k]) {
                        k += 1;
                    }
                    self.steps = self.steps.saturating_sub(k as u64);
                    if k < node.min {
                        return false;
                    }
                    if k == node.min {
                        pos += k;
                        n = node.next;
                        continue;
                    }
                    let mut i = k;
                    loop {
                        if self.guarded(node, pos + i) && self.run(node.next, pos + i) {
                            return true;
                        }
                        if i == node.min {
                            return false;
                        }
                        i -= 1;
                    }
                }
                Op::PredRep => {
                    let mut limit = self.input.len() - pos;
                    if let Some(max) = node.max {
                        limit = limit.min(max);
                    }
                    let saved = self.end;
                    let mut k = 0;
                    while k < limit && self.run(node.body, pos + k) && self.end == (pos + k + 1) as isize {
                        k += 1;
                    }
                    self.end = saved;
                    if k < node.min {
                        return false;
                    }
                    let mut i = k;
                    loop {
                        if self.guarded(node, pos + i) && self.run(node.next, pos + i) {
                            return true;
                        }
                        if i == node.min {
                            return false;
                        }
                        i -= 1;
                    }
                }
                Op::Alt => {
                    let (last, rest) = node.alts.split_last().expect("an alternation has alternatives");
                    for &a in rest {
                        if self.run(a, pos) {
                            return true;
                        }
                    }
                    n = *last;
                }
                Op::CapOpen => {
                    let i = 2 * node.index;
                    let (old_start, old_end) = (self.caps[i], self.caps[i + 1]);
                    self.caps[i] = pos as isize;
                    if self.run(node.next, pos) {
                        return true;
                    }
                    self.caps[i] = old_start;
                    self.caps[i + 1] = old_end;
                    return false;
                }
                Op::CapClose => {
                    let i = 2 * node.index + 1;
                    let old = self.caps[i];
                    self.caps[i] = pos as isize;
                    if self.run(node.next, pos) {
                        return true;
                    }
                    self.caps[i] = old;
                    return false;
                }
                Op::Loop => return self.iterate(n, 0, pos),
                Op::LoopBack => {
                    let lp = node.lp;
                    let index = re.nodes[lp].index;
                    let st = self.loops[index];
                    if pos == st.start {
                        // A pass that took nothing ends the loop without
                        // matching, as JavaScript's RepeatMatcher refuses an
                        // empty iteration.
                        return false;
                    }
                    if self.iterate(lp, st.count, pos) {
                        return true;
                    }
                    self.loops[index] = st;
                    return false;
                }
                Op::Look => {
                    let saved = if node.keep { Some(self.caps.clone()) } else { None };
                    let end = self.end;
                    let ok = self.run(node.body, pos);
                    self.end = end;
                    if let Some(saved) = saved.filter(|_| ok == node.negate || node.negate) {
                        self.caps.copy_from_slice(&saved);
                    }
                    if ok == node.negate {
                        return false;
                    }
                    n = node.next;
                }
                Op::Behind => {
                    let mut ok = false;
                    if pos >= node.width {
                        let saved = if node.keep { Some(self.caps.clone()) } else { None };
                        let (target, end) = (self.target, self.end);
                        self.target = pos;
                        ok = self.run(node.body, pos - node.width);
                        self.target = target;
                        self.end = end;
                        if let Some(saved) = saved.filter(|_| !ok || node.negate) {
                            self.caps.copy_from_slice(&saved);
                        }
                    }
                    if ok == node.negate {
                        return false;
                    }
                    n = node.next;
                }
                Op::WordB | Op::NotWordB => {
                    let at = self.word_at(pos as isize - 1) != self.word_at(pos as isize);
                    if at != (node.op == Op::WordB) {
                        return false;
                    }
                    n = node.next;
                }
                Op::Start => {
                    if pos != 0 {
                        return false;
                    }
                    n = node.next;
                }
                Op::End => {
                    if pos != self.input.len() {
                        return false;
                    }
                    n = node.next;
                }
                Op::Accept => {
                    self.end = pos as isize;
                    return true;
                }
                Op::AcceptAt => return pos == self.target,
            }
        }
    }

    /// Tries one more pass of a loop that has made `count` passes, then
    /// (greedy) leaving it.
    fn iterate(&mut self, lp: usize, count: usize, pos: usize) -> bool {
        let re = self.re;
        let node = &re.nodes[lp];
        let st = self.loops[node.index];
        if node.max.is_none_or(|max| count < max) {
            self.loops[node.index] = LoopState { count: count + 1, start: pos };
            if self.run(node.body, pos) {
                return true;
            }
            self.loops[node.index] = st;
        }
        if count >= node.min {
            return self.run(node.next, pos);
        }
        false
    }
}

/// One match: the code units of the whole match and each group.
pub(crate) struct Match<'a> {
    input: &'a [u16],
    caps: &'a [isize],
}

impl Match<'_> {
    /// Group `i`'s code units (0 is the whole match), or `None` when the
    /// group did not take part in the match.
    pub(crate) fn group(&self, i: usize) -> Option<&[u16]> {
        if 2 * i + 1 >= self.caps.len() || self.caps[2 * i] < 0 || self.caps[2 * i + 1] < 0 {
            return None;
        }
        Some(&self.input[self.caps[2 * i] as usize..self.caps[2 * i + 1] as usize])
    }

    /// Group `i` as text, "" when it did not take part.
    #[cfg(test)]
    pub(crate) fn text(&self, i: usize) -> String {
        js::from_units(self.group(i).unwrap_or(&[]))
    }
}

#[cfg(test)]
mod tests;
