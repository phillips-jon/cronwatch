using System;
using System.Collections;
using System.Collections.Generic;

namespace Cronwatch;

/// <summary>
/// An immutable list compared by its content, so a record holding one compares by value.
/// </summary>
/// <typeparam name="T">The element type.</typeparam>
public sealed class ValueList<T> : IReadOnlyList<T>, IEquatable<ValueList<T>>
{
    private readonly T[] _items;

    /// <summary>The empty list.</summary>
    public static ValueList<T> Empty { get; } = new([]);

    private ValueList(T[] items)
    {
        _items = items;
    }

    /// <summary>A list holding a copy of <paramref name="items"/>.</summary>
    public static ValueList<T> Of(IEnumerable<T> items)
    {
        ArgumentNullException.ThrowIfNull(items);
        var array = new List<T>(items).ToArray();
        return array.Length == 0 ? Empty : new ValueList<T>(array);
    }

    /// <summary>A list holding these items.</summary>
    public static ValueList<T> Of(params ReadOnlySpan<T> items) => items.Length == 0 ? Empty : new ValueList<T>(items.ToArray());

    /// <summary>A list from a collection expression.</summary>
    public static implicit operator ValueList<T>(T[] items) => Of((IEnumerable<T>)items);

    /// <inheritdoc/>
    public T this[int index] => _items[index];

    /// <inheritdoc/>
    public int Count => _items.Length;

    /// <inheritdoc/>
    public IEnumerator<T> GetEnumerator() => ((IEnumerable<T>)_items).GetEnumerator();

    IEnumerator IEnumerable.GetEnumerator() => _items.GetEnumerator();

    /// <inheritdoc/>
    public bool Equals(ValueList<T>? other)
    {
        if (other is null || other.Count != Count)
        {
            return false;
        }
        var cmp = EqualityComparer<T>.Default;
        for (int i = 0; i < _items.Length; i++)
        {
            if (!cmp.Equals(_items[i], other._items[i]))
            {
                return false;
            }
        }
        return true;
    }

    /// <inheritdoc/>
    public override bool Equals(object? obj) => obj is ValueList<T> l && Equals(l);

    /// <inheritdoc/>
    public override int GetHashCode()
    {
        var h = new HashCode();
        foreach (var x in _items)
        {
            h.Add(x);
        }
        return h.ToHashCode();
    }

    /// <summary>The items, comma separated in brackets.</summary>
    public override string ToString() => "[" + string.Join(", ", _items) + "]";
}
