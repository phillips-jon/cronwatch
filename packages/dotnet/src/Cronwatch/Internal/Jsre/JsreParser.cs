using System;
using System.Collections.Generic;
using System.Globalization;

namespace Cronwatch.Internal;

/// <summary>Kinds of syntax tree node.</summary>
internal enum JsreKind
{
    /// <summary>Children: the alternatives.</summary>
    Alt,

    /// <summary>Children: the terms in order.</summary>
    Seq,

    /// <summary>One code unit from the set.</summary>
    Char,

    /// <summary><c>Children[0]</c> inside; a capture above 0 captures.</summary>
    Group,

    /// <summary>Lookahead or lookbehind around <c>Children[0]</c>.</summary>
    Look,

    /// <summary><c>\b</c>.</summary>
    WordB,

    /// <summary><c>\B</c>.</summary>
    NotWordB,

    /// <summary><c>^</c>.</summary>
    Start,

    /// <summary><c>$</c>.</summary>
    End,
}

/// <summary>A node of a parsed pattern.</summary>
internal sealed class JsreTree(JsreKind kind)
{
    public JsreKind Kind = kind;
    public readonly List<JsreTree> Children = [];
    public JsreCharSet? Set;
    public int Capture;
    public bool Behind;
    public bool Negate;
    public int Min = 1;
    public int Max = 1;

    public static JsreTree OfSet(JsreCharSet set) => new(JsreKind.Char) { Set = set };

    public bool Once => Min == 1 && Max == 1;
}

/// <summary>
/// The parser: a pattern's source, in JavaScript's non-unicode syntax, as a tree. The source is
/// read as UTF-16 code units, as V8 reads a pattern without the <c>u</c> flag, so a character
/// outside the BMP is its two code units in turn: a quantifier after it takes the second alone,
/// and in a class it is two members (a range between two such characters is out of order, as V8
/// finds it).
/// </summary>
internal sealed class JsreParser
{
    /// <summary>Unbounded, as a quantifier's most.</summary>
    public const int Inf = -1;

    /// <summary>How deep groups may nest: the parser and the compiler recurse into them.</summary>
    public const int MaxNesting = 100;

    private readonly string _src;
    private readonly bool _fold;
    private int _i;
    private int _depth;
    private int _captures;

    /// <summary>Every set read, held once.</summary>
    private readonly Dictionary<JsreCharSet, JsreCharSet> _sets = [];

    private JsreParser(string src, bool fold)
    {
        _src = src;
        _fold = fold;
    }

    /// <summary>Reads a pattern's source into a tree, and counts its capturing groups.</summary>
    public static (JsreTree Tree, int Captures) Parse(string source, bool fold)
    {
        var p = new JsreParser(source, fold);
        JsreTree t = p.Disjunction();
        if (p._i < p._src.Length)
        {
            throw p.Fail("unmatched ')'");
        }
        return (t, p._captures);
    }

    private ArgumentException Fail(string what) =>
        new("jsre: " + what + " at " + _i.ToString(CultureInfo.InvariantCulture) + " in /" + _src + "/");

    private bool More => _i < _src.Length;

    private char Peek => _src[_i];

    private bool At(string s) => _i + s.Length <= _src.Length && string.CompareOrdinal(_src, _i, s, 0, s.Length) == 0;

    private JsreCharSet Intern(JsreCharSet.Builder b)
    {
        JsreCharSet s = b.Build(_fold);
        if (_sets.TryGetValue(s, out var held))
        {
            return held;
        }
        _sets[s] = s;
        return s;
    }

    private JsreTree Disjunction()
    {
        var alt = new JsreTree(JsreKind.Alt);
        while (true)
        {
            alt.Children.Add(Alternative());
            if (More && Peek == '|')
            {
                _i++;
                continue;
            }
            break;
        }
        return alt.Children.Count == 1 ? alt.Children[0] : alt;
    }

    private JsreTree Alternative()
    {
        var seq = new JsreTree(JsreKind.Seq);
        while (More && Peek != '|' && Peek != ')')
        {
            seq.Children.Add(Term());
        }
        return seq;
    }

    private JsreTree Term()
    {
        char c = Peek;
        JsreTree t;
        switch (c)
        {
            case '^':
                _i++;
                return new JsreTree(JsreKind.Start);
            case '$':
                _i++;
                return new JsreTree(JsreKind.End);
            case '(':
                {
                    _i++;
                    var g = new JsreTree(JsreKind.Group);
                    if (At("?:"))
                    {
                        _i += 2;
                    }
                    else if (At("?=") || At("?!"))
                    {
                        g.Kind = JsreKind.Look;
                        g.Negate = _src[_i + 1] == '!';
                        _i += 2;
                    }
                    else if (At("?<=") || At("?<!"))
                    {
                        g.Kind = JsreKind.Look;
                        g.Behind = true;
                        g.Negate = _src[_i + 2] == '!';
                        _i += 3;
                    }
                    else if (At("?"))
                    {
                        throw Fail("unsupported group");
                    }
                    else
                    {
                        _captures++;
                        g.Capture = _captures;
                    }
                    _depth++;
                    if (_depth > MaxNesting)
                    {
                        throw Fail("groups nested too deeply");
                    }
                    JsreTree inner = Disjunction();
                    _depth--;
                    if (!More || Peek != ')')
                    {
                        throw Fail("missing ')'");
                    }
                    _i++;
                    g.Children.Add(inner);
                    if (g.Kind == JsreKind.Look && g.Behind)
                    {
                        // A lookbehind cannot be quantified.
                        if (More && IsQuantifier())
                        {
                            throw Fail("a lookbehind cannot be quantified");
                        }
                        return g;
                    }
                    t = g;
                    break;
                }
            case '[':
                _i++;
                t = JsreTree.OfSet(Klass());
                break;
            case '.':
                _i++;
                t = JsreTree.OfSet(Intern(new JsreCharSet.Builder().AddAll(JsreCharSet.Dot)));
                break;
            case '\\':
                {
                    _i++;
                    if (!More)
                    {
                        throw Fail("\\ at end of pattern");
                    }
                    if (Peek == 'b')
                    {
                        _i++;
                        return new JsreTree(JsreKind.WordB);
                    }
                    if (Peek == 'B')
                    {
                        _i++;
                        return new JsreTree(JsreKind.NotWordB);
                    }
                    var b = new JsreCharSet.Builder();
                    Escape(b);
                    t = JsreTree.OfSet(Intern(b));
                    break;
                }
            case '*':
            case '+':
            case '?':
                throw Fail("nothing to repeat");
            case ')':
                throw Fail("unmatched ')'");
            default:
                _i++;
                t = JsreTree.OfSet(Intern(new JsreCharSet.Builder().Add(c)));
                break;
        }
        return Quantifier(t);
    }

    private bool IsQuantifier()
    {
        char c = Peek;
        return c == '*' || c == '+' || c == '?' || (c == '{' && Brace() != null);
    }

    /// <summary>A number of a quantifier, held at <see cref="int.MaxValue"/>, as no input is that long.</summary>
    private static int Bounded(string digits) =>
        digits.Length > 9 ? int.MaxValue : int.Parse(digits, NumberStyles.None, CultureInfo.InvariantCulture);

    private static bool IsDigit(char c) => c >= '0' && c <= '9';

    /// <summary>
    /// Reads a bounded quantifier ("{n}", "{n,}" or "{n,m}") at the parser's position: the bounds
    /// and the index after its closing brace, or null when the opening brace is a literal (Annex B).
    /// </summary>
    private (int Min, int Max, int After)? Brace()
    {
        int j = _i + 1;
        int start = j;
        while (j < _src.Length && IsDigit(_src[j]))
        {
            j++;
        }
        if (j == start)
        {
            return null;
        }
        int n = Bounded(StripZeros(_src[start..j]));
        int m = n;
        if (j < _src.Length && _src[j] == ',')
        {
            j++;
            if (j < _src.Length && _src[j] == '}')
            {
                m = Inf;
            }
            else
            {
                int from = j;
                while (j < _src.Length && IsDigit(_src[j]))
                {
                    j++;
                }
                if (j == from)
                {
                    return null;
                }
                m = Bounded(StripZeros(_src[from..j]));
            }
        }
        if (j >= _src.Length || _src[j] != '}')
        {
            return null;
        }
        return (n, m, j + 1);
    }

    private static string StripZeros(string digits)
    {
        int k = 0;
        while (k < digits.Length - 1 && digits[k] == '0')
        {
            k++;
        }
        return digits[k..];
    }

    private JsreTree Quantifier(JsreTree t)
    {
        if (!More)
        {
            return t;
        }
        int lo;
        int hi;
        switch (Peek)
        {
            case '*':
                _i++;
                lo = 0;
                hi = Inf;
                break;
            case '+':
                _i++;
                lo = 1;
                hi = Inf;
                break;
            case '?':
                _i++;
                lo = 0;
                hi = 1;
                break;
            case '{':
                {
                    var b = Brace();
                    if (b == null)
                    {
                        return t;
                    }
                    if (b.Value.Max != Inf && b.Value.Max < b.Value.Min)
                    {
                        throw Fail("numbers out of order in {} quantifier");
                    }
                    _i = b.Value.After;
                    lo = b.Value.Min;
                    hi = b.Value.Max;
                    break;
                }
            default:
                return t;
        }
        if (More && Peek == '?')
        {
            throw Fail("lazy quantifiers are not supported");
        }
        // A quantified term is wrapped, so its own min and max stay 1.
        JsreTree q = t;
        if (!t.Once)
        {
            q = new JsreTree(JsreKind.Group);
            q.Children.Add(t);
        }
        q.Min = lo;
        q.Max = hi;
        return q;
    }

    private JsreCharSet Klass()
    {
        var set = new JsreCharSet.Builder();
        if (More && Peek == '^')
        {
            set.Negate = true;
            _i++;
        }
        while (true)
        {
            if (!More)
            {
                throw Fail("missing ']'");
            }
            if (Peek == ']')
            {
                _i++;
                break;
            }
            int lo = ClassAtom(set);
            // A range a-b, unless "-" ends the class or either end is a class escape such as \s
            // (then "-" is literal, as Annex B reads it).
            if (_i + 1 < _src.Length && Peek == '-' && _src[_i + 1] != ']')
            {
                int save = _i;
                _i++;
                var probe = new JsreCharSet.Builder();
                int hi = ClassAtom(probe);
                if (lo >= 0 && hi >= 0)
                {
                    if (hi < lo)
                    {
                        throw Fail("range out of order in character class");
                    }
                    set.AddRange(lo, hi);
                    continue;
                }
                // Not a range: the "-" and what follows are members on their own.
                if (lo >= 0)
                {
                    set.Add(lo);
                }
                set.Add('-');
                _i = save + 1;
                continue;
            }
            if (lo >= 0)
            {
                set.Add(lo);
            }
        }
        return Intern(set);
    }

    /// <summary>
    /// Reads one member of a class: a character (returned), or a class escape added to
    /// <paramref name="set"/> (-1).
    /// </summary>
    private int ClassAtom(JsreCharSet.Builder set)
    {
        char c = Peek;
        if (c != '\\')
        {
            _i++;
            return c;
        }
        _i++;
        if (!More)
        {
            throw Fail("\\ at end of pattern");
        }
        if (Peek == 'b')
        {
            _i++;
            return 0x08;
        }
        var single = new JsreCharSet.Builder();
        Escape(single);
        int r = single.Single();
        if (r >= 0)
        {
            return r;
        }
        set.Union(single);
        return -1;
    }

    private static int HexDigit(char c) =>
        c >= '0' && c <= '9' ? c - '0' : c >= 'a' && c <= 'f' ? c - 'a' + 10 : c >= 'A' && c <= 'F' ? c - 'A' + 10 : -1;

    /// <summary>Reads what follows a backslash into <paramref name="set"/>.</summary>
    private void Escape(JsreCharSet.Builder set)
    {
        char c = Peek;
        _i++;
        switch (c)
        {
            case 'd':
                set.AddAll(JsreCharSet.Digit);
                break;
            case 'D':
                set.AddAll(JsreCharSet.Complement(JsreCharSet.Digit));
                break;
            case 'w':
                set.AddAll(JsreCharSet.Word);
                break;
            case 'W':
                set.AddAll(JsreCharSet.Complement(JsreCharSet.Word));
                break;
            case 's':
                set.AddAll(JsreCharSet.Space);
                break;
            case 'S':
                set.AddAll(JsreCharSet.Complement(JsreCharSet.Space));
                break;
            case 'n':
                set.Add('\n');
                break;
            case 't':
                set.Add('\t');
                break;
            case 'r':
                set.Add('\r');
                break;
            case 'f':
                set.Add(0x0c);
                break;
            case 'v':
                set.Add(0x0b);
                break;
            case '0':
                // \0 then a digit is a legacy octal escape in JavaScript, read as something else here.
                if (More && IsDigit(Peek))
                {
                    throw new ArgumentException("jsre: \\0 followed by a digit is not supported");
                }
                set.Add(0);
                break;
            case '1':
            case '2':
            case '3':
            case '4':
            case '5':
            case '6':
            case '7':
            case '8':
            case '9':
            case 'c':
            case 'k':
            case 'p':
            case 'P':
                // JavaScript reads these as a backreference, a control character, a named
                // backreference or a property; read as the plain letter they would match
                // something else, so they are refused.
                throw new ArgumentException("jsre: \\" + c + " is not supported");
            case 'x':
            case 'u':
                {
                    int width = c == 'u' ? 4 : 2;
                    if (c == 'u' && More && Peek == '{')
                    {
                        throw new ArgumentException("jsre: \\u{...} is not supported");
                    }
                    if (_i + width <= _src.Length)
                    {
                        int n = 0;
                        bool hex = true;
                        for (int k = 0; k < width; k++)
                        {
                            int d = HexDigit(_src[_i + k]);
                            if (d < 0)
                            {
                                hex = false;
                                break;
                            }
                            n = n * 16 + d;
                        }
                        if (hex)
                        {
                            _i += width;
                            set.Add(n);
                            return;
                        }
                    }
                    set.Add(c);
                    break;
                }
            default:
                set.Add(c);
                break;
        }
    }
}
