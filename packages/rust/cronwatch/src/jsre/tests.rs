//! JavaScript's semantics the redaction patterns rely on, each checked
//! against what V8 answers for the same pattern and input (written beside
//! each case as the JavaScript expression it mirrors).

use super::*;

fn replace(source: &str, flags: &str, input: &str, template: &str) -> String {
    Regexp::new(source, flags).unwrap_or_else(|e| panic!("{e}")).replace(input, template)
}

#[test]
fn semantics() {
    let cases: &[(&str, &str, &str, &str, &str)] = &[
        // "abcd".replace(/ab|abc/g, "X"): the first alternative that matches wins, not the longest.
        ("ab|abc", "g", "abcd", "X", "Xcd"),
        // "aaab".replace(/a{1,3}ab/, "X"): greedy, then walked back.
        ("a{1,3}ab", "", "aaab", "X", "X"),
        // "xaaa".replace(/a{2}/g, "[$&]")
        ("a{2}", "g", "xaaa", "[$&]", "x[aa]a"),
        // "a1b2".replace(/\d/g, "#"), and only the first without g.
        (r"\d", "g", "a1b2", "#", "a#b#"),
        (r"\d", "", "a1b2", "#", "a#b2"),
        // \b is between ASCII word characters and anything else.
        (r"\bab", "g", "ab xab -ab \u{e9}ab", "X", "X xab -X \u{e9}X"),
        (r"\Bab", "g", "ab xab", "X", "ab xX"),
        // Lookbehind: "maxtokens=1 mytoken=2".replace(/\w+(?<!tokens)=\d/g, "X")
        (r"\w+(?<!tokens)=\d", "g", "maxtokens=1 mytoken=2", "X", "maxtokens=1 X"),
        // Lookahead, negative and positive.
        ("a(?!b)", "g", "ab ac a", "X", "ab Xc X"),
        ("a(?=b)", "g", "ab ac", "X", "Xb ac"),
        // Groups that did not take part are "" in a template.
        ("(a)|(b)", "g", "ab", "[$1|$2]", "[a|][|b]"),
        // Optional groups and quantified groups.
        ("passw(?:or)?d", "g", "passwd password passwod", "X", "X X passwod"),
        ("(?:ab ){0,3}c", "g", "ab ab ab ab c", "X", "ab X"),
        // /i folds ASCII letters only: "ſ" (long s) and "K" (Kelvin) stay themselves.
        ("secret|key", "gi", "SECRET Key \u{17f}ecret \u{212a}ey", "X", "X X \u{17f}ecret \u{212a}ey"),
        ("[a-z]+", "gi", "AbC\u{c9}", "X", "X\u{c9}"),
        // \s is JavaScript's set: no-break space, ideographic space, line separator, BOM.
        (r"a\sb", "g", "a\u{a0}b a\u{3000}b a\u{2028}b a\u{feff}b a\u{85}b", "X", "X X X X a\u{85}b"),
        // A negated class counts an emoji as two code units.
        (r"x[^\s]{3}", "g", "x\u{1F600}\u{1F600}", "X", "X\u{fffd}"),
        (r"x[^\s]{1,4}", "g", "xab\u{1F600}\u{1F600}", "X", "X\u{1F600}"),
        // Escaped punctuation, and "-" at the edge of a class.
        (r"a\/b\.c[+/=-]", "g", "a/b.c- a/b.c=", "X", "X X"),
        // An empty match moves on one unit.
        ("x*", "g", "ab", "-", "-a-b-"),
        // "{" that is not a quantifier is a literal (Annex B).
        ("a{b", "g", "a{b", "X", "X"),
        // $$ is a dollar.
        ("a", "g", "a", "$$", "$"),
    ];
    for &(source, flags, input, template, want) in cases {
        assert_eq!(replace(source, flags, input, template), want, "{input:?}.replace(/{source}/{flags}, {template:?})");
    }
}

#[test]
fn replace_with_a_function() {
    let re = Regexp::must(r#"(k)=(?:(")[^"]*"|(')[^']*'|\w+)"#, "g");
    let got = js::from_units(&re.replace_units(&js::units(r#"k="a b" k='c' k=d"#), |m| {
        let q = js::from_units(m.group(2).or_else(|| m.group(3)).unwrap_or(&[]));
        js::units(&format!("{}={q}_{q}", m.text(1)))
    }));
    assert_eq!(got, r#"k="_" k='_' k=_"#);
}

#[test]
fn long_bounded_runs() {
    // The regex crate has no lookahead; here a {0,16384} run is an ordinary
    // bound, and a run of it does not grow the stack a frame per character.
    let re = Regexp::must("<(?:[a-z]|-(?!--)){0,16384}>?", "g");
    let body = "ab-".repeat(5000);
    assert_eq!(re.replace(&format!("<{body}>"), "X"), "X");
    assert_eq!(re.replace("<ab---", "X"), "X---");
    // 4096, then the rest, then the empty match at the end.
    assert_eq!(Regexp::must("a{0,4096}", "g").replace(&"a".repeat(5000), "X"), "XXX");
}

#[test]
fn compile_errors() {
    for source in [
        "(a", "a)", "*a", "[a", "a{3,1}", "a+?", "(?<!a+)b", "[z-a]",
        // JavaScript reads these as something other than the letter.
        r"(a)\1", r"\cJ", r"\k<x>", r"\p{L}", r"\u{41}", r"[\2]",
    ] {
        assert!(Regexp::new(source, "g").is_err(), "/{source}/ compiled");
    }
    assert!(Regexp::new("a", "y").is_err(), "an unsupported flag was taken");
}

#[test]
fn matches_and_writes_itself() {
    let re = Regexp::must("b+", "gi");
    assert!(re.is_match("aBc"));
    assert!(!re.is_match("ac"));
    assert_eq!(re.to_string(), "/b+/gi");
}
