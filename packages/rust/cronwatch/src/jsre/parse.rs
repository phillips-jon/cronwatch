//! The parser: a pattern's source, in JavaScript's non-unicode syntax, as a
//! tree of the kinds below.

/// Kinds of syntax tree node.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(super) enum Kind {
    /// Children: the alternatives.
    Alt,
    /// Children: the terms in order.
    Seq,
    /// One code unit from the set.
    Char,
    /// `children[0]` inside; a capture above 0 captures.
    Group,
    /// Lookahead or lookbehind around `children[0]`.
    Look,
    /// `\b`
    WordB,
    /// `\B`
    NotWordB,
    /// `^`
    Start,
    /// `$`
    End,
}

/// A parsed pattern.
#[derive(Clone, Debug)]
pub(super) struct Tree {
    pub(super) kind: Kind,
    pub(super) children: Vec<Tree>,
    pub(super) set: Option<CharSet>,
    pub(super) capture: usize,
    pub(super) behind: bool,
    pub(super) negate: bool,
    /// The quantifier; a `max` of `None` is unbounded.
    pub(super) min: usize,
    pub(super) max: Option<usize>,
}

impl Tree {
    fn new(kind: Kind) -> Tree {
        Tree { kind, children: Vec::new(), set: None, capture: 0, behind: false, negate: false, min: 1, max: Some(1) }
    }

    fn char(set: CharSet) -> Tree {
        Tree { set: Some(set), ..Tree::new(Kind::Char) }
    }

    pub(super) fn once(&self) -> bool {
        self.min == 1 && self.max == Some(1)
    }
}

struct Parser {
    src: Vec<char>,
    i: usize,
    fold: bool,
    captures: usize,
    /// How many groups the parser is inside.
    depth: usize,
}

/// How deep groups may nest.
const MAX_NESTING: usize = 100;

/// Reads a pattern's source into a tree and its number of captures.
pub(super) fn parse(source: &str, fold: bool) -> Result<(Tree, usize), String> {
    let mut p = Parser { src: source.chars().collect(), i: 0, fold, captures: 0, depth: 0 };
    let t = p.disjunction()?;
    if p.i < p.src.len() {
        return Err(p.fail("unmatched ')'"));
    }
    Ok((t, p.captures))
}

impl Parser {
    fn fail(&self, what: &str) -> String {
        format!("jsre: {what} at {} in /{}/", self.i, self.src.iter().collect::<String>())
    }

    fn more(&self) -> bool {
        self.i < self.src.len()
    }

    fn peek(&self) -> char {
        self.src[self.i]
    }

    fn has(&self, prefix: &str) -> bool {
        self.src[self.i..].starts_with(&prefix.chars().collect::<Vec<char>>())
    }

    fn disjunction(&mut self) -> Result<Tree, String> {
        let mut alt = Tree::new(Kind::Alt);
        loop {
            let seq = self.alternative()?;
            alt.children.push(seq);
            if self.more() && self.peek() == '|' {
                self.i += 1;
                continue;
            }
            break;
        }
        if alt.children.len() == 1 {
            return Ok(alt.children.pop().expect("one alternative"));
        }
        Ok(alt)
    }

    fn alternative(&mut self) -> Result<Tree, String> {
        let mut seq = Tree::new(Kind::Seq);
        while self.more() && self.peek() != '|' && self.peek() != ')' {
            let t = self.term()?;
            seq.children.push(t);
        }
        Ok(seq)
    }

    fn term(&mut self) -> Result<Tree, String> {
        let c = self.peek();
        let t = match c {
            '^' => {
                self.i += 1;
                return Ok(Tree::new(Kind::Start));
            }
            '$' => {
                self.i += 1;
                return Ok(Tree::new(Kind::End));
            }
            '(' => {
                self.i += 1;
                let mut g = Tree::new(Kind::Group);
                if self.has("?:") {
                    self.i += 2;
                } else if self.has("?=") || self.has("?!") {
                    g.kind = Kind::Look;
                    g.negate = self.src[self.i + 1] == '!';
                    self.i += 2;
                } else if self.has("?<=") || self.has("?<!") {
                    g.kind = Kind::Look;
                    g.behind = true;
                    g.negate = self.src[self.i + 2] == '!';
                    self.i += 3;
                } else if self.has("?") {
                    return Err(self.fail("unsupported group"));
                } else {
                    self.captures += 1;
                    g.capture = self.captures;
                }
                // The parser and the compiler recurse into groups, so a
                // pattern of thousands of '(' would overflow the stack.
                self.depth += 1;
                if self.depth > MAX_NESTING {
                    return Err(self.fail("groups nested too deeply"));
                }
                let inner = self.disjunction()?;
                self.depth -= 1;
                if !self.more() || self.peek() != ')' {
                    return Err(self.fail("missing ')'"));
                }
                self.i += 1;
                g.children = vec![inner];
                if g.kind == Kind::Look && g.behind {
                    // A lookbehind cannot be quantified.
                    return Ok(g);
                }
                g
            }
            '[' => {
                self.i += 1;
                let set = self.class()?;
                Tree::char(set)
            }
            '.' => {
                self.i += 1;
                let mut set = CharSet::new();
                set.add_range(0, 0xffff);
                set.remove('\n' as u32);
                set.remove('\r' as u32);
                set.remove(0x2028);
                set.remove(0x2029);
                Tree::char(set)
            }
            '\\' => {
                self.i += 1;
                if !self.more() {
                    return Err(self.fail("\\ at end of pattern"));
                }
                match self.peek() {
                    'b' => {
                        self.i += 1;
                        return Ok(Tree::new(Kind::WordB));
                    }
                    'B' => {
                        self.i += 1;
                        return Ok(Tree::new(Kind::NotWordB));
                    }
                    _ => {}
                }
                let mut set = CharSet::new();
                self.escape(&mut set)?;
                Tree::char(self.folded(set))
            }
            '*' | '+' | '?' => return Err(self.fail("nothing to repeat")),
            ')' => return Err(self.fail("unmatched ')'")),
            _ => {
                self.i += 1;
                let mut set = CharSet::new();
                set.add(c as u32);
                Tree::char(self.folded(set))
            }
        };
        self.quantifier(t)
    }

    /// Reads `{n}`, `{n,}` or `{n,m}` at the parser's position: the bounds and
    /// the index after the `}`, or `None` when the `{` is a literal (Annex B).
    fn brace(&self) -> Option<(usize, Option<usize>, usize)> {
        let src = &self.src;
        let mut j = self.i + 1;
        let num = |j: &mut usize| -> Option<usize> {
            let start = *j;
            while *j < src.len() && src[*j].is_ascii_digit() {
                *j += 1;
            }
            if *j == start {
                return None;
            }
            src[start..*j].iter().collect::<String>().parse().ok()
        };
        let n = num(&mut j)?;
        let mut m = Some(n);
        if j < src.len() && src[j] == ',' {
            j += 1;
            if j < src.len() && src[j] == '}' {
                m = None;
            } else {
                m = Some(num(&mut j)?);
            }
        }
        if j >= src.len() || src[j] != '}' {
            return None;
        }
        Some((n, m, j + 1))
    }

    fn quantifier(&mut self, t: Tree) -> Result<Tree, String> {
        if !self.more() {
            return Ok(t);
        }
        let (lo, hi) = match self.peek() {
            '*' => {
                self.i += 1;
                (0, None)
            }
            '+' => {
                self.i += 1;
                (1, None)
            }
            '?' => {
                self.i += 1;
                (0, Some(1))
            }
            '{' => {
                // {n}, {n,} or {n,m}; anything else is a literal "{" (Annex B).
                let Some((n, m, after)) = self.brace() else {
                    return Ok(t);
                };
                if m.is_some_and(|m| m < n) {
                    return Err(self.fail("numbers out of order in {} quantifier"));
                }
                self.i = after;
                (n, m)
            }
            _ => return Ok(t),
        };
        if self.more() && self.peek() == '?' {
            return Err(self.fail("lazy quantifiers are not supported"));
        }
        if t.kind == Kind::Look && t.behind {
            return Err(self.fail("a lookbehind cannot be quantified"));
        }
        // A quantified term is wrapped, so its own min and max stay 1.
        let mut t = if t.once() { t } else { Tree { children: vec![t], ..Tree::new(Kind::Group) } };
        t.min = lo;
        t.max = hi;
        Ok(t)
    }

    /// The set with the other case of every ASCII letter in it, when the
    /// pattern has the i flag.
    fn folded(&self, mut s: CharSet) -> CharSet {
        if !self.fold {
            return s;
        }
        for c in 'A' as u32..='Z' as u32 {
            if s.has_raw(c as u16) || s.has_raw((c + 32) as u16) {
                s.add(c);
                s.add(c + 32);
            }
        }
        s
    }

    fn class(&mut self) -> Result<CharSet, String> {
        let mut set = CharSet::new();
        let mut negate = false;
        if self.more() && self.peek() == '^' {
            negate = true;
            self.i += 1;
        }
        loop {
            if !self.more() {
                return Err(self.fail("missing ']'"));
            }
            if self.peek() == ']' {
                self.i += 1;
                break;
            }
            let lo = self.class_atom(&mut set)?;
            // A range a-b, unless "-" ends the class or either end is a class
            // escape such as \s (then "-" is literal, as Annex B reads it).
            if self.i + 1 < self.src.len() && self.peek() == '-' && self.src[self.i + 1] != ']' {
                let save = self.i;
                self.i += 1;
                let mut probe = CharSet::new();
                let hi = self.class_atom(&mut probe)?;
                if let (Some(lo), Some(hi)) = (lo, hi) {
                    if hi < lo {
                        return Err(self.fail("range out of order in character class"));
                    }
                    set.add_range(lo, hi);
                    continue;
                }
                // Not a range: the "-" and what follows are members on their own.
                if let Some(lo) = lo {
                    set.add(lo);
                }
                set.add('-' as u32);
                self.i = save + 1;
                continue;
            }
            if let Some(lo) = lo {
                set.add(lo);
            }
        }
        let mut set = self.folded(set);
        set.negate = negate;
        Ok(set)
    }

    /// Reads one member of a class: a character (returned), or a class
    /// escape added to `set` (`None`).
    fn class_atom(&mut self, set: &mut CharSet) -> Result<Option<u32>, String> {
        let c = self.peek();
        if c != '\\' {
            self.i += 1;
            return Ok(Some(c as u32));
        }
        self.i += 1;
        if !self.more() {
            return Err(self.fail("\\ at end of pattern"));
        }
        if self.peek() == 'b' {
            self.i += 1;
            return Ok(Some(0x08));
        }
        let mut single = CharSet::new();
        self.escape(&mut single)?;
        if let Some(r) = single.single() {
            return Ok(Some(r));
        }
        set.union(&single);
        Ok(None)
    }

    /// Reads what follows a backslash into `set`.
    fn escape(&mut self, set: &mut CharSet) -> Result<(), String> {
        let c = self.peek();
        self.i += 1;
        match c {
            'd' => set.add_range('0' as u32, '9' as u32),
            'D' => {
                set.add_range(0, 0xffff);
                for r in '0' as u32..='9' as u32 {
                    set.remove(r);
                }
            }
            'w' => add_word(set),
            'W' => {
                set.add_range(0, 0xffff);
                let mut w = CharSet::new();
                add_word(&mut w);
                for r in 0..128u32 {
                    if w.has_raw(r as u16) {
                        set.remove(r);
                    }
                }
            }
            's' => set.space = true,
            'S' => {
                set.add_range(0, 0xffff);
                set.not_space = true;
            }
            'n' => set.add('\n' as u32),
            't' => set.add('\t' as u32),
            'r' => set.add('\r' as u32),
            'f' => set.add(0x0c),
            'v' => set.add(0x0b),
            '0' => set.add(0),
            '1'..='9' | 'c' | 'k' | 'p' | 'P' => {
                // JavaScript reads these as a backreference, a control
                // character, a named backreference or a property; read as the
                // plain letter they would match something else, so they are
                // refused.
                return Err(format!("jsre: \\{c} is not supported"));
            }
            'x' | 'u' => {
                let mut width = 2;
                if c == 'u' {
                    width = 4;
                    if self.i < self.src.len() && self.src[self.i] == '{' {
                        return Err("jsre: \\u{...} is not supported".into());
                    }
                }
                if self.i + width <= self.src.len() {
                    let digits: String = self.src[self.i..self.i + width].iter().collect();
                    let hex = digits.chars().all(|d| d.is_ascii_hexdigit());
                    if let Some(n) = u32::from_str_radix(&digits, 16).ok().filter(|_| hex) {
                        self.i += width;
                        set.add(n);
                        return Ok(());
                    }
                }
                set.add(c as u32);
            }
            _ => {
                if c as u32 >= 0x10000 {
                    // Written as its two code units, as JavaScript holds it.
                    return Err("jsre: escape of a character outside the BMP is not supported".into());
                }
                set.add(c as u32);
            }
        }
        Ok(())
    }
}

fn add_word(s: &mut CharSet) {
    s.add_range('a' as u32, 'z' as u32);
    s.add_range('A' as u32, 'Z' as u32);
    s.add_range('0' as u32, '9' as u32);
    s.add('_' as u32);
}

/// A bitmap of every UTF-16 code unit.
pub(super) type Bits = [u64; 1 << 16 >> 6];

/// A set of UTF-16 code units: a bitmap of the whole range, built once at
/// compile time so a test is one lookup.
#[derive(Clone, Debug)]
pub(super) struct CharSet {
    bits: Box<Bits>,
    /// JavaScript's `\s`.
    space: bool,
    /// Everything but `\s` (with `bits` holding all).
    not_space: bool,
    negate: bool,
    pub(super) fin: Option<Box<Bits>>,
}

impl CharSet {
    pub(super) fn new() -> CharSet {
        CharSet { bits: Box::new([0; 1 << 16 >> 6]), space: false, not_space: false, negate: false, fin: None }
    }

    /// A set whose membership is these bits, already frozen.
    pub(super) fn frozen(bits: Box<Bits>) -> CharSet {
        let mut s = CharSet::new();
        s.fin = Some(bits);
        s
    }

    fn add(&mut self, r: u32) {
        if r >= 0x10000 {
            // A character outside the BMP in a pattern would be two code
            // units; the redaction patterns hold none.
            let r = r - 0x10000;
            self.add(0xd800 + (r >> 10));
            self.add(0xdc00 + (r & 0x3ff));
            return;
        }
        self.bits[(r >> 6) as usize] |= 1 << (r & 63);
    }

    fn add_range(&mut self, lo: u32, hi: u32) {
        let mut r = lo;
        while r <= hi && r < 0x10000 {
            self.add(r);
            r += 1;
        }
    }

    fn remove(&mut self, r: u32) {
        self.bits[(r >> 6) as usize] &= !(1 << (r & 63));
    }

    fn has_raw(&self, c: u16) -> bool {
        self.bits[(c >> 6) as usize] & (1 << (c & 63)) != 0
    }

    fn union(&mut self, o: &CharSet) {
        for (a, b) in self.bits.iter_mut().zip(o.bits.iter()) {
            *a |= b;
        }
        self.space = self.space || o.space;
        if o.not_space {
            self.not_space = true;
        }
    }

    /// The one character in a set holding exactly one plain character.
    fn single(&self) -> Option<u32> {
        if self.space || self.not_space || self.negate {
            return None;
        }
        let mut found = None;
        for (i, &w) in self.bits.iter().enumerate() {
            if w == 0 {
                continue;
            }
            if found.is_some() || w.count_ones() > 1 {
                return None;
            }
            found = Some(i as u32 * 64 + w.trailing_zeros());
        }
        found
    }

    /// Works out the final membership bitmap: `\s`, "everything but `\s`"
    /// and negation folded in.
    pub(super) fn freeze(&mut self) {
        if self.fin.is_some() {
            return;
        }
        let mut f = self.bits.clone();
        let space = space_bits();
        for (i, w) in f.iter_mut().enumerate() {
            if self.space {
                *w |= space[i];
            }
            if self.not_space {
                *w &= !space[i];
            }
            if self.negate {
                *w = !*w;
            }
        }
        self.fin = Some(f);
    }

    /// Whether the frozen set holds `c`.
    pub(super) fn has(&self, c: u16) -> bool {
        let f = self.fin.as_ref().expect("a frozen set");
        f[(c >> 6) as usize] & (1 << (c & 63)) != 0
    }
}

/// `\s` as a bitmap.
fn space_bits() -> &'static Bits {
    static BITS: std::sync::OnceLock<Box<Bits>> = std::sync::OnceLock::new();
    BITS.get_or_init(|| {
        let mut b = Box::new([0u64; 1 << 16 >> 6]);
        for c in 0..=0xffffu32 {
            if char::from_u32(c).is_some_and(crate::js::is_space) {
                b[(c >> 6) as usize] |= 1 << (c & 63);
            }
        }
        b
    })
}
