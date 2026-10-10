package dev.cronwatch.internal.jsre;

import dev.cronwatch.internal.jsre.Parser.Kind;
import dev.cronwatch.internal.jsre.Parser.Tree;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.List;
import java.util.function.Function;
import org.jspecify.annotations.Nullable;

/**
 * A small backtracking regular expression engine with JavaScript's semantics, for the SDK's secret
 * redaction patterns and for a job's stored {@code matches /.../} expect rule. It is the Go port's
 * {@code internal/jsre}, carried over through the Rust and Elixir ports with their audits' fixes.
 *
 * <p>{@code java.util.regex} cannot stand in for it: its {@code \s} and {@code \b} are its own,
 * {@code $} matches before a final line terminator, its case folding differs, and it has no step
 * limit. This engine matches over UTF-16 code units, as V8 does without the {@code u} flag, so an
 * emoji counts as two characters to a bounded quantifier and to a negated class, and the SDK's
 * patterns are written here verbatim and match exactly what they match there.
 *
 * <p>It reads the subset of JavaScript's syntax those patterns use, in non-unicode mode: literals
 * and escapes ({@code \d \s \w \b} and their negations, {@code \n \t \r \f \v \0 \xHH \\uHHHH}, and
 * any other escaped character), character classes with ranges and negation, capturing and
 * non-capturing groups, lookahead, fixed-length lookbehind, alternation, greedy quantifiers, and
 * the flags {@code g} and {@code i}. The {@code i} flag folds as JavaScript's Canonicalize without
 * {@code u}. What it does not implement it refuses rather than read as something else: lazy
 * quantifiers, named groups, backreferences, {@code \c}, {@code \p{...}}, {@code \\u{...}}, and
 * legacy octal escapes.
 *
 * <p>A compiled pattern is read-only, so one may be shared by every thread; each match keeps its
 * own state.
 */
public final class Regexp {
  /** The longest pattern {@link #compile} reads, in UTF-16 code units. */
  static final int MAX_SOURCE = 4096;

  /**
   * How deep one match may recurse. A loop whose passes are not one code unit wide ({@code
   * (?:ab)*}) recurses a few frames a pass, so a stored pattern over a long output could otherwise
   * overflow a thread's stack; past this the match gives up ({@link #tryTest} answers null).
   */
  static final int MAX_DEPTH = 512;

  /**
   * How much work {@link #tryTest} does before it gives up: each attempt at a node is a step, and
   * so is each code unit a repeat scans. A stored pattern of stars back to back ({@code
   * \n*\n*\n*\n*\n*x}) or a dot star ({@code .*x}) backtracks polynomially over an output it does
   * not match, as V8 does; past this the match gives up and the pattern does not match. The SDK's
   * own redaction patterns are bounded and run without a budget.
   */
  static final long MAX_STEPS = 50_000_000L;

  /** No node: the end of a chain that never continues. */
  private static final int NONE = -1;

  private final String source;
  private final String flags;
  private final boolean global;
  private final Node[] nodes;
  private final int start;
  private final int captures;
  private final int loops;

  /**
   * The code units a match can start with, or null when a match can start with anything (or be
   * empty), so the search skips positions no match could start at.
   */
  private final long @Nullable [] first;

  private enum Op {
    /** min to max code units from the set, greedy. */
    REP,
    /** min to max repeats of a one-unit body, greedy. */
    PRED_REP,
    /** Try each alternative in turn. */
    ALT,
    CAP_OPEN,
    CAP_CLOSE,
    /** A quantified group of any width. */
    LOOP,
    /** The end of one pass through a loop's body. */
    LOOP_BACK,
    LOOK,
    /** Lookbehind of a fixed width. */
    BEHIND,
    WORD_B,
    NOT_WORD_B,
    START,
    END,
    /** The whole pattern (or a lookahead's body) matched. */
    ACCEPT,
    /** A lookbehind's body matched, if it ends where the lookbehind stands. */
    ACCEPT_AT
  }

  /**
   * One step of the compiled pattern. Each node knows the step after it, so the matcher runs a
   * pattern as a chain and backtracks by returning false up the call stack.
   */
  private static final class Node {
    final Op op;
    @Nullable CharSet set;
    int min = 1;
    int max = 1;
    int next = NONE;
    int[] alts = new int[0];
    int body = NONE;
    int index;
    boolean negate;
    int width;
    int lp = NONE;
    @Nullable CharTest guard;
    boolean keep;

    Node(Op op) {
      this.op = op;
    }
  }

  private Regexp(
      String source,
      String flags,
      boolean global,
      Node[] nodes,
      int start,
      int captures,
      int loops,
      long @Nullable [] first) {
    this.source = source;
    this.flags = flags;
    this.global = global;
    this.nodes = nodes;
    this.start = start;
    this.captures = captures;
    this.loops = loops;
    this.first = first;
  }

  /**
   * Reads a JavaScript pattern's source (what goes between the slashes) and its flags ({@code g}
   * and {@code i}).
   *
   * @throws IllegalArgumentException for a pattern it cannot read or does not implement, one of
   *     more than 4096 characters, or one with groups nested more than 100 deep
   */
  public static Regexp compile(String source, String flags) {
    if (source.length() > MAX_SOURCE) {
      throw new IllegalArgumentException(
          "jsre: a pattern of more than " + MAX_SOURCE + " characters is not supported");
    }
    boolean fold = false;
    boolean global = false;
    for (int k = 0; k < flags.length(); k++) {
      char f = flags.charAt(k);
      switch (f) {
        case 'i' -> fold = true;
        case 'g' -> global = true;
        default -> throw new IllegalArgumentException("jsre: flag \"" + f + "\" is not supported");
      }
    }
    Parser.Parsed parsed = Parser.parse(source, fold);
    Compiler c = new Compiler(source);
    int accept = c.push(new Node(Op.ACCEPT));
    int start = c.compile(parsed.tree(), accept);
    c.guard(start, new boolean[c.nodes.size()]);
    long[] bits = new long[1 << 10];
    long[] first = first(parsed.tree(), bits) ? null : bits;
    return new Regexp(
        source,
        flags,
        global,
        c.nodes.toArray(new Node[0]),
        start,
        parsed.captures(),
        c.loops,
        first);
  }

  private static final class Compiler {
    final List<Node> nodes = new ArrayList<>();
    int loops;
    final String source;

    Compiler(String source) {
      this.source = source;
    }

    int push(Node n) {
      nodes.add(n);
      return nodes.size() - 1;
    }

    /** Builds the chain for {@code t}, which continues with {@code cont}. */
    int compile(Tree t, int cont) {
      if (t.once()) {
        return once(t, cont);
      }
      if (t.kind == Kind.CHAR) {
        Node n = new Node(Op.REP);
        n.set = t.set;
        n.min = t.min;
        n.max = t.max;
        n.next = cont;
        return push(n);
      }
      long[] w = width(t.children.get(0));
      if (w[0] == 1 && w[1] == 1 && !hasCapture(t) && t.kind == Kind.GROUP && t.capture == 0) {
        // Every pass takes exactly one code unit, so the passes are counted greedily and walked
        // back, rather than taking one call per pass: a {0,16384} run stays shallow.
        int accept = push(new Node(Op.ACCEPT));
        Node n = new Node(Op.PRED_REP);
        n.body = compile(t.children.get(0), accept);
        n.min = t.min;
        n.max = t.max;
        n.next = cont;
        return push(n);
      }
      Node loop = new Node(Op.LOOP);
      loop.min = t.min;
      loop.max = t.max;
      loop.next = cont;
      loop.index = loops++;
      int lp = push(loop);
      Node back = new Node(Op.LOOP_BACK);
      back.lp = lp;
      int b = push(back);
      int min = t.min;
      int max = t.max;
      t.min = 1;
      t.max = 1;
      loop.body = once(t, b);
      t.min = min;
      t.max = max;
      return lp;
    }

    /** Builds the chain for one pass of {@code t}. */
    int once(Tree t, int cont) {
      return switch (t.kind) {
        case SEQ -> sequence(t, cont);
        case ALT -> alternation(t, cont);
        case CHAR -> {
          Node n = new Node(Op.REP);
          n.set = t.set;
          n.next = cont;
          yield push(n);
        }
        case GROUP -> group(t, cont);
        case LOOK -> t.behind ? behind(t, cont) : ahead(t, cont);
        case WORD_B -> assertion(Op.WORD_B, cont);
        case NOT_WORD_B -> assertion(Op.NOT_WORD_B, cont);
        case START -> assertion(Op.START, cont);
        case END -> assertion(Op.END, cont);
      };
    }

    private int sequence(Tree t, int cont) {
      int c = cont;
      for (int k = t.children.size() - 1; k >= 0; k--) {
        c = compile(t.children.get(k), c);
      }
      return c;
    }

    private int alternation(Tree t, int cont) {
      Node n = new Node(Op.ALT);
      n.alts = new int[t.children.size()];
      for (int k = 0; k < t.children.size(); k++) {
        n.alts[k] = compile(t.children.get(k), cont);
      }
      return push(n);
    }

    private int group(Tree t, int cont) {
      if (t.capture == 0) {
        return compile(t.children.get(0), cont);
      }
      Node close = new Node(Op.CAP_CLOSE);
      close.index = t.capture;
      close.next = cont;
      int closed = push(close);
      Node open = new Node(Op.CAP_OPEN);
      open.index = t.capture;
      open.next = compile(t.children.get(0), closed);
      return push(open);
    }

    private int behind(Tree t, int cont) {
      long[] w = width(t.children.get(0));
      if (w[1] != w[0]) {
        throw new IllegalArgumentException(
            "jsre: a lookbehind must have one width, in /" + source + "/");
      }
      int at = push(new Node(Op.ACCEPT_AT));
      Node n = new Node(Op.BEHIND);
      n.keep = hasCapture(t);
      n.negate = t.negate;
      n.width = (int) Math.min(w[0], Integer.MAX_VALUE);
      n.body = compile(t.children.get(0), at);
      n.next = cont;
      return push(n);
    }

    private int ahead(Tree t, int cont) {
      int accept = push(new Node(Op.ACCEPT));
      Node n = new Node(Op.LOOK);
      n.keep = hasCapture(t);
      n.negate = t.negate;
      n.body = compile(t.children.get(0), accept);
      n.next = cont;
      return push(n);
    }

    private int assertion(Op op, int cont) {
      Node n = new Node(op);
      n.next = cont;
      return push(n);
    }

    /** Sets each repeat's guard, visiting every node once. */
    void guard(int n, boolean[] seen) {
      if (n == NONE || seen[n]) {
        return;
      }
      seen[n] = true;
      Node node = nodes.get(n);
      if (node.op == Op.REP || node.op == Op.PRED_REP) {
        node.guard = startSet(node.next, 0);
      }
      guard(node.next, seen);
      guard(node.body, seen);
      for (int a : node.alts) {
        guard(a, seen);
      }
    }

    /** What a match from {@code n} must start with, or null when it may start with anything. */
    @Nullable CharTest startSet(int n, int depth) {
      if (n == NONE || depth > 16) {
        return null;
      }
      Node node = nodes.get(n);
      return switch (node.op) {
        case REP -> node.min >= 1 ? node.set : null;
        case ALT -> {
          List<CharTest> parts = new ArrayList<>();
          for (int a : node.alts) {
            CharTest s = startSet(a, depth + 1);
            if (s == null) {
              yield null;
            }
            parts.add(s);
          }
          yield CharTest.anyOf(parts);
        }
        // These take nothing; what follows them starts the match.
        case CAP_OPEN, CAP_CLOSE, LOOK, BEHIND, WORD_B, NOT_WORD_B ->
            startSet(node.next, depth + 1);
        default -> null;
      };
    }
  }

  private static long mul(long a, int m) {
    if (a == 0 || m == 0) {
      return 0;
    }
    return a > Long.MAX_VALUE / m ? Long.MAX_VALUE : a * m;
  }

  /** The least and most code units {@code t} can take; a most of -1 is no limit. */
  private static long[] width(Tree t) {
    long lo;
    long hi;
    switch (t.kind) {
      case CHAR -> {
        lo = 1;
        hi = 1;
      }
      case SEQ -> {
        lo = 0;
        hi = 0;
        for (Tree c : t.children) {
          long[] w = width(c);
          lo = Math.min(Long.MAX_VALUE / 2, lo + w[0]);
          hi = hi < 0 || w[1] < 0 ? -1 : Math.min(Long.MAX_VALUE / 2, hi + w[1]);
        }
      }
      case ALT -> {
        lo = Long.MAX_VALUE;
        hi = 0;
        for (Tree c : t.children) {
          long[] w = width(c);
          lo = Math.min(lo, w[0]);
          hi = hi < 0 || w[1] < 0 ? -1 : Math.max(hi, w[1]);
        }
        if (t.children.isEmpty()) {
          lo = 0;
        }
      }
      case GROUP -> {
        long[] w = width(t.children.get(0));
        lo = w[0];
        hi = w[1];
      }
      default -> {
        // Assertions and lookarounds take nothing.
        return new long[] {0, 0};
      }
    }
    // A quantified term repeats its own width.
    long qlo = mul(lo, t.min);
    long qhi;
    if (t.max == Parser.INF) {
      qhi = hi == 0 ? 0 : -1;
    } else {
      qhi = hi < 0 ? -1 : mul(hi, t.max);
    }
    return new long[] {qlo, qhi};
  }

  private static boolean hasCapture(Tree t) {
    if (t.kind == Kind.GROUP && t.capture > 0) {
      return true;
    }
    for (Tree c : t.children) {
      if (hasCapture(c)) {
        return true;
      }
    }
    return false;
  }

  /**
   * Adds to {@code bits} what {@code t} can start with, and says whether {@code t} can match
   * without taking anything (so what follows it can start the match too).
   */
  private static boolean first(Tree t, long[] bits) {
    boolean nullable;
    switch (t.kind) {
      case CHAR -> {
        java.util.Objects.requireNonNull(t.set).addTo(bits);
        nullable = false;
      }
      case SEQ -> {
        nullable = true;
        for (Tree c : t.children) {
          if (!first(c, bits)) {
            nullable = false;
            break;
          }
        }
      }
      case ALT -> {
        nullable = false;
        for (Tree c : t.children) {
          if (first(c, bits)) {
            nullable = true;
          }
        }
      }
      case GROUP -> nullable = first(t.children.get(0), bits);
      default -> {
        return true;
      }
    }
    return nullable || t.min == 0;
  }

  // ---- matching

  /** Whether the pattern matches anywhere in {@code text}, with no step budget. */
  public boolean test(String text) {
    Matcher m = new Matcher(this, text, Long.MAX_VALUE);
    return m.exec(0);
  }

  /**
   * Whether the pattern matches anywhere in {@code text}, within {@link #MAX_STEPS} steps and
   * {@link #MAX_DEPTH} frames, or null when the match gave up: a stored expect pattern then does
   * not match.
   */
  public @Nullable Boolean tryTest(String text) {
    Matcher m = new Matcher(this, text, MAX_STEPS);
    boolean found = m.exec(0);
    return m.gaveUp ? null : found;
  }

  /**
   * {@code String.prototype.replace} with a replacement string: {@code $1} to {@code $99} are the
   * groups ("" for one that did not take part), {@code $&} the match, {@code $`} and {@code $'}
   * what comes before and after it, {@code $$} a "$". Every match with the {@code g} flag, else the
   * first.
   */
  public String replace(String text, String replacement) {
    return replaceWithin(text, Long.MAX_VALUE, m -> expand(replacement, m));
  }

  /** {@code String.prototype.replace} with a function of each match. */
  public String replace(String text, Function<Match, String> replacement) {
    return replaceWithin(text, Long.MAX_VALUE, replacement);
  }

  /**
   * {@link #replace(String, String)} within {@link #MAX_STEPS}, or null when a match gave up: an
   * arbitrary pattern's replacement, for the property that it always ends.
   */
  @Nullable String tryReplace(String text, String replacement) {
    String[] out = new String[1];
    boolean gaveUp = replaceWithin(text, MAX_STEPS, m -> expand(replacement, m), out);
    return gaveUp ? null : out[0];
  }

  private String replaceWithin(String text, long budget, Function<Match, String> f) {
    String[] out = new String[1];
    replaceWithin(text, budget, f, out);
    return out[0];
  }

  /** The replacement into {@code out[0]}, and whether a match gave up part way. */
  private boolean replaceWithin(String text, long budget, Function<Match, String> f, String[] out) {
    Matcher m = new Matcher(this, text, budget);
    StringBuilder b = null;
    int last = 0;
    int pos = 0;
    while (pos <= text.length() && m.exec(pos)) {
      int s = m.caps[0];
      int e = m.caps[1];
      if (b == null) {
        b = new StringBuilder(text.length());
      }
      b.append(text, last, s);
      b.append(f.apply(new Match(text, m.caps.clone())));
      last = e;
      pos = e == s ? e + 1 : e;
      if (!global) {
        break;
      }
    }
    if (b == null) {
      out[0] = text;
    } else {
      b.append(text, last, text.length());
      out[0] = b.toString();
    }
    return m.gaveUp;
  }

  private static String expand(String template, Match m) {
    StringBuilder b = new StringBuilder(template.length());
    int n = template.length();
    int groups = m.caps.length / 2;
    int k = 0;
    while (k < n) {
      char c = template.charAt(k);
      if (c != '$' || k + 1 >= n) {
        b.append(c);
        k++;
        continue;
      }
      char d = template.charAt(k + 1);
      if (d == '$') {
        b.append('$');
        k += 2;
      } else if (d == '&') {
        b.append(m.text(0));
        k += 2;
      } else if (d == '`') {
        b.append(m.input, 0, m.caps[0]);
        k += 2;
      } else if (d == '\'') {
        b.append(m.input, m.caps[1], m.input.length());
        k += 2;
      } else if (d >= '0' && d <= '9') {
        int group = d - '0';
        int used = 1;
        if (k + 2 < n && template.charAt(k + 2) >= '0' && template.charAt(k + 2) <= '9') {
          int two = group * 10 + (template.charAt(k + 2) - '0');
          if (two >= 1 && two < groups) {
            group = two;
            used = 2;
          }
        }
        if (group < 1 || group >= groups) {
          b.append(c);
          k++;
          continue;
        }
        b.append(m.text(group));
        k += 1 + used;
      } else {
        b.append(c);
        k++;
      }
    }
    return b.toString();
  }

  /** The pattern as JavaScript writes it: {@code /source/flags}. */
  @Override
  public String toString() {
    return "/" + source + "/" + flags;
  }

  /** One match: the whole match and each group. */
  public static final class Match {
    private final String input;
    private final int[] caps;

    Match(String input, int[] caps) {
      this.input = input;
      this.caps = caps;
    }

    /** Group {@code i} (0 is the whole match), or null when it did not take part in the match. */
    public @Nullable String group(int i) {
      if (2 * i + 1 >= caps.length || caps[2 * i] < 0 || caps[2 * i + 1] < 0) {
        return null;
      }
      return input.substring(caps[2 * i], caps[2 * i + 1]);
    }

    /** Group {@code i}, or "" when it did not take part. */
    public String text(int i) {
      String g = group(i);
      return g == null ? "" : g;
    }
  }

  /** The state of one search. */
  private static final class Matcher {
    final Regexp re;
    final Node[] nodes;
    final String input;
    final int len;
    final int[] caps;
    final int[] loopCount;
    final int[] loopStart;
    int end = -1;
    int target;
    int depth;
    long steps;
    boolean gaveUp;

    Matcher(Regexp re, String input, long budget) {
      this.re = re;
      this.nodes = re.nodes;
      this.input = input;
      this.len = input.length();
      this.caps = new int[2 * (re.captures + 1)];
      this.loopCount = new int[re.loops];
      this.loopStart = new int[re.loops];
      this.steps = budget;
    }

    /** Finds the first match starting at or after {@code from}. */
    boolean exec(int from) {
      long[] first = re.first;
      for (int s = from; s <= len; s++) {
        if (first != null) {
          if (s == len) {
            return false;
          }
          char c = input.charAt(s);
          if ((first[c >> 6] & (1L << (c & 63))) == 0) {
            continue;
          }
        }
        Arrays.fill(caps, -1);
        end = -1;
        if (run(re.start, s)) {
          caps[0] = s;
          caps[1] = end;
          return true;
        }
        if (gaveUp) {
          return false;
        }
      }
      return false;
    }

    private static boolean isWord(char c) {
      return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '_';
    }

    private boolean wordAt(int i) {
      return i >= 0 && i < len && isWord(input.charAt(i));
    }

    private boolean guarded(Node n, int at) {
      CharTest g = n.guard;
      return g == null || (at < len && g.has(input.charAt(at)));
    }

    /**
     * Whether the chain from {@code n} matches at {@code pos}, leaving captures and {@code end} set
     * when it does. Past {@link #MAX_DEPTH}, or out of steps, the match gives up: this and every
     * call after it answers false, and {@code gaveUp} is set.
     */
    boolean run(int n, int pos) {
      if (gaveUp) {
        return false;
      }
      if (depth >= MAX_DEPTH || steps <= 0) {
        gaveUp = true;
        return false;
      }
      depth++;
      steps--;
      boolean matched = runChain(n, pos);
      depth--;
      return matched;
    }

    private int limit(Node node, int pos) {
      int limit = len - pos;
      return node.max == Parser.INF ? limit : Math.min(limit, node.max);
    }

    private boolean runChain(int n0, int pos0) {
      int n = n0;
      int pos = pos0;
      while (true) {
        Node node = nodes[n];
        switch (node.op) {
          case REP -> {
            CharSet set = node.set;
            int limit = limit(node, pos);
            int k = 0;
            while (k < limit && set.has(input.charAt(pos + k))) {
              k++;
            }
            steps -= k;
            if (k < node.min) {
              return false;
            }
            if (k == node.min) {
              pos += k;
              n = node.next;
              continue;
            }
            for (int i = k; ; i--) {
              if (guarded(node, pos + i) && run(node.next, pos + i)) {
                return true;
              }
              if (i == node.min) {
                return false;
              }
            }
          }
          case PRED_REP -> {
            int limit = limit(node, pos);
            int saved = end;
            int k = 0;
            while (k < limit && run(node.body, pos + k) && end == pos + k + 1) {
              k++;
            }
            end = saved;
            if (k < node.min) {
              return false;
            }
            for (int i = k; ; i--) {
              if (guarded(node, pos + i) && run(node.next, pos + i)) {
                return true;
              }
              if (i == node.min) {
                return false;
              }
            }
          }
          case ALT -> {
            int[] alts = node.alts;
            for (int a = 0; a < alts.length - 1; a++) {
              if (run(alts[a], pos)) {
                return true;
              }
            }
            n = alts[alts.length - 1];
          }
          case CAP_OPEN -> {
            int i = 2 * node.index;
            int oldStart = caps[i];
            int oldEnd = caps[i + 1];
            caps[i] = pos;
            if (run(node.next, pos)) {
              return true;
            }
            caps[i] = oldStart;
            caps[i + 1] = oldEnd;
            return false;
          }
          case CAP_CLOSE -> {
            int i = 2 * node.index + 1;
            int old = caps[i];
            caps[i] = pos;
            if (run(node.next, pos)) {
              return true;
            }
            caps[i] = old;
            return false;
          }
          case LOOP -> {
            return iterate(n, 0, pos);
          }
          case LOOP_BACK -> {
            int lp = node.lp;
            int index = nodes[lp].index;
            int count = loopCount[index];
            int startedAt = loopStart[index];
            if (pos == startedAt) {
              // A pass that took nothing ends the loop without matching, as JavaScript's
              // RepeatMatcher refuses an empty iteration.
              return false;
            }
            if (iterate(lp, count, pos)) {
              return true;
            }
            loopCount[index] = count;
            loopStart[index] = startedAt;
            return false;
          }
          case LOOK -> {
            int[] saved = node.keep ? caps.clone() : null;
            int e = end;
            boolean ok = run(node.body, pos);
            end = e;
            if (saved != null && (ok == node.negate || node.negate)) {
              System.arraycopy(saved, 0, caps, 0, caps.length);
            }
            if (ok == node.negate) {
              return false;
            }
            n = node.next;
          }
          case BEHIND -> {
            boolean ok = false;
            if (pos >= node.width) {
              int[] saved = node.keep ? caps.clone() : null;
              int t = target;
              int e = end;
              target = pos;
              ok = run(node.body, pos - node.width);
              target = t;
              end = e;
              if (saved != null && (!ok || node.negate)) {
                System.arraycopy(saved, 0, caps, 0, caps.length);
              }
            }
            if (ok == node.negate) {
              return false;
            }
            n = node.next;
          }
          case WORD_B, NOT_WORD_B -> {
            boolean at = wordAt(pos - 1) != wordAt(pos);
            if (at != (node.op == Op.WORD_B)) {
              return false;
            }
            n = node.next;
          }
          case START -> {
            if (pos != 0) {
              return false;
            }
            n = node.next;
          }
          case END -> {
            if (pos != len) {
              return false;
            }
            n = node.next;
          }
          case ACCEPT -> {
            end = pos;
            return true;
          }
          case ACCEPT_AT -> {
            return pos == target;
          }
        }
      }
    }

    /**
     * Tries one more pass of a loop that has made {@code count} passes, then (greedy) leaving it.
     */
    private boolean iterate(int lp, int count, int pos) {
      Node node = nodes[lp];
      int count0 = loopCount[node.index];
      int start0 = loopStart[node.index];
      if (node.max == Parser.INF || count < node.max) {
        loopCount[node.index] = count + 1;
        loopStart[node.index] = pos;
        if (run(node.body, pos)) {
          return true;
        }
        loopCount[node.index] = count0;
        loopStart[node.index] = start0;
      }
      if (count >= node.min) {
        return run(node.next, pos);
      }
      return false;
    }
  }
}
