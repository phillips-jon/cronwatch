using System;
using System.Collections.Generic;

namespace Cronwatch.Internal;

/// <summary>What a code unit must be at some point of a match: a set, or the union of several.</summary>
internal interface IJsreCharTest
{
    /// <summary>Whether <paramref name="c"/> is one.</summary>
    bool Has(char c);
}

/// <summary>The union of several tests.</summary>
internal sealed class JsreAnyOf(IJsreCharTest[] parts) : IJsreCharTest
{
    public bool Has(char c)
    {
        foreach (var p in parts)
        {
            if (p.Has(c))
            {
                return true;
            }
        }
        return false;
    }
}

/// <summary>
/// A set of UTF-16 code units, held as its sorted ranges so a set costs a few integers however
/// many characters it holds (the Elixir audit: a set held as a bitmap per character made a long
/// pattern some 130 MB). A set built with the <c>i</c> flag matches a code unit when any member
/// has the same canonical form, as JavaScript's Canonicalize reads it without the <c>u</c> flag;
/// a negated set answers the opposite, after folding, as JavaScript's CharacterSetMatcher does.
/// </summary>
internal sealed class JsreCharSet : IJsreCharTest, IEquatable<JsreCharSet>
{
    private readonly int[] _ranges;
    private readonly bool _negate;
    private readonly bool _fold;

    private JsreCharSet(int[] ranges, bool negate, bool fold)
    {
        _ranges = ranges;
        _negate = negate;
        _fold = fold;
    }

    /// <summary>Whether the set's own ranges hold <paramref name="c"/>, before folding and negation.</summary>
    private bool Raw(char c)
    {
        int lo = 0;
        int hi = _ranges.Length / 2 - 1;
        while (lo <= hi)
        {
            int mid = (lo + hi) >>> 1;
            if (c < _ranges[2 * mid])
            {
                hi = mid - 1;
            }
            else if (c > _ranges[2 * mid + 1])
            {
                lo = mid + 1;
            }
            else
            {
                return true;
            }
        }
        return false;
    }

    public bool Has(char c)
    {
        bool inSet = Raw(c);
        if (!inSet && _fold)
        {
            char[]? same = JsreCanonical.Equivalents(c);
            if (same != null)
            {
                foreach (char x in same)
                {
                    if (Raw(x))
                    {
                        inSet = true;
                        break;
                    }
                }
            }
        }
        return inSet != _negate;
    }

    /// <summary>Adds every code unit the set holds to a bitmap of the whole range.</summary>
    public void AddTo(ulong[] bits)
    {
        if (!_negate && !_fold)
        {
            for (int i = 0; i < _ranges.Length; i += 2)
            {
                for (int c = _ranges[i]; c <= _ranges[i + 1]; c++)
                {
                    bits[c >> 6] |= 1UL << (c & 63);
                }
            }
            return;
        }
        for (int c = 0; c <= 0xffff; c++)
        {
            if (Has((char)c))
            {
                bits[c >> 6] |= 1UL << (c & 63);
            }
        }
    }

    public bool Equals(JsreCharSet? other) =>
        other != null && other._negate == _negate && other._fold == _fold && other._ranges.AsSpan().SequenceEqual(_ranges);

    public override bool Equals(object? obj) => obj is JsreCharSet s && Equals(s);

    public override int GetHashCode()
    {
        var h = new HashCode();
        foreach (int r in _ranges)
        {
            h.Add(r);
        }
        h.Add(_negate);
        h.Add(_fold);
        return h.ToHashCode();
    }

    /// <summary>A set being read from a pattern: ranges added in any order, merged when it is built.</summary>
    internal sealed class Builder
    {
        private int[] _buf = new int[8];
        private int _n;

        public bool Negate { get; set; }

        /// <summary>Adds one code unit.</summary>
        public Builder Add(int c) => AddRange(c, c);

        /// <summary>Adds the code units from <paramref name="lo"/> to <paramref name="hi"/>, both included.</summary>
        public Builder AddRange(int lo, int hi)
        {
            if (_n + 2 > _buf.Length)
            {
                Array.Resize(ref _buf, _buf.Length * 2);
            }
            _buf[_n++] = lo;
            _buf[_n++] = hi;
            return this;
        }

        /// <summary>Adds sorted ranges, as <see cref="Complement"/> and the constants below give them.</summary>
        public Builder AddAll(int[] ranges)
        {
            for (int i = 0; i < ranges.Length; i += 2)
            {
                AddRange(ranges[i], ranges[i + 1]);
            }
            return this;
        }

        /// <summary>Adds every member of another builder (its negation is not carried).</summary>
        public Builder Union(Builder o) => AddAll(o.Normalized());

        /// <summary>The ranges sorted and merged.</summary>
        public int[] Normalized()
        {
            int count = _n / 2;
            var pairs = new long[count];
            for (int i = 0; i < count; i++)
            {
                pairs[i] = ((long)_buf[2 * i] << 32) | (uint)_buf[2 * i + 1];
            }
            Array.Sort(pairs);
            var output = new int[_n];
            int m = 0;
            foreach (long p in pairs)
            {
                int lo = (int)(p >>> 32);
                int hi = (int)p;
                if (m > 0 && lo <= output[m - 1] + 1)
                {
                    output[m - 1] = Math.Max(output[m - 1], hi);
                }
                else
                {
                    output[m++] = lo;
                    output[m++] = hi;
                }
            }
            Array.Resize(ref output, m);
            return output;
        }

        /// <summary>The one code unit a set of exactly one plain member holds, or -1.</summary>
        public int Single()
        {
            if (Negate)
            {
                return -1;
            }
            int[] r = Normalized();
            return r.Length == 2 && r[0] == r[1] ? r[0] : -1;
        }

        /// <summary>The set, folded when the pattern has the <c>i</c> flag.</summary>
        public JsreCharSet Build(bool fold) => new(Normalized(), Negate, fold);
    }

    /// <summary>The code units not in these sorted, merged ranges.</summary>
    public static int[] Complement(int[] ranges)
    {
        var output = new int[ranges.Length + 2];
        int m = 0;
        int from = 0;
        for (int i = 0; i < ranges.Length; i += 2)
        {
            if (ranges[i] > from)
            {
                output[m++] = from;
                output[m++] = ranges[i] - 1;
            }
            from = ranges[i + 1] + 1;
        }
        if (from <= 0xffff)
        {
            output[m++] = from;
            output[m++] = 0xffff;
        }
        Array.Resize(ref output, m);
        return output;
    }

    /// <summary><c>\d</c>.</summary>
    public static readonly int[] Digit = ['0', '9'];

    /// <summary><c>\w</c>: ASCII letters, digits, and underscore, whatever the flags.</summary>
    public static readonly int[] Word = ['0', '9', 'A', 'Z', '_', '_', 'a', 'z'];

    /// <summary>JavaScript's <c>\s</c>: WhiteSpace and LineTerminator.</summary>
    public static readonly int[] Space =
    [
        0x09, 0x0d, 0x20, 0x20, 0xa0, 0xa0, 0x1680, 0x1680, 0x2000, 0x200a, 0x2028, 0x2029, 0x202f,
        0x202f, 0x205f, 0x205f, 0x3000, 0x3000, 0xfeff, 0xfeff,
    ];

    /// <summary><c>.</c>: everything but a line terminator.</summary>
    public static readonly int[] Dot = Complement([0x0a, 0x0a, 0x0d, 0x0d, 0x2028, 0x2029]);
}

/// <summary>
/// JavaScript's Canonicalize without the <c>u</c> flag: a code unit's upper case when that is
/// one code unit, unless it maps a character outside ASCII onto one inside it, so the long s
/// (U+017F) never matches "s" and the Kelvin sign never matches "k". Read from
/// <see cref="JsreCanonicalTable"/>, Node's own answers, not from .NET's case mapping.
/// </summary>
internal static class JsreCanonical
{
    private static readonly char[]?[] EquivalentsTable = Build();

    /// <summary>Every other code unit with the same canonical form as <paramref name="c"/>, or null when none.</summary>
    public static char[]? Equivalents(char c) => EquivalentsTable[c];

    /// <summary>Every code unit's canonical form.</summary>
    public static char[] CanonicalForms()
    {
        var canon = new char[0x10000];
        for (int c = 0; c <= 0xffff; c++)
        {
            canon[c] = (char)c;
        }
        int[] runs = JsreCanonicalTable.Runs;
        for (int r = 0; r < runs.Length; r += 4)
        {
            int first = runs[r];
            int count = runs[r + 1];
            int step = runs[r + 2];
            int delta = runs[r + 3];
            for (int k = 0; k < count; k++)
            {
                int c = first + k * step;
                canon[c] = (char)(c + delta);
            }
        }
        return canon;
    }

    private static char[]?[] Build()
    {
        char[] canon = CanonicalForms();
        var members = new Dictionary<char, List<char>>();
        for (int c = 0; c <= 0xffff; c++)
        {
            if (!members.TryGetValue(canon[c], out var list))
            {
                list = [];
                members[canon[c]] = list;
            }
            list.Add((char)c);
        }
        var output = new char[]?[0x10000];
        for (int c = 0; c <= 0xffff; c++)
        {
            var m = members[canon[c]];
            if (m.Count > 1)
            {
                var others = new char[m.Count - 1];
                int j = 0;
                foreach (char x in m)
                {
                    if (x != c)
                    {
                        others[j++] = x;
                    }
                }
                output[c] = others;
            }
        }
        return output;
    }
}
