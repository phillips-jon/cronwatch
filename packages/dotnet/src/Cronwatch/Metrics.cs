using System;
using System.Collections;
using System.Collections.Generic;
using System.Diagnostics.CodeAnalysis;
using System.Linq;

namespace Cronwatch;

/// <summary>
/// A run's metrics: names and finite numbers, in the order they were first reported. Immutable,
/// compared by content.
/// </summary>
public sealed class Metrics : IReadOnlyDictionary<string, double>, IEquatable<Metrics>
{
    private readonly JsObject _values;

    /// <summary>No metrics.</summary>
    public static Metrics Empty { get; } = new(new JsObject());

    private Metrics(JsObject values)
    {
        _values = values;
    }

    /// <summary>Metrics of these names and values, in their order.</summary>
    /// <exception cref="ArgumentException">When a value is not finite.</exception>
    public static Metrics Of(IEnumerable<KeyValuePair<string, double>> values)
    {
        ArgumentNullException.ThrowIfNull(values);
        var o = new JsObject();
        foreach (var e in values)
        {
            if (!double.IsFinite(e.Value))
            {
                throw new ArgumentException("metric \"" + e.Key + "\" must be a finite number");
            }
            o.Set(e.Key, e.Value);
        }
        return new Metrics(o);
    }

    /// <summary>Metrics over a JSON object the caller gives up (numbers only, already checked).</summary>
    internal static Metrics Own(JsObject values) => new(values);

    /// <summary>A copy with one metric set.</summary>
    public Metrics With(string name, double value)
    {
        var o = _values.Copy();
        o.Set(name, value);
        return new Metrics(o);
    }

    /// <summary>These metrics with <paramref name="over"/>'s set over them (its values win).</summary>
    public Metrics Merged(Metrics over)
    {
        ArgumentNullException.ThrowIfNull(over);
        if (over.Count == 0)
        {
            return this;
        }
        var o = _values.Copy();
        foreach (var e in over._values)
        {
            o.Set(e.Key, e.Value);
        }
        return new Metrics(o);
    }

    /// <inheritdoc/>
    public double this[string key] => TryGetValue(key, out double v) ? v : throw new KeyNotFoundException(key);

    /// <inheritdoc/>
    public IEnumerable<string> Keys => _values.Keys;

    /// <inheritdoc/>
    public IEnumerable<double> Values => _values.Select(e => (double)e.Value!);

    /// <inheritdoc/>
    public int Count => _values.Count;

    /// <inheritdoc/>
    public bool ContainsKey(string key) => _values.Has(key);

    /// <inheritdoc/>
    public bool TryGetValue(string key, [MaybeNullWhen(false)] out double value)
    {
        if (_values.Get(key) is double d)
        {
            value = d;
            return true;
        }
        value = 0;
        return false;
    }

    /// <inheritdoc/>
    public IEnumerator<KeyValuePair<string, double>> GetEnumerator()
    {
        foreach (var e in _values)
        {
            yield return new KeyValuePair<string, double>(e.Key, (double)e.Value!);
        }
    }

    IEnumerator IEnumerable.GetEnumerator() => GetEnumerator();

    /// <summary>The metrics as a JSON object (a copy).</summary>
    public JsObject ToValue() => _values.Copy();

    /// <summary>The metrics' JSON.</summary>
    public string ToJson() => _values.ToJson();

    /// <summary>
    /// Metrics read from stored JSON: null is none, and anything else must be an object of
    /// numbers.
    /// </summary>
    /// <exception cref="JsonParseException">When it is not.</exception>
    public static Metrics FromValue(object? v)
    {
        if (v == null)
        {
            return Empty;
        }
        if (v is not JsObject o)
        {
            throw new JsonParseException("metrics must be an object, not " + Json.Kind(v));
        }
        var output = new JsObject();
        foreach (var e in o)
        {
            if (!Json.TryNumber(e.Value, out double n))
            {
                throw new JsonParseException("metric " + Json.Quote(e.Key) + " must be a number, not " + Json.Kind(e.Value));
            }
            output.Set(e.Key, n);
        }
        return new Metrics(output);
    }

    /// <summary>Metrics read from a row of another shape: the numbers kept, anything else dropped.</summary>
    public static Metrics Lenient(object? v)
    {
        var output = new JsObject();
        if (v is JsObject o)
        {
            foreach (var e in o)
            {
                if (Json.TryNumber(e.Value, out double n))
                {
                    output.Set(e.Key, n);
                }
            }
        }
        return new Metrics(output);
    }

    /// <summary>The metrics' JSON.</summary>
    public override string ToString() => ToJson();

    /// <inheritdoc/>
    public bool Equals(Metrics? other) => other is not null && _values.Equals(other._values);

    /// <inheritdoc/>
    public override bool Equals(object? obj) => obj is Metrics m && Equals(m);

    /// <inheritdoc/>
    public override int GetHashCode() => _values.GetHashCode();
}
