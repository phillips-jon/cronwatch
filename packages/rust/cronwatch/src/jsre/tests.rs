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
    assert_eq!(re.try_is_match("aBc"), Some(true));
    assert_eq!(re.try_is_match("ac"), Some(false));
    assert_eq!(re.to_string(), "/b+/gi");
}

#[test]
fn deep_matches_give_up_rather_than_overflow_the_stack() {
    // A loop whose passes are two units wide recurses a few frames a pass;
    // over a long input it gives up (the audit), on a tokio worker's stack.
    let answers = std::thread::Builder::new()
        .stack_size(1024 * 1024)
        .spawn(|| {
            let long = format!("{}c", "ab".repeat(16_384));
            let short = format!("{}c", "ab".repeat(100));
            let re = Regexp::must("(?:ab)*c", "");
            let counted = Regexp::must("(?:xy){100000}", "");
            (re.try_is_match(&long), re.try_is_match(&short), counted.try_is_match(&"xy".repeat(100_000)))
        })
        .unwrap()
        .join()
        .unwrap();
    assert_eq!(answers, (None, Some(true), None));
}

#[test]
fn a_match_that_backtracks_without_end_gives_up_within_its_steps() {
    // `\n*\n*\n*\n*\n*x` over newlines is some n^5 / 120 attempts; V8
    // takes seconds over 100. Past `MAX_STEPS` the match gives up, while
    // a pattern with work to do over a long output answers in full.
    let newlines = "\n".repeat(32_000);
    let started = std::time::Instant::now();
    assert_eq!(Regexp::must(r"\n*\n*\n*\n*\n*x", "").try_is_match(&newlines), None);
    assert_eq!(Regexp::must(".*x", "").try_is_match(&"a".repeat(32_000)), None);
    let took = started.elapsed();
    eprintln!("two budgets ran out in {took:?}");
    assert!(took < std::time::Duration::from_secs(5), "took {took:?}");
    assert_eq!(Regexp::must(r"\n*\n*\n*\n*\n*x", "").try_is_match(&"\n".repeat(20)), Some(false));
    assert_eq!(Regexp::must(r"\n*\n*\n*\n*\n*x", "").try_is_match(&format!("{newlines}x")), Some(true));
    assert_eq!(Regexp::must(".*done", "").try_is_match(&format!("{}done", "a".repeat(32_000))), Some(true));
    // Redaction has no budget: its patterns are the SDK's own, bounded.
    let units = crate::js::units(&"a".repeat(4_000));
    assert_eq!(Regexp::must(".*x", "g").replace_units(&units, |_| Vec::new()), units);
}

#[test]
fn a_character_outside_the_bmp_is_its_two_units_in_turn() {
    // /a😀b/.test("a😀b"), and "x😀😀y".replace(/😀{2}/g, "-"): the quantifier
    // takes the second unit alone, as V8 reads a pattern without `u`.
    assert_eq!(Regexp::must("a\u{1f600}b", "").try_is_match("a\u{1f600}b"), Some(true));
    assert_eq!(Regexp::must("a\u{1f600}b", "").try_is_match("ab"), Some(false));
    assert_eq!(replace("\u{1f600}+", "g", "x\u{1f600}\u{1f600}y", "-"), "x--y");
    assert_eq!(replace("\u{1f600}{2}", "g", "x\u{1f600}\u{1f600}y", "-"), "x\u{1f600}\u{1f600}y");
}

#[test]
fn patterns_too_deep_or_long_are_refused() {
    let nested = format!("{}a{}", "(".repeat(2000), ")".repeat(2000));
    assert!(Regexp::new(&nested, "").unwrap_err().contains("nested too deeply"));
    assert!(Regexp::new(&format!("{}a{}", "(".repeat(100), ")".repeat(100)), "").is_ok());
    assert!(Regexp::new(&"a".repeat(5000), "").unwrap_err().contains("more than 4096 characters"));
}
