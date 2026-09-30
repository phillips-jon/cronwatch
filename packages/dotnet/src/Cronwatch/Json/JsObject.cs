using System;
using System.Collections;
using System.Collections.Generic;

namespace Cronwatch;

/// <summary>
/// A JavaScript object: its keys in JavaScript's order, which is every key that is an array
/// index (a canonical whole number below 2^32 - 1) in ascending order, then every other key in
/// the order it was first set. Setting a key already there keeps its place and takes the new
/// value, as a JavaScript object does.
/// </summary>
/// <remarks>
/// Values are what <see cref="Json"/> reads and writes: <c>null</c>, a <see cref="bool"/>, a
/// number (<see cref="double"/> when read), a <see cref="string"/>, a <see cref="List{T}"/> of
/// values or a <see cref="JsObject"/>. A definition, a state's unknown keys and a stored alert are
/// kept as these, so a field another writer added is written back where it was. Not safe for use
/// from several threads at once without a lock of the caller's.
/// </remarks>
public sealed class JsObject : IEnumerable<KeyValuePair<string, object?>>
{
    private readonly SortedDictionary<long, KeyValuePair<string, object?>> _indexed = [];
    private readonly OrderedDictionary<string, object?> _named = new(StringComparer.Ordinal);

    /// <summary>An empty object.</summary>
    public JsObject()
    {
    }

    /// <summary>
    /// Whether a key is an array index, which JavaScript orders before every other key: the
    /// number, or -1 when it is not one.
    /// </summary>
    internal static long ArrayIndex(string key)
    {
        int n = key.Length;
        if (n == 0 || n > 10 || (n > 1 && key[0] == '0'))
        {
            return -1;
        }
        long v = 0;
        foreach (char c in key)
        {
            if (c < '0' || c > '9')
            {
                return -1;
            }
            v = v * 10 + (c - '0');
        }
        return v >= (1L << 32) - 1 ? -1 : v;
    }

    /// <summary>
    /// Gives <paramref name="key"/> the value: a new key takes its place in JavaScript's order, a
    /// key already there keeps its place.
    /// </summary>
    /// <returns>This object, for building one in a line.</returns>
    public JsObject Set(string key, object? value)
    {
        ArgumentNullException.ThrowIfNull(key);
        long n = ArrayIndex(key);
        if (n >= 0)
        {
            _indexed[n] = new KeyValuePair<string, object?>(key, value);
        }
        else
        {
            _named[key] = value;
        }
        return this;
    }

    /// <summary>The value at <paramref name="key"/>, or null when it is absent (see <see cref="Has"/>) or null.</summary>
    public object? this[string key]
    {
        get => Get(key);
        set => Set(key, value);
    }

    /// <summary>The value at <paramref name="key"/>, or null when it is absent or null.</summary>
    public object? Get(string key)
    {
        long n = ArrayIndex(key);
        if (n >= 0)
        {
            return _indexed.TryGetValue(n, out var e) ? e.Value : null;
        }
        return _named.TryGetValue(key, out var v) ? v : null;
    }

    /// <summary>Whether the key is there, whatever its value.</summary>
    public bool Has(string key)
    {
        long n = ArrayIndex(key);
        return n >= 0 ? _indexed.ContainsKey(n) : _named.ContainsKey(key);
    }

    /// <summary>Removes <paramref name="key"/>, giving back whether it was there.</summary>
    public bool Remove(string key)
    {
        long n = ArrayIndex(key);
        return n >= 0 ? _indexed.Remove(n) : _named.Remove(key);
    }

    /// <summary><c>Object.keys</c>: the keys in JavaScript's order.</summary>
    public IReadOnlyList<string> Keys
    {
        get
        {
            var output = new List<string>(Count);
            foreach (var e in _indexed.Values)
            {
                output.Add(e.Key);
            }
            output.AddRange(_named.Keys);
            return output;
        }
    }

    /// <summary>How many keys there are.</summary>
    public int Count => _indexed.Count + _named.Count;

    /// <summary>Whether there are none.</summary>
    public bool IsEmpty => Count == 0;

    /// <summary>A deep copy: nested objects and lists are copied too.</summary>
    public JsObject Copy()
    {
        var output = new JsObject();
        foreach (var e in this)
        {
            output.Set(e.Key, CopyValue(e.Value));
        }
        return output;
    }

    /// <summary>A deep copy of a JSON value.</summary>
    internal static object? CopyValue(object? v)
    {
        if (v is JsObject o)
        {
            return o.Copy();
        }
        if (v is List<object?> list)
        {
            var output = new List<object?>(list.Count);
            foreach (var x in list)
            {
                output.Add(CopyValue(x));
            }
            return output;
        }
        return v;
    }

    /// <summary>The keys and values in JavaScript's order.</summary>
    public IEnumerator<KeyValuePair<string, object?>> GetEnumerator()
    {
        foreach (var e in _indexed.Values)
        {
            yield return e;
        }
        foreach (var e in _named)
        {
            yield return e;
        }
    }

    IEnumerator IEnumerable.GetEnumerator() => GetEnumerator();

    /// <summary>Adds a key, for a collection initializer.</summary>
    public void Add(string key, object? value) => Set(key, value);

    /// <summary><c>JSON.stringify</c> of the object.</summary>
    public string ToJson() => Json.Stringify(this);

    /// <summary>The object's JSON.</summary>
    public override string ToString() => ToJson();

    /// <summary>Equal when both hold the same keys in the same order with values whose JSON is the same.</summary>
    public override bool Equals(object? obj) => obj is JsObject o && string.Equals(ToJson(), o.ToJson(), StringComparison.Ordinal);

    /// <inheritdoc/>
    public override int GetHashCode() => StringComparer.Ordinal.GetHashCode(ToJson());
}
