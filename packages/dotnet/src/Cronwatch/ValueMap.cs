using System;
using System.Collections;
using System.Collections.Generic;
using System.Diagnostics.CodeAnalysis;

namespace Cronwatch;

/// <summary>
/// An immutable map that keeps its keys in the order given, compared by its content (order
/// included), so a record holding one compares by value.
/// </summary>
/// <typeparam name="TKey">The key type.</typeparam>
/// <typeparam name="TValue">The value type.</typeparam>
public sealed class ValueMap<TKey, TValue> : IReadOnlyDictionary<TKey, TValue>, IEquatable<ValueMap<TKey, TValue>>
    where TKey : notnull
{
    private readonly KeyValuePair<TKey, TValue>[] _entries;
    private readonly Dictionary<TKey, TValue> _lookup;

    /// <summary>The empty map.</summary>
    public static ValueMap<TKey, TValue> Empty { get; } = new([]);

    private ValueMap(KeyValuePair<TKey, TValue>[] entries)
    {
        _entries = entries;
        _lookup = new Dictionary<TKey, TValue>(entries.Length);
        foreach (var e in entries)
        {
            _lookup[e.Key] = e.Value;
        }
    }

    /// <summary>
    /// A map of these entries in their order; a key given twice keeps its first place and its last
    /// value, as a JavaScript object does.
    /// </summary>
    public static ValueMap<TKey, TValue> Of(IEnumerable<KeyValuePair<TKey, TValue>> entries)
    {
        ArgumentNullException.ThrowIfNull(entries);
        var order = new List<TKey>();
        var values = new Dictionary<TKey, TValue>();
        foreach (var e in entries)
        {
            if (!values.ContainsKey(e.Key))
            {
                order.Add(e.Key);
            }
            values[e.Key] = e.Value;
        }
        if (order.Count == 0)
        {
            return Empty;
        }
        var output = new KeyValuePair<TKey, TValue>[order.Count];
        for (int i = 0; i < order.Count; i++)
        {
            output[i] = new KeyValuePair<TKey, TValue>(order[i], values[order[i]]);
        }
        return new ValueMap<TKey, TValue>(output);
    }

    /// <summary>A copy with <paramref name="key"/> set: a new key goes last, a key already there keeps its place.</summary>
    public ValueMap<TKey, TValue> With(TKey key, TValue value)
    {
        var list = new List<KeyValuePair<TKey, TValue>>(_entries) { new(key, value) };
        return Of(list);
    }

    /// <summary>A copy without <paramref name="key"/>.</summary>
    public ValueMap<TKey, TValue> Without(TKey key)
    {
        if (!_lookup.ContainsKey(key))
        {
            return this;
        }
        var list = new List<KeyValuePair<TKey, TValue>>();
        foreach (var e in _entries)
        {
            if (!EqualityComparer<TKey>.Default.Equals(e.Key, key))
            {
                list.Add(e);
            }
        }
        return Of(list);
    }

    /// <inheritdoc/>
    public TValue this[TKey key] => _lookup[key];

    /// <inheritdoc/>
    public IEnumerable<TKey> Keys
    {
        get
        {
            foreach (var e in _entries)
            {
                yield return e.Key;
            }
        }
    }

    /// <inheritdoc/>
    public IEnumerable<TValue> Values
    {
        get
        {
            foreach (var e in _entries)
            {
                yield return e.Value;
            }
        }
    }

    /// <inheritdoc/>
    public int Count => _entries.Length;

    /// <inheritdoc/>
    public bool ContainsKey(TKey key) => _lookup.ContainsKey(key);

    /// <inheritdoc/>
    public bool TryGetValue(TKey key, [MaybeNullWhen(false)] out TValue value) => _lookup.TryGetValue(key, out value);

    /// <inheritdoc/>
    public IEnumerator<KeyValuePair<TKey, TValue>> GetEnumerator() => ((IEnumerable<KeyValuePair<TKey, TValue>>)_entries).GetEnumerator();

    IEnumerator IEnumerable.GetEnumerator() => _entries.GetEnumerator();

    /// <inheritdoc/>
    public bool Equals(ValueMap<TKey, TValue>? other)
    {
        if (other is null || other.Count != Count)
        {
            return false;
        }
        for (int i = 0; i < _entries.Length; i++)
        {
            if (!EqualityComparer<TKey>.Default.Equals(_entries[i].Key, other._entries[i].Key)
                || !EqualityComparer<TValue>.Default.Equals(_entries[i].Value, other._entries[i].Value))
            {
                return false;
            }
        }
        return true;
    }

    /// <inheritdoc/>
    public override bool Equals(object? obj) => obj is ValueMap<TKey, TValue> m && Equals(m);

    /// <inheritdoc/>
    public override int GetHashCode()
    {
        var h = new HashCode();
        foreach (var e in _entries)
        {
            h.Add(e.Key);
            h.Add(e.Value);
        }
        return h.ToHashCode();
    }

    /// <summary>The entries, in braces.</summary>
    public override string ToString() => "{" + string.Join(", ", Array.ConvertAll(_entries, e => e.Key + ": " + e.Value)) + "}";
}
