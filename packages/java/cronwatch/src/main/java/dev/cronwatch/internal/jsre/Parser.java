package dev.cronwatch.internal.jsre;

import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import org.jspecify.annotations.Nullable;

/**
 * The parser: a pattern's source, in JavaScript's non-unicode syntax, as a tree. The source is read
 * as UTF-16 code units, as V8 reads a pattern without the {@code u} flag, so a character outside
 * the BMP is its two code units in turn: a quantifier after it takes the second alone, and in a
 * class it is two members (a range between two such characters is out of order, as V8 finds it).
 */
final class Parser {
  /** Kinds of syntax tree node. */
  enum Kind {
    /** Children: the alternatives. */
    ALT,
    /** Children: the terms in order. */
    SEQ,
    /** One code unit from the set. */
    CHAR,
    /** {@code children[0]} inside; a capture above 0 captures. */
    GROUP,
    /** Lookahead or lookbehind around {@code children[0]}. */
    LOOK,
    /** {@code \b} */
    WORD_B,
    /** {@code \B} */
    NOT_WORD_B,
    /** {@code ^} */
    START,
    /** {@code $} */
    END
  }

  /** Unbounded, as a quantifier's most. */
  static final int INF = -1;

  /** A node of a parsed pattern. */
  static final class Tree {
    Kind kind;
    List<Tree> children = new ArrayList<>();
    @Nullable CharSet set;
    int capture;
    boolean behind;
    boolean negate;
    int min = 1;
    int max = 1;

    Tree(Kind kind) {
      this.kind = kind;
    }

    static Tree ofSet(CharSet set) {
      Tree t = new Tree(Kind.CHAR);
      t.set = set;
      return t;
    }

    boolean once() {
      return min == 1 && max == 1;
    }
  }

  /** How deep groups may nest: the parser and the compiler recurse into them. */
  static final int MAX_NESTING = 100;

  private final String src;
  private final boolean fold;
  private int i;
  private int depth;
  private int captures;

  /** Every set read, held once. */
  private final Map<CharSet, CharSet> sets = new HashMap<>();

  private Parser(String src, boolean fold) {
    this.src = src;
    this.fold = fold;
  }

  /** A pattern read: its tree and its number of capturing groups. */
  record Parsed(Tree tree, int captures) {}

  /** Reads a pattern's source into a tree. */
  static Parsed parse(String source, boolean fold) {
    Parser p = new Parser(source, fold);
    Tree t = p.disjunction();
    if (p.i < p.src.length()) {
      throw p.fail("unmatched ')'");
    }
    return new Parsed(t, p.captures);
  }

  private IllegalArgumentException fail(String what) {
    return new IllegalArgumentException("jsre: " + what + " at " + i + " in /" + src + "/");
  }

  private boolean more() {
    return i < src.length();
  }

  private char peek() {
    return src.charAt(i);
  }

  private CharSet intern(CharSet.Builder b) {
    CharSet s = b.build(fold);
    CharSet held = sets.putIfAbsent(s, s);
    return held == null ? s : held;
  }

  private Tree disjunction() {
    Tree alt = new Tree(Kind.ALT);
    while (true) {
      alt.children.add(alternative());
      if (more() && peek() == '|') {
        i++;
        continue;
      }
      break;
    }
    return alt.children.size() == 1 ? alt.children.get(0) : alt;
  }

  private Tree alternative() {
    Tree seq = new Tree(Kind.SEQ);
    while (more() && peek() != '|' && peek() != ')') {
      seq.children.add(term());
    }
    return seq;
  }

  private Tree term() {
    char c = peek();
    Tree t;
    switch (c) {
      case '^' -> {
        i++;
        return new Tree(Kind.START);
      }
      case '$' -> {
        i++;
        return new Tree(Kind.END);
      }
      case '(' -> {
        i++;
        Tree g = new Tree(Kind.GROUP);
        if (src.startsWith("?:", i)) {
          i += 2;
        } else if (src.startsWith("?=", i) || src.startsWith("?!", i)) {
          g.kind = Kind.LOOK;
          g.negate = src.charAt(i + 1) == '!';
          i += 2;
        } else if (src.startsWith("?<=", i) || src.startsWith("?<!", i)) {
          g.kind = Kind.LOOK;
          g.behind = true;
          g.negate = src.charAt(i + 2) == '!';
          i += 3;
        } else if (src.startsWith("?", i)) {
          throw fail("unsupported group");
        } else {
          captures++;
          g.capture = captures;
        }
        depth++;
        if (depth > MAX_NESTING) {
          throw fail("groups nested too deeply");
        }
        Tree inner = disjunction();
        depth--;
        if (!more() || peek() != ')') {
          throw fail("missing ')'");
        }
        i++;
        g.children.add(inner);
        if (g.kind == Kind.LOOK && g.behind) {
          // A lookbehind cannot be quantified.
          if (more() && isQuantifier()) {
            throw fail("a lookbehind cannot be quantified");
          }
          return g;
        }
        t = g;
      }
      case '[' -> {
        i++;
        t = Tree.ofSet(klass());
      }
      case '.' -> {
        i++;
        t = Tree.ofSet(intern(new CharSet.Builder().addAll(CharSet.DOT)));
      }
      case '\\' -> {
        i++;
        if (!more()) {
          throw fail("\\ at end of pattern");
        }
        if (peek() == 'b') {
          i++;
          return new Tree(Kind.WORD_B);
        }
        if (peek() == 'B') {
          i++;
          return new Tree(Kind.NOT_WORD_B);
        }
        CharSet.Builder b = new CharSet.Builder();
        escape(b);
        t = Tree.ofSet(intern(b));
      }
      case '*', '+', '?' -> throw fail("nothing to repeat");
      case ')' -> throw fail("unmatched ')'");
      default -> {
        i++;
        t = Tree.ofSet(intern(new CharSet.Builder().add(c)));
      }
    }
    return quantifier(t);
  }

  private boolean isQuantifier() {
    char c = peek();
    return c == '*' || c == '+' || c == '?' || (c == '{' && brace() != null);
  }

  /** A number of a quantifier, held at {@link Integer#MAX_VALUE}, as no input is that long. */
  private static int bounded(String digits) {
    return digits.length() > 9 ? Integer.MAX_VALUE : Integer.parseInt(digits);
  }

  /**
   * Reads a bounded quantifier ("{n}", "{n,}" or "{n,m}") at the parser's position: the bounds and
   * the index after its closing brace, or null when the opening brace is a literal (Annex B).
   */
  private int @Nullable [] brace() {
    int j = i + 1;
    int start = j;
    while (j < src.length() && src.charAt(j) >= '0' && src.charAt(j) <= '9') {
      j++;
    }
    if (j == start) {
      return null;
    }
    int n = bounded(stripZeros(src.substring(start, j)));
    int m = n;
    if (j < src.length() && src.charAt(j) == ',') {
      j++;
      if (j < src.length() && src.charAt(j) == '}') {
        m = INF;
      } else {
        int from = j;
        while (j < src.length() && src.charAt(j) >= '0' && src.charAt(j) <= '9') {
          j++;
        }
        if (j == from) {
          return null;
        }
        m = bounded(stripZeros(src.substring(from, j)));
      }
    }
    if (j >= src.length() || src.charAt(j) != '}') {
      return null;
    }
    return new int[] {n, m, j + 1};
  }

  private static String stripZeros(String digits) {
    int k = 0;
    while (k < digits.length() - 1 && digits.charAt(k) == '0') {
      k++;
    }
    return digits.substring(k);
  }

  private Tree quantifier(Tree t) {
    if (!more()) {
      return t;
    }
    int lo;
    int hi;
    switch (peek()) {
      case '*' -> {
        i++;
        lo = 0;
        hi = INF;
      }
      case '+' -> {
        i++;
        lo = 1;
        hi = INF;
      }
      case '?' -> {
        i++;
        lo = 0;
        hi = 1;
      }
      case '{' -> {
        int[] b = brace();
        if (b == null) {
          return t;
        }
        if (b[1] != INF && b[1] < b[0]) {
          throw fail("numbers out of order in {} quantifier");
        }
        i = b[2];
        lo = b[0];
        hi = b[1];
      }
      default -> {
        return t;
      }
    }
    if (more() && peek() == '?') {
      throw fail("lazy quantifiers are not supported");
    }
    // A quantified term is wrapped, so its own min and max stay 1.
    Tree q = t;
    if (!t.once()) {
      q = new Tree(Kind.GROUP);
      q.children.add(t);
    }
    q.min = lo;
    q.max = hi;
    return q;
  }

  private CharSet klass() {
    CharSet.Builder set = new CharSet.Builder();
    if (more() && peek() == '^') {
      set.negate = true;
      i++;
    }
    while (true) {
      if (!more()) {
        throw fail("missing ']'");
      }
      if (peek() == ']') {
        i++;
        break;
      }
      int lo = classAtom(set);
      // A range a-b, unless "-" ends the class or either end is a class escape such as \s (then
      // "-" is literal, as Annex B reads it).
      if (i + 1 < src.length() && peek() == '-' && src.charAt(i + 1) != ']') {
        int save = i;
        i++;
        CharSet.Builder probe = new CharSet.Builder();
        int hi = classAtom(probe);
        if (lo >= 0 && hi >= 0) {
          if (hi < lo) {
            throw fail("range out of order in character class");
          }
          set.addRange(lo, hi);
          continue;
        }
        // Not a range: the "-" and what follows are members on their own.
        if (lo >= 0) {
          set.add(lo);
        }
        set.add('-');
        i = save + 1;
        continue;
      }
      if (lo >= 0) {
        set.add(lo);
      }
    }
    return intern(set);
  }

  /**
   * Reads one member of a class: a character (returned), or a class escape added to {@code set}
   * (-1).
   */
  private int classAtom(CharSet.Builder set) {
    char c = peek();
    if (c != '\\') {
      i++;
      return c;
    }
    i++;
    if (!more()) {
      throw fail("\\ at end of pattern");
    }
    if (peek() == 'b') {
      i++;
      return 0x08;
    }
    CharSet.Builder single = new CharSet.Builder();
    escape(single);
    int r = single.single();
    if (r >= 0) {
      return r;
    }
    set.union(single);
    return -1;
  }

  /** Reads what follows a backslash into {@code set}. */
  private void escape(CharSet.Builder set) {
    char c = peek();
    i++;
    switch (c) {
      case 'd' -> set.addAll(CharSet.DIGIT);
      case 'D' -> set.addAll(CharSet.complement(CharSet.DIGIT));
      case 'w' -> set.addAll(CharSet.WORD);
      case 'W' -> set.addAll(CharSet.complement(CharSet.WORD));
      case 's' -> set.addAll(CharSet.SPACE);
      case 'S' -> set.addAll(CharSet.complement(CharSet.SPACE));
      case 'n' -> set.add('\n');
      case 't' -> set.add('\t');
      case 'r' -> set.add('\r');
      case 'f' -> set.add(0x0c);
      case 'v' -> set.add(0x0b);
      case '0' -> {
        // \0 then a digit is a legacy octal escape in JavaScript, read as something else here.
        if (more() && peek() >= '0' && peek() <= '9') {
          throw new IllegalArgumentException("jsre: \\0 followed by a digit is not supported");
        }
        set.add(0);
      }
      case '1', '2', '3', '4', '5', '6', '7', '8', '9', 'c', 'k', 'p', 'P' ->
          // JavaScript reads these as a backreference, a control character, a named
          // backreference, or a property; read as the plain letter they would match something
          // else, so they are refused.
          throw new IllegalArgumentException("jsre: \\" + c + " is not supported");
      case 'x', 'u' -> {
        int width = c == 'u' ? 4 : 2;
        if (c == 'u' && more() && peek() == '{') {
          throw new IllegalArgumentException("jsre: \\u{...} is not supported");
        }
        if (i + width <= src.length()) {
          int n = 0;
          boolean hex = true;
          for (int k = 0; k < width; k++) {
            int d = Character.digit(src.charAt(i + k), 16);
            if (d < 0 || src.charAt(i + k) > 'f') {
              hex = false;
              break;
            }
            n = n * 16 + d;
          }
          if (hex) {
            i += width;
            set.add(n);
            return;
          }
        }
        set.add(c);
      }
      default -> set.add(c);
    }
  }
}
