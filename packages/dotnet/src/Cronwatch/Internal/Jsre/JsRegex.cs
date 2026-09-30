using System;
using System.Collections.Generic;
using System.Globalization;
using System.Text;

namespace Cronwatch.Internal;

/// <summary>
/// A small backtracking regular expression engine with JavaScript's semantics, for the SDK's
/// secret redaction patterns and for a job's stored <c>matches /.../</c> expect rule. It is the Go
/// port's <c>internal/jsre</c>, carried over through the Rust, Elixir and Java ports with their
/// audits' fixes.
/// </summary>
/// <remarks>
/// <para><c>System.Text.RegularExpressions</c> cannot stand in for it: its <c>\s</c> and
/// <c>\b</c> are its own, <c>$</c> matches before a final newline, its case folding differs, and
/// it reads backreferences and classes its own way. This engine matches over UTF-16 code units,
/// as V8 does without the <c>u</c> flag, so an emoji counts as two characters to a bounded
/// quantifier and to a negated class, and the SDK's patterns are written here verbatim and match
/// exactly what they match there.</para>
/// <para>It reads the subset of JavaScript's syntax those patterns use, in non-unicode mode:
/// literals and escapes, character classes with ranges and negation, capturing and non-capturing
/// groups, lookahead, fixed-length lookbehind, alternation, greedy quantifiers, and the flags
/// <c>g</c> and <c>i</c>. What it does not implement it refuses rather than read as something
/// else: lazy quantifiers, named groups, backreferences, <c>\c</c>, <c>\p{...}</c>,
/// <c>\u{...}</c> and legacy octal escapes.</para>
/// <para>A compiled pattern is read-only, so one may be shared by every thread; each match keeps
/// its own state.</para>
/// </remarks>
internal sealed class JsRegex
{
    /// <summary>The longest pattern <see cref="Compile"/> reads, in UTF-16 code units.</summary>
    public const int MaxSource = 4096;

    /// <summary>
    /// How deep one match may recurse. A loop whose passes are not one code unit wide
    /// (<c>(?:ab)*</c>) recurses a few frames a pass, so a stored pattern over a long output could
    /// otherwise overflow a thread's stack, which .NET cannot catch; past this the match gives up
    /// (<see cref="TryTest(string)"/> answers null).
    /// </summary>
    public const int MaxDepth = 512;

    /// <summary>
    /// How much work <see cref="TryTest(string)"/> does before it gives up: each attempt at a node is a
    /// step, and so is each code unit a repeat scans. A stored pattern of stars back to back
    /// (<c>\n*\n*\n*\n*\n*x</c>) or a dot star (<c>.*x</c>) backtracks polynomially over an output
    /// it does not match, as V8 does; past this the match gives up and the pattern does not match.
    /// The SDK's own redaction patterns are bounded and run without a budget.
    /// </summary>
    public const long MaxSteps = 50_000_000L;

    /// <summary>No node: the end of a chain that never continues.</summary>
    private const int None = -1;

    private readonly string _source;
    private readonly string _flags;
    private readonly bool _global;
    private readonly Node[] _nodes;
    private readonly int _start;
    private readonly int _captures;
    private readonly int _loops;

    /// <summary>
    /// The code units a match can start with, or null when a match can start with anything (or
    /// be empty), so the search skips positions no match could start at.
    /// </summary>
    private readonly ulong[]? _first;

    private enum Op
    {
        /// <summary>Min to max code units from the set, greedy.</summary>
        Rep,

        /// <summary>Min to max repeats of a one-unit body, greedy.</summary>
        PredRep,

        /// <summary>Try each alternative in turn.</summary>
        Alt,
        CapOpen,
        CapClose,

        /// <summary>A quantified group of any width.</summary>
        Loop,

        /// <summary>The end of one pass through a loop's body.</summary>
        LoopBack,
        Look,

        /// <summary>Lookbehind of a fixed width.</summary>
        Behind,
        WordB,
        NotWordB,
        Start,
        End,

        /// <summary>The whole pattern (or a lookahead's body) matched.</summary>
        Accept,

        /// <summary>A lookbehind's body matched, if it ends where the lookbehind stands.</summary>
        AcceptAt,
    }

    /// <summary>
    /// One step of the compiled pattern. Each node knows the step after it, so the matcher runs a
    /// pattern as a chain and backtracks by returning false up the call stack.
    /// </summary>
    private sealed class Node(Op op)
    {
        public readonly Op Op = op;
        public JsreCharSet? Set;
        public int Min = 1;
        public int Max = 1;
        public int Next = None;
        public int[] Alts = [];
        public int Body = None;
        public int Index;
        public bool Negate;
        public int Width;
        public int Lp = None;
        public IJsreCharTest? Guard;
        public bool Keep;
    }

    private JsRegex(string source, string flags, bool global, Node[] nodes, int start, int captures, int loops, ulong[]? first)
    {
        _source = source;
        _flags = flags;
        _global = global;
        _nodes = nodes;
        _start = start;
        _captures = captures;
        _loops = loops;
        _first = first;
    }

    /// <summary>The pattern's source, what goes between the slashes.</summary>
    public string Source => _source;

    /// <summary>The pattern's flags.</summary>
    public string Flags => _flags;

    /// <summary>
    /// Reads a JavaScript pattern's source (what goes between the slashes) and its flags (<c>g</c>
    /// and <c>i</c>).
    /// </summary>
    /// <exception cref="ArgumentException">For a pattern it cannot read or does not implement, one
    /// of more than 4096 characters, or one with groups nested more than 100 deep.</exception>
    public static JsRegex Compile(string source, string flags)
    {
        if (source.Length > MaxSource)
        {
            throw new ArgumentException(
                "jsre: a pattern of more than " + MaxSource.ToString(CultureInfo.InvariantCulture) + " characters is not supported");
        }
        bool fold = false;
        bool global = false;
        foreach (char f in flags)
        {
            switch (f)
            {
                case 'i':
                    fold = true;
                    break;
                case 'g':
                    global = true;
                    break;
                default:
                    throw new ArgumentException("jsre: flag \"" + f + "\" is not supported");
            }
        }
        var (tree, captures) = JsreParser.Parse(source, fold);
        var c = new Compiler(source);
        int accept = c.Push(new Node(Op.Accept));
        int start = c.Compile(tree, accept);
        c.SetGuards(start, new bool[c.Nodes.Count]);
        var bits = new ulong[1 << 10];
        ulong[]? first = First(tree, bits) ? null : bits;
        return new JsRegex(source, flags, global, c.Nodes.ToArray(), start, captures, c.Loops, first);
    }

    private sealed class Compiler(string source)
    {
        public readonly List<Node> Nodes = [];
        public int Loops;

        public int Push(Node n)
        {
            Nodes.Add(n);
            return Nodes.Count - 1;
        }

        /// <summary>Builds the chain for <paramref name="t"/>, which continues with <paramref name="cont"/>.</summary>
        public int Compile(JsreTree t, int cont)
        {
            if (t.Once)
            {
                return Once(t, cont);
            }
            if (t.Kind == JsreKind.Char)
            {
                return Push(new Node(Op.Rep) { Set = t.Set, Min = t.Min, Max = t.Max, Next = cont });
            }
            var (lo, hi) = WidthOf(t.Children[0]);
            if (lo == 1 && hi == 1 && !HasCapture(t) && t.Kind == JsreKind.Group && t.Capture == 0)
            {
                // Every pass takes exactly one code unit, so the passes are counted greedily and
                // walked back, rather than taking one call per pass: a {0,16384} run stays shallow.
                int accept = Push(new Node(Op.Accept));
                var n = new Node(Op.PredRep) { Min = t.Min, Max = t.Max, Next = cont };
                n.Body = Compile(t.Children[0], accept);
                return Push(n);
            }
            var loop = new Node(Op.Loop) { Min = t.Min, Max = t.Max, Next = cont, Index = Loops++ };
            int lp = Push(loop);
            int b = Push(new Node(Op.LoopBack) { Lp = lp });
            int min = t.Min;
            int max = t.Max;
            t.Min = 1;
            t.Max = 1;
            loop.Body = Once(t, b);
            t.Min = min;
            t.Max = max;
            return lp;
        }

        /// <summary>Builds the chain for one pass of <paramref name="t"/>.</summary>
        private int Once(JsreTree t, int cont) => t.Kind switch
        {
            JsreKind.Seq => Sequence(t, cont),
            JsreKind.Alt => Alternation(t, cont),
            JsreKind.Char => Push(new Node(Op.Rep) { Set = t.Set, Next = cont }),
            JsreKind.Group => Group(t, cont),
            JsreKind.Look => t.Behind ? Behind(t, cont) : Ahead(t, cont),
            JsreKind.WordB => Assertion(Op.WordB, cont),
            JsreKind.NotWordB => Assertion(Op.NotWordB, cont),
            JsreKind.Start => Assertion(Op.Start, cont),
            _ => Assertion(Op.End, cont),
        };

        private int Sequence(JsreTree t, int cont)
        {
            int c = cont;
            for (int k = t.Children.Count - 1; k >= 0; k--)
            {
                c = Compile(t.Children[k], c);
            }
            return c;
        }

        private int Alternation(JsreTree t, int cont)
        {
            var n = new Node(Op.Alt) { Alts = new int[t.Children.Count] };
            for (int k = 0; k < t.Children.Count; k++)
            {
                n.Alts[k] = Compile(t.Children[k], cont);
            }
            return Push(n);
        }

        private int Group(JsreTree t, int cont)
        {
            if (t.Capture == 0)
            {
                return Compile(t.Children[0], cont);
            }
            int closed = Push(new Node(Op.CapClose) { Index = t.Capture, Next = cont });
            var open = new Node(Op.CapOpen) { Index = t.Capture };
            open.Next = Compile(t.Children[0], closed);
            return Push(open);
        }

        private int Behind(JsreTree t, int cont)
        {
            var (lo, hi) = WidthOf(t.Children[0]);
            if (hi != lo)
            {
                throw new ArgumentException("jsre: a lookbehind must have one width, in /" + source + "/");
            }
            int at = Push(new Node(Op.AcceptAt));
            var n = new Node(Op.Behind)
            {
                Keep = HasCapture(t),
                Negate = t.Negate,
                Width = (int)Math.Min(lo, int.MaxValue),
                Next = cont,
            };
            n.Body = Compile(t.Children[0], at);
            return Push(n);
        }

        private int Ahead(JsreTree t, int cont)
        {
            int accept = Push(new Node(Op.Accept));
            var n = new Node(Op.Look) { Keep = HasCapture(t), Negate = t.Negate, Next = cont };
            n.Body = Compile(t.Children[0], accept);
            return Push(n);
        }

        private int Assertion(Op op, int cont) => Push(new Node(op) { Next = cont });

        /// <summary>Sets each repeat's guard, visiting every node once.</summary>
        public void SetGuards(int n, bool[] seen)
        {
            if (n == None || seen[n])
            {
                return;
            }
            seen[n] = true;
            Node node = Nodes[n];
            if (node.Op == Op.Rep || node.Op == Op.PredRep)
            {
                node.Guard = StartSet(node.Next, 0);
            }
            SetGuards(node.Next, seen);
            SetGuards(node.Body, seen);
            foreach (int a in node.Alts)
            {
                SetGuards(a, seen);
            }
        }

        /// <summary>What a match from <paramref name="n"/> must start with, or null when it may start with anything.</summary>
        private IJsreCharTest? StartSet(int n, int depth)
        {
            if (n == None || depth > 16)
            {
                return null;
            }
            Node node = Nodes[n];
            switch (node.Op)
            {
                case Op.Rep:
                    return node.Min >= 1 ? node.Set : null;
                case Op.Alt:
                    {
                        var parts = new IJsreCharTest[node.Alts.Length];
                        for (int k = 0; k < node.Alts.Length; k++)
                        {
                            var s = StartSet(node.Alts[k], depth + 1);
                            if (s == null)
                            {
                                return null;
                            }
                            parts[k] = s;
                        }
                        return new JsreAnyOf(parts);
                    }
                // These take nothing; what follows them starts the match.
                case Op.CapOpen:
                case Op.CapClose:
                case Op.Look:
                case Op.Behind:
                case Op.WordB:
                case Op.NotWordB:
                    return StartSet(node.Next, depth + 1);
                default:
                    return null;
            }
        }
    }

    private static long Mul(long a, int m)
    {
        if (a == 0 || m == 0)
        {
            return 0;
        }
        return a > long.MaxValue / m ? long.MaxValue : a * m;
    }

    /// <summary>The least and most code units <paramref name="t"/> can take; a most of -1 is no limit.</summary>
    private static (long Lo, long Hi) WidthOf(JsreTree t)
    {
        long lo;
        long hi;
        switch (t.Kind)
        {
            case JsreKind.Char:
                lo = 1;
                hi = 1;
                break;
            case JsreKind.Seq:
                lo = 0;
                hi = 0;
                foreach (var c in t.Children)
                {
                    var w = WidthOf(c);
                    lo = Math.Min(long.MaxValue / 2, lo + w.Lo);
                    hi = hi < 0 || w.Hi < 0 ? -1 : Math.Min(long.MaxValue / 2, hi + w.Hi);
                }
                break;
            case JsreKind.Alt:
                lo = long.MaxValue;
                hi = 0;
                foreach (var c in t.Children)
                {
                    var w = WidthOf(c);
                    lo = Math.Min(lo, w.Lo);
                    hi = hi < 0 || w.Hi < 0 ? -1 : Math.Max(hi, w.Hi);
                }
                if (t.Children.Count == 0)
                {
                    lo = 0;
                }
                break;
            case JsreKind.Group:
                (lo, hi) = WidthOf(t.Children[0]);
                break;
            default:
                // Assertions and lookarounds take nothing.
                return (0, 0);
        }
        // A quantified term repeats its own width.
        long qlo = Mul(lo, t.Min);
        long qhi;
        if (t.Max == JsreParser.Inf)
        {
            qhi = hi == 0 ? 0 : -1;
        }
        else
        {
            qhi = hi < 0 ? -1 : Mul(hi, t.Max);
        }
        return (qlo, qhi);
    }

    private static bool HasCapture(JsreTree t)
    {
        if (t.Kind == JsreKind.Group && t.Capture > 0)
        {
            return true;
        }
        foreach (var c in t.Children)
        {
            if (HasCapture(c))
            {
                return true;
            }
        }
        return false;
    }

    /// <summary>
    /// Adds to <paramref name="bits"/> what <paramref name="t"/> can start with, and says whether
    /// it can match without taking anything (so what follows it can start the match too).
    /// </summary>
    private static bool First(JsreTree t, ulong[] bits)
    {
        bool nullable;
        switch (t.Kind)
        {
            case JsreKind.Char:
                t.Set!.AddTo(bits);
                nullable = false;
                break;
            case JsreKind.Seq:
                nullable = true;
                foreach (var c in t.Children)
                {
                    if (!First(c, bits))
                    {
                        nullable = false;
                        break;
                    }
                }
                break;
            case JsreKind.Alt:
                nullable = false;
                foreach (var c in t.Children)
                {
                    if (First(c, bits))
                    {
                        nullable = true;
                    }
                }
                break;
            case JsreKind.Group:
                nullable = First(t.Children[0], bits);
                break;
            default:
                return true;
        }
        return nullable || t.Min == 0;
    }

    // ---- matching

    /// <summary>Whether the pattern matches anywhere in <paramref name="text"/>, with no step budget.</summary>
    public bool Test(string text) => new Matcher(this, text, long.MaxValue).Exec(0);

    /// <summary>
    /// Whether the pattern matches anywhere in <paramref name="text"/>, within
    /// <see cref="MaxSteps"/> steps and <see cref="MaxDepth"/> frames, or null when the match
    /// gave up: a stored expect pattern then does not match.
    /// </summary>
    public bool? TryTest(string text) => TryTest(text, MaxSteps);

    /// <summary><see cref="TryTest(string)"/> within a budget of the caller's.</summary>
    public bool? TryTest(string text, long budget)
    {
        var m = new Matcher(this, text, budget);
        bool found = m.Exec(0);
        return m.GaveUp ? null : found;
    }

    /// <summary>
    /// <c>String.prototype.replace</c> with a replacement string: <c>$1</c> to <c>$99</c> are the
    /// groups ("" for one that did not take part), <c>$&amp;</c> the match, <c>$`</c> and
    /// <c>$'</c> what comes before and after it, <c>$$</c> a "$". Every match with the <c>g</c>
    /// flag, else the first.
    /// </summary>
    public string Replace(string text, string replacement) =>
        ReplaceWithin(text, long.MaxValue, m => Expand(replacement, m), out _);

    /// <summary><c>String.prototype.replace</c> with a function of each match.</summary>
    public string Replace(string text, Func<JsreMatch, string> replacement) =>
        ReplaceWithin(text, long.MaxValue, replacement, out _);

    /// <summary>
    /// <see cref="Replace(string, string)"/> within <see cref="MaxSteps"/>, or null when a match
    /// gave up: an arbitrary pattern's replacement, for the property that it always ends.
    /// </summary>
    public string? TryReplace(string text, string replacement)
    {
        string output = ReplaceWithin(text, MaxSteps, m => Expand(replacement, m), out bool gaveUp);
        return gaveUp ? null : output;
    }

    private string ReplaceWithin(string text, long budget, Func<JsreMatch, string> f, out bool gaveUp)
    {
        var m = new Matcher(this, text, budget);
        StringBuilder? b = null;
        int last = 0;
        int pos = 0;
        while (pos <= text.Length && m.Exec(pos))
        {
            int s = m.Caps[0];
            int e = m.Caps[1];
            b ??= new StringBuilder(text.Length);
            b.Append(text, last, s - last);
            b.Append(f(new JsreMatch(text, (int[])m.Caps.Clone())));
            last = e;
            pos = e == s ? e + 1 : e;
            if (!_global)
            {
                break;
            }
        }
        gaveUp = m.GaveUp;
        if (b == null)
        {
            return text;
        }
        b.Append(text, last, text.Length - last);
        return b.ToString();
    }

    private static string Expand(string template, JsreMatch m)
    {
        var b = new StringBuilder(template.Length);
        int n = template.Length;
        int groups = m.Groups;
        int k = 0;
        while (k < n)
        {
            char c = template[k];
            if (c != '$' || k + 1 >= n)
            {
                b.Append(c);
                k++;
                continue;
            }
            char d = template[k + 1];
            if (d == '$')
            {
                b.Append('$');
                k += 2;
            }
            else if (d == '&')
            {
                b.Append(m.Text(0));
                k += 2;
            }
            else if (d == '`')
            {
                b.Append(m.Before);
                k += 2;
            }
            else if (d == '\'')
            {
                b.Append(m.After);
                k += 2;
            }
            else if (d >= '0' && d <= '9')
            {
                int group = d - '0';
                int used = 1;
                if (k + 2 < n && template[k + 2] >= '0' && template[k + 2] <= '9')
                {
                    int two = group * 10 + (template[k + 2] - '0');
                    if (two >= 1 && two < groups)
                    {
                        group = two;
                        used = 2;
                    }
                }
                if (group < 1 || group >= groups)
                {
                    b.Append(c);
                    k++;
                    continue;
                }
                b.Append(m.Text(group));
                k += 1 + used;
            }
            else
            {
                b.Append(c);
                k++;
            }
        }
        return b.ToString();
    }

    /// <summary>The pattern as JavaScript writes it: <c>/source/flags</c>.</summary>
    public override string ToString() => "/" + _source + "/" + _flags;

    /// <summary>The state of one search.</summary>
    private sealed class Matcher
    {
        private readonly JsRegex _re;
        private readonly Node[] _nodes;
        private readonly string _input;
        private readonly int _len;
        public readonly int[] Caps;
        private readonly int[] _loopCount;
        private readonly int[] _loopStart;
        private int _end = -1;
        private int _target;
        private int _depth;
        private long _steps;
        public bool GaveUp;

        public Matcher(JsRegex re, string input, long budget)
        {
            _re = re;
            _nodes = re._nodes;
            _input = input;
            _len = input.Length;
            Caps = new int[2 * (re._captures + 1)];
            _loopCount = new int[re._loops];
            _loopStart = new int[re._loops];
            _steps = budget;
        }

        /// <summary>Finds the first match starting at or after <paramref name="from"/>.</summary>
        public bool Exec(int from)
        {
            ulong[]? first = _re._first;
            for (int s = from; s <= _len; s++)
            {
                if (first != null)
                {
                    if (s == _len)
                    {
                        return false;
                    }
                    char c = _input[s];
                    if ((first[c >> 6] & (1UL << (c & 63))) == 0)
                    {
                        continue;
                    }
                }
                Array.Fill(Caps, -1);
                _end = -1;
                if (Run(_re._start, s))
                {
                    Caps[0] = s;
                    Caps[1] = _end;
                    return true;
                }
                if (GaveUp)
                {
                    return false;
                }
            }
            return false;
        }

        private static bool IsWord(char c) =>
            (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '_';

        private bool WordAt(int i) => i >= 0 && i < _len && IsWord(_input[i]);

        private bool Guarded(Node n, int at)
        {
            var g = n.Guard;
            return g == null || (at < _len && g.Has(_input[at]));
        }

        /// <summary>
        /// Whether the chain from <paramref name="n"/> matches at <paramref name="pos"/>, leaving
        /// captures and the end set when it does. Past <see cref="MaxDepth"/>, or out of steps,
        /// the match gives up: this and every call after it answers false, and
        /// <see cref="GaveUp"/> is set.
        /// </summary>
        private bool Run(int n, int pos)
        {
            if (GaveUp)
            {
                return false;
            }
            if (_depth >= MaxDepth || _steps <= 0)
            {
                GaveUp = true;
                return false;
            }
            _depth++;
            _steps--;
            bool matched = RunChain(n, pos);
            _depth--;
            return matched;
        }

        private int Limit(Node node, int pos)
        {
            int limit = _len - pos;
            return node.Max == JsreParser.Inf ? limit : Math.Min(limit, node.Max);
        }

        private bool RunChain(int n, int pos)
        {
            while (true)
            {
                Node node = _nodes[n];
                switch (node.Op)
                {
                    case Op.Rep:
                        {
                            JsreCharSet set = node.Set!;
                            int limit = Limit(node, pos);
                            int k = 0;
                            while (k < limit && set.Has(_input[pos + k]))
                            {
                                k++;
                            }
                            _steps -= k;
                            if (k < node.Min)
                            {
                                return false;
                            }
                            if (k == node.Min)
                            {
                                pos += k;
                                n = node.Next;
                                continue;
                            }
                            for (int i = k; ; i--)
                            {
                                if (Guarded(node, pos + i) && Run(node.Next, pos + i))
                                {
                                    return true;
                                }
                                if (i == node.Min)
                                {
                                    return false;
                                }
                            }
                        }
                    case Op.PredRep:
                        {
                            int limit = Limit(node, pos);
                            int saved = _end;
                            int k = 0;
                            while (k < limit && Run(node.Body, pos + k) && _end == pos + k + 1)
                            {
                                k++;
                            }
                            _end = saved;
                            if (k < node.Min)
                            {
                                return false;
                            }
                            for (int i = k; ; i--)
                            {
                                if (Guarded(node, pos + i) && Run(node.Next, pos + i))
                                {
                                    return true;
                                }
                                if (i == node.Min)
                                {
                                    return false;
                                }
                            }
                        }
                    case Op.Alt:
                        {
                            int[] alts = node.Alts;
                            for (int a = 0; a < alts.Length - 1; a++)
                            {
                                if (Run(alts[a], pos))
                                {
                                    return true;
                                }
                            }
                            n = alts[^1];
                            break;
                        }
                    case Op.CapOpen:
                        {
                            int i = 2 * node.Index;
                            int oldStart = Caps[i];
                            int oldEnd = Caps[i + 1];
                            Caps[i] = pos;
                            if (Run(node.Next, pos))
                            {
                                return true;
                            }
                            Caps[i] = oldStart;
                            Caps[i + 1] = oldEnd;
                            return false;
                        }
                    case Op.CapClose:
                        {
                            int i = 2 * node.Index + 1;
                            int old = Caps[i];
                            Caps[i] = pos;
                            if (Run(node.Next, pos))
                            {
                                return true;
                            }
                            Caps[i] = old;
                            return false;
                        }
                    case Op.Loop:
                        return Iterate(n, 0, pos);
                    case Op.LoopBack:
                        {
                            int lp = node.Lp;
                            int index = _nodes[lp].Index;
                            int count = _loopCount[index];
                            int startedAt = _loopStart[index];
                            if (pos == startedAt)
                            {
                                // A pass that took nothing ends the loop without matching, as
                                // JavaScript's RepeatMatcher refuses an empty iteration.
                                return false;
                            }
                            if (Iterate(lp, count, pos))
                            {
                                return true;
                            }
                            _loopCount[index] = count;
                            _loopStart[index] = startedAt;
                            return false;
                        }
                    case Op.Look:
                        {
                            int[]? saved = node.Keep ? (int[])Caps.Clone() : null;
                            int e = _end;
                            bool ok = Run(node.Body, pos);
                            _end = e;
                            if (saved != null && (ok == node.Negate || node.Negate))
                            {
                                Array.Copy(saved, Caps, Caps.Length);
                            }
                            if (ok == node.Negate)
                            {
                                return false;
                            }
                            n = node.Next;
                            break;
                        }
                    case Op.Behind:
                        {
                            bool ok = false;
                            if (pos >= node.Width)
                            {
                                int[]? saved = node.Keep ? (int[])Caps.Clone() : null;
                                int t = _target;
                                int e = _end;
                                _target = pos;
                                ok = Run(node.Body, pos - node.Width);
                                _target = t;
                                _end = e;
                                if (saved != null && (!ok || node.Negate))
                                {
                                    Array.Copy(saved, Caps, Caps.Length);
                                }
                            }
                            if (ok == node.Negate)
                            {
                                return false;
                            }
                            n = node.Next;
                            break;
                        }
                    case Op.WordB:
                    case Op.NotWordB:
                        {
                            bool at = WordAt(pos - 1) != WordAt(pos);
                            if (at != (node.Op == Op.WordB))
                            {
                                return false;
                            }
                            n = node.Next;
                            break;
                        }
                    case Op.Start:
                        if (pos != 0)
                        {
                            return false;
                        }
                        n = node.Next;
                        break;
                    case Op.End:
                        if (pos != _len)
                        {
                            return false;
                        }
                        n = node.Next;
                        break;
                    case Op.Accept:
                        _end = pos;
                        return true;
                    default:
                        return pos == _target;
                }
            }
        }

        /// <summary>
        /// Tries one more pass of a loop that has made <paramref name="count"/> passes, then
        /// (greedy) leaving it.
        /// </summary>
        private bool Iterate(int lp, int count, int pos)
        {
            Node node = _nodes[lp];
            int count0 = _loopCount[node.Index];
            int start0 = _loopStart[node.Index];
            if (node.Max == JsreParser.Inf || count < node.Max)
            {
                _loopCount[node.Index] = count + 1;
                _loopStart[node.Index] = pos;
                if (Run(node.Body, pos))
                {
                    return true;
                }
                _loopCount[node.Index] = count0;
                _loopStart[node.Index] = start0;
            }
            if (count >= node.Min)
            {
                return Run(node.Next, pos);
            }
            return false;
        }
    }
}

/// <summary>One match: the whole match and each group.</summary>
internal sealed class JsreMatch
{
    private readonly string _input;
    private readonly int[] _caps;

    internal JsreMatch(string input, int[] caps)
    {
        _input = input;
        _caps = caps;
    }

    /// <summary>How many groups there are, the whole match counted.</summary>
    public int Groups => _caps.Length / 2;

    /// <summary>What comes before the match.</summary>
    public string Before => _input[.._caps[0]];

    /// <summary>What comes after the match.</summary>
    public string After => _input[_caps[1]..];

    /// <summary>Group <paramref name="i"/> (0 is the whole match), or null when it did not take part in the match.</summary>
    public string? Group(int i)
    {
        if (2 * i + 1 >= _caps.Length || _caps[2 * i] < 0 || _caps[2 * i + 1] < 0)
        {
            return null;
        }
        return _input[_caps[2 * i].._caps[2 * i + 1]];
    }

    /// <summary>Group <paramref name="i"/>, or "" when it did not take part.</summary>
    public string Text(int i) => Group(i) ?? "";
}
