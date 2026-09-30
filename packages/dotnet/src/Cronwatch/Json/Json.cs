using System;
using System.Collections;
using System.Collections.Generic;
using System.Globalization;
using System.Text;
using Cronwatch.Internal;

namespace Cronwatch;

/// <summary>
/// Why text is not JSON, with <c>JSON.parse</c>'s wording and the position in UTF-16 units, or why a
/// JSON value is not the record it was read as. Named apart from <c>System.Text.Json.JsonException</c>,
/// so an app importing both namespaces can name either.
/// </summary>
public sealed class JsonParseException : Exception
{
    /// <summary>An error with no message.</summary>
    public JsonParseException()
    {
    }

    /// <summary>An error with this message.</summary>
    public JsonParseException(string message)
        : base(message)
    {
    }

    /// <summary>An error with this message and cause.</summary>
    public JsonParseException(string message, Exception inner)
        : base(message, inner)
    {
    }
}

/// <summary>
/// <c>JSON.stringify</c> and <c>JSON.parse</c>, byte for byte, for everything CronWatch writes to a
/// store or reads from one, so a .NET process and a Node, Ruby, Python, PHP, Go, Rust, Elixir or
/// Java process can share one database.
/// </summary>
/// <remarks>
/// Numbers are written as JavaScript prints them (<c>2</c>, not <c>2.0</c>; <c>1e-7</c>;
/// <c>1e+21</c>), a number that is not finite as <c>null</c>, and a <c>long</c> beyond 2^53 as the
/// double JavaScript would hold. Strings escape only control characters, quotes and backslashes,
/// and a lone surrogate as <c>\ud83d</c>, as a well-formed <c>JSON.stringify</c> does. Objects
/// keep JavaScript's key order (see <see cref="JsObject"/>).
/// </remarks>
public static class Json
{
    /// <summary>
    /// How deep arrays and objects may nest. The reader and writer recurse, so text nested
    /// thousands deep (a request body, a stored row) would overflow a thread's stack; nothing
    /// CronWatch or an app stores comes near this.
    /// </summary>
    public const int MaxDepth = 256;

    /// <summary>
    /// <c>JSON.stringify</c> of a value: <c>null</c>, a <see cref="bool"/>, a number, a
    /// <see cref="string"/>, a list, a <see cref="JsObject"/> or a dictionary with string keys
    /// (written in its enumeration order, array-index keys first, as JavaScript orders them).
    /// </summary>
    /// <exception cref="ArgumentException">For a value of any other type.</exception>
    public static string Stringify(object? value)
    {
        var b = new StringBuilder();
        Write(b, value, 0);
        return b.ToString();
    }

    private static void Write(StringBuilder b, object? v, int depth)
    {
        if (depth > MaxDepth)
        {
            throw new ArgumentException("JSON nested too deeply");
        }
        switch (v)
        {
            case null:
                b.Append("null");
                break;
            case bool x:
                b.Append(x ? "true" : "false");
                break;
            case double d:
                b.Append(double.IsFinite(d) ? Js.FormatNumber(d) : "null");
                break;
            case float f:
                b.Append(float.IsFinite(f) ? Js.FormatNumber(f) : "null");
                break;
            case long l:
                b.Append(Js.FormatLong(l));
                break;
            case int i:
                b.Append(i.ToString(CultureInfo.InvariantCulture));
                break;
            case short s:
                b.Append(s.ToString(CultureInfo.InvariantCulture));
                break;
            case byte y:
                b.Append(y.ToString(CultureInfo.InvariantCulture));
                break;
            case uint ui:
                b.Append(ui.ToString(CultureInfo.InvariantCulture));
                break;
            case decimal m:
                b.Append(Js.FormatNumber((double)m));
                break;
            case string s:
                QuoteInto(b, s);
                break;
            case JsObject o:
                {
                    b.Append('{');
                    bool first = true;
                    foreach (var e in o)
                    {
                        if (!first)
                        {
                            b.Append(',');
                        }
                        first = false;
                        QuoteInto(b, e.Key);
                        b.Append(':');
                        Write(b, e.Value, depth + 1);
                    }
                    b.Append('}');
                    break;
                }
            case IEnumerable<KeyValuePair<string, object?>> map:
                {
                    var o = new JsObject();
                    foreach (var e in map)
                    {
                        o.Set(e.Key, e.Value);
                    }
                    Write(b, o, depth);
                    break;
                }
            case IDictionary dict:
                {
                    var o = new JsObject();
                    foreach (DictionaryEntry e in dict)
                    {
                        o.Set(Convert.ToString(e.Key, CultureInfo.InvariantCulture) ?? "", e.Value);
                    }
                    Write(b, o, depth);
                    break;
                }
            case IEnumerable list:
                {
                    b.Append('[');
                    bool first = true;
                    foreach (var x in list)
                    {
                        if (!first)
                        {
                            b.Append(',');
                        }
                        first = false;
                        Write(b, x, depth + 1);
                    }
                    b.Append(']');
                    break;
                }
            default:
                throw new ArgumentException("cannot write a " + v.GetType().Name + " as JSON");
        }
    }

    /// <summary>A deep copy of a JSON value: nested objects and lists are copied, the rest is immutable.</summary>
    public static object? Copy(object? value) => JsObject.CopyValue(value);

    /// <summary><c>JSON.stringify</c> of a string.</summary>
    public static string Quote(string s)
    {
        var b = new StringBuilder(s.Length + 2);
        QuoteInto(b, s);
        return b.ToString();
    }

    private const string Hex = "0123456789abcdef";

    private static void QuoteInto(StringBuilder b, string s)
    {
        b.Append('"');
        int n = s.Length;
        int start = 0;
        for (int i = 0; i < n; i++)
        {
            char c = s[i];
            if (c >= 0x20 && c != '"' && c != '\\' && !char.IsSurrogate(c))
            {
                continue;
            }
            if (char.IsHighSurrogate(c) && i + 1 < n && char.IsLowSurrogate(s[i + 1]))
            {
                i++;
                continue;
            }
            b.Append(s, start, i - start);
            switch (c)
            {
                case '"':
                    b.Append("\\\"");
                    break;
                case '\\':
                    b.Append("\\\\");
                    break;
                case '\b':
                    b.Append("\\b");
                    break;
                case '\f':
                    b.Append("\\f");
                    break;
                case '\n':
                    b.Append("\\n");
                    break;
                case '\r':
                    b.Append("\\r");
                    break;
                case '\t':
                    b.Append("\\t");
                    break;
                default:
                    b.Append("\\u").Append(Hex[(c >> 12) & 0xf]).Append(Hex[(c >> 8) & 0xf])
                        .Append(Hex[(c >> 4) & 0xf]).Append(Hex[c & 0xf]);
                    break;
            }
            start = i + 1;
        }
        b.Append(s, start, n - start);
        b.Append('"');
    }

    /// <summary>
    /// <c>JSON.parse</c>: numbers as <see cref="double"/>, objects as <see cref="JsObject"/> in
    /// JavaScript's key order (a key given twice keeps its first place and its last value), arrays
    /// as <c>List&lt;object?&gt;</c>. A lone surrogate escape (<c>\ud800</c>) is kept, as JavaScript
    /// keeps it. Arrays and objects nested more than <see cref="MaxDepth"/> deep are refused.
    /// </summary>
    /// <exception cref="JsonParseException">When the text is not JSON.</exception>
    public static object? Parse(string text)
    {
        var p = new Parser(text);
        p.Space();
        object? v = p.Value(0);
        p.Space();
        if (p.I < text.Length)
        {
            throw p.Fail("Unexpected non-whitespace character after JSON");
        }
        return v;
    }

    /// <summary><see cref="Parse"/> of text that must be an object.</summary>
    /// <exception cref="JsonParseException">When the text is not JSON or not an object.</exception>
    public static JsObject ParseObject(string text)
    {
        object? v = Parse(text);
        if (v is JsObject o)
        {
            return o;
        }
        throw new JsonParseException("expected a JSON object, not " + Kind(v));
    }

    /// <summary>A value's type as JavaScript's <c>typeof</c> names it, for messages.</summary>
    public static string Kind(object? v) => v switch
    {
        null => "null",
        bool => "boolean",
        double or float or long or int or short or byte or uint or decimal => "number",
        string => "string",
        _ => "object",
    };

    /// <summary>Whether a value is a JSON number, and which.</summary>
    public static bool TryNumber(object? v, out double n)
    {
        switch (v)
        {
            case double d:
                n = d;
                return true;
            case long l:
                n = l;
                return true;
            case int i:
                n = i;
                return true;
            case float f:
                n = f;
                return true;
            case short s:
                n = s;
                return true;
            case byte y:
                n = y;
                return true;
            case uint u:
                n = u;
                return true;
            case decimal m:
                n = (double)m;
                return true;
            default:
                n = 0;
                return false;
        }
    }

    private sealed class Parser(string s)
    {
        public int I;

        public JsonParseException Fail(string what) =>
            new(what + " at position " + I.ToString(CultureInfo.InvariantCulture));

        public void Space()
        {
            while (I < s.Length)
            {
                char c = s[I];
                if (c != ' ' && c != '\t' && c != '\n' && c != '\r')
                {
                    return;
                }
                I++;
            }
        }

        private bool At(char c) => I < s.Length && s[I] == c;

        private bool StartsHere(string word) => string.CompareOrdinal(s, I, word, 0, word.Length) == 0;

        public object? Value(int depth)
        {
            if (depth >= MaxDepth)
            {
                throw new JsonParseException("JSON nested too deeply");
            }
            if (I >= s.Length)
            {
                throw Fail("Unexpected end of JSON input");
            }
            char c = s[I];
            switch (c)
            {
                case '{':
                    {
                        I++;
                        var o = new JsObject();
                        Space();
                        if (At('}'))
                        {
                            I++;
                            return o;
                        }
                        while (true)
                        {
                            Space();
                            if (!At('"'))
                            {
                                throw Fail("Expected property name");
                            }
                            string k = String();
                            Space();
                            if (!At(':'))
                            {
                                throw Fail("Expected ':' after property name");
                            }
                            I++;
                            Space();
                            object? v = Value(depth + 1);
                            o.Set(k, v);
                            Space();
                            if (At(','))
                            {
                                I++;
                                continue;
                            }
                            if (At('}'))
                            {
                                I++;
                                return o;
                            }
                            throw Fail("Expected ',' or '}' after property value");
                        }
                    }
                case '[':
                    {
                        I++;
                        var output = new List<object?>();
                        Space();
                        if (At(']'))
                        {
                            I++;
                            return output;
                        }
                        while (true)
                        {
                            Space();
                            output.Add(Value(depth + 1));
                            Space();
                            if (At(','))
                            {
                                I++;
                                continue;
                            }
                            if (At(']'))
                            {
                                I++;
                                return output;
                            }
                            throw Fail("Expected ',' or ']' after array element");
                        }
                    }
                case '"':
                    return String();
                case 't':
                    if (StartsHere("true"))
                    {
                        I += 4;
                        return true;
                    }
                    throw Fail("Unexpected token");
                case 'f':
                    if (StartsHere("false"))
                    {
                        I += 5;
                        return false;
                    }
                    throw Fail("Unexpected token");
                case 'n':
                    if (StartsHere("null"))
                    {
                        I += 4;
                        return null;
                    }
                    throw Fail("Unexpected token");
                default:
                    if (c == '-' || (c >= '0' && c <= '9'))
                    {
                        return Number();
                    }
                    throw Fail("Unexpected token");
            }
        }

        private int Digits()
        {
            int from = I;
            while (I < s.Length && s[I] >= '0' && s[I] <= '9')
            {
                I++;
            }
            return I - from;
        }

        private double Number()
        {
            int start = I;
            if (At('-'))
            {
                I++;
            }
            if (At('0'))
            {
                I++;
            }
            else if (Digits() == 0)
            {
                throw Fail("No number after minus sign");
            }
            if (At('.'))
            {
                I++;
                if (Digits() == 0)
                {
                    throw Fail("Unterminated fractional number");
                }
            }
            if (At('e') || At('E'))
            {
                I++;
                if (At('+') || At('-'))
                {
                    I++;
                }
                if (Digits() == 0)
                {
                    throw Fail("Exponent part is missing a number");
                }
            }
            // Out of range reads as JavaScript reads it: Infinity or 0.
            return double.Parse(s.AsSpan(start, I - start), NumberStyles.Float, CultureInfo.InvariantCulture);
        }

        private int Hex4()
        {
            if (I + 4 > s.Length)
            {
                return -1;
            }
            int n = 0;
            for (int k = 0; k < 4; k++)
            {
                char ch = s[I + k];
                int d = ch >= '0' && ch <= '9' ? ch - '0' : ch >= 'a' && ch <= 'f' ? ch - 'a' + 10 : ch >= 'A' && ch <= 'F' ? ch - 'A' + 10 : -1;
                if (d < 0)
                {
                    return -1;
                }
                n = n * 16 + d;
            }
            I += 4;
            return n;
        }

        private string String()
        {
            I++; // the opening quote
            var b = new StringBuilder();
            int start = I;
            while (I < s.Length)
            {
                char c = s[I];
                if (c == '"')
                {
                    b.Append(s, start, I - start);
                    I++;
                    return b.ToString();
                }
                if (c < 0x20)
                {
                    throw Fail("Bad control character in string literal");
                }
                if (c == '\\')
                {
                    b.Append(s, start, I - start);
                    I++;
                    if (I >= s.Length)
                    {
                        throw Fail("Unterminated string");
                    }
                    char e = s[I++];
                    switch (e)
                    {
                        case '"':
                        case '\\':
                        case '/':
                            b.Append(e);
                            break;
                        case 'b':
                            b.Append('\b');
                            break;
                        case 'f':
                            b.Append('\f');
                            break;
                        case 'n':
                            b.Append('\n');
                            break;
                        case 'r':
                            b.Append('\r');
                            break;
                        case 't':
                            b.Append('\t');
                            break;
                        case 'u':
                            int u = Hex4();
                            if (u < 0)
                            {
                                throw Fail("Bad Unicode escape");
                            }
                            b.Append((char)u);
                            break;
                        default:
                            throw Fail("Bad escaped character");
                    }
                    start = I;
                    continue;
                }
                I++;
            }
            throw Fail("Unterminated string");
        }
    }
}
