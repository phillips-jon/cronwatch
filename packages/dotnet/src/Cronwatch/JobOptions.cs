using System;
using System.Collections;
using System.Collections.Generic;
using Cronwatch.Internal;

namespace Cronwatch;

/// <summary>
/// A job's options: the SDK's <c>JobOptions</c>. The stored definition keeps its fields in the
/// order they were given, as the SDK's object literal does: each property takes its place the
/// first time it is set, so <c>new JobOptions { Schedule = "0 2 * * *", Grace = "15m" }</c> stores
/// <c>schedule</c> before <c>grace</c>. A property set to null is left out.
/// </summary>
public sealed class JobOptions
{
    private readonly List<string> _order = [];
    private readonly Dictionary<string, object?> _values = new(StringComparer.Ordinal);
    private readonly BudgetMap _budget;
    private readonly FloorMap _floor;

    /// <summary>Options with nothing set.</summary>
    public JobOptions()
    {
        _budget = new BudgetMap(this);
        _floor = new FloorMap(this);
    }

    private void Put(string key, object? value)
    {
        if (value == null)
        {
            _values.Remove(key);
            _order.Remove(key);
            return;
        }
        if (!_values.ContainsKey(key))
        {
            _order.Add(key);
        }
        _values[key] = value;
    }

    private T? Read<T>(string key)
        where T : class => _values.TryGetValue(key, out object? v) ? v as T : null;

    /// <summary>
    /// When the job is supposed to run: a five or six field cron expression (<c>"0 2 * * *"</c>), a
    /// nickname (<c>"@hourly"</c>), or an interval (<c>"every 5m"</c>). Without one, nothing is
    /// ever reported as missed.
    /// </summary>
    public string? Schedule { get => Read<string>("schedule"); init => Put("schedule", value); }

    /// <summary>The IANA zone the cron is read in; by default the client's clock's local zone.</summary>
    public string? Timezone { get => Read<string>("timezone"); init => Put("timezone", value); }

    /// <summary>How late a run may start before it counts as missed. Default <c>"10m"</c>.</summary>
    public Duration? Grace { get => DurationOf("grace"); init => PutDuration("grace", value); }

    /// <summary>A run still going after this long is stuck; the run's token is cancelled then. Default <c>"1h"</c>.</summary>
    public Duration? Timeout { get => DurationOf("timeout"); init => PutDuration("timeout", value); }

    /// <summary>Alert when a successful run takes longer than this.</summary>
    public Duration? MaxDuration { get => DurationOf("maxDuration"); init => PutDuration("maxDuration", value); }

    /// <summary>
    /// Ceilings for metrics, in the order given: <c>Budget = { ["cost"] = 2 }</c> alerts when a run
    /// reports a cost above 2.
    /// </summary>
    public BudgetMap Budget
    {
        get => _budget;
        init
        {
            ArgumentNullException.ThrowIfNull(value);
            foreach (var e in value)
            {
                _budget[e.Key] = e.Value;
            }
            Touch("budget");
        }
    }

    /// <summary>
    /// Floors for metrics, in the order given: <c>Floor = { ["rows"] = 1 }</c> alerts when a run
    /// reports rows below 1. A metric without one alerts when a run reports 0 or less and the five
    /// to twenty successful runs before it all reported more than 0. A floor of 0 lets a metric
    /// reach 0 without alerting.
    /// </summary>
    public FloorMap Floor
    {
        get => _floor;
        init
        {
            ArgumentNullException.ThrowIfNull(value);
            foreach (var e in value)
            {
                _floor[e.Key] = e.Value;
            }
            Touch("floor");
        }
    }

    /// <summary>What a successful run's output must show; see <see cref="Cronwatch.Expect"/>.</summary>
    public Expect? Expect { get => _expect; init => _expect = value; }

    private Expect? _expect;

    /// <summary>Alert on the Nth failure in a row rather than the first. Default 1.</summary>
    public int? FailuresBeforeAlert
    {
        get => _values.TryGetValue("failuresBeforeAlert", out object? v) && v is int n ? n : null;
        init => Put("failuresBeforeAlert", value);
    }

    /// <summary>A description, shown on the dashboard.</summary>
    public string? Description { get => Read<string>("description"); init => Put("description", value); }

    /// <summary>Tags, shown on the dashboard.</summary>
    public IReadOnlyList<string>? Tags
    {
        get => _values.TryGetValue("tags", out object? v) && v is List<object?> l ? l.ConvertAll(x => (string)x!) : null;
        init => Put("tags", value == null ? null : new List<object?>(value));
    }

    /// <summary>
    /// Sets a field of the definition this port has no property for (a field a newer SDK knows),
    /// in its place, as JSON: null, a bool, a number, a string, a list, or a
    /// <see cref="JsObject"/>.
    /// </summary>
    /// <returns>These options, for setting several in a line.</returns>
    public JobOptions Field(string key, object? value)
    {
        ArgumentNullException.ThrowIfNull(key);
        Json.Stringify(value);
        if (!_values.ContainsKey(key))
        {
            _order.Add(key);
        }
        _values[key] = JsonText.Copy(value);
        return this;
    }

    private Duration? DurationOf(string key) => _values.TryGetValue(key, out object? v) ? v switch
    {
        string s => s,
        double d => d,
        _ => null,
    }
        : null;

    private void PutDuration(string key, Duration? value) => Put(key, value?.JsonValue);

    internal void Touch(string key)
    {
        if (!_values.ContainsKey(key))
        {
            _order.Add(key);
            _values[key] = key == "floor" ? _floor : (object)_budget;
        }
    }

    /// <summary>
    /// A copy of these options, for an integration that adds to options the app gave. The budget,
    /// the floor, and every value are copied; the expect rule is shared, as it is immutable.
    /// </summary>
    internal JobOptions Copy()
    {
        var copy = new JobOptions();
        copy.MergeFrom(this);
        return copy;
    }

    /// <summary>
    /// Sets each field <paramref name="other"/> sets, after these: a key already here keeps its
    /// place and takes the other's value, as the SDK's object spread does; its expect rule, when it
    /// has one, replaces this one's.
    /// </summary>
    internal void MergeFrom(JobOptions other)
    {
        foreach (string key in other._order)
        {
            object? v = other._values[key];
            if (v is BudgetMap b)
            {
                foreach (var e in b)
                {
                    _budget[e.Key] = e.Value;
                }
                Touch("budget");
            }
            else if (v is FloorMap f)
            {
                foreach (var e in f)
                {
                    _floor[e.Key] = e.Value;
                }
                Touch("floor");
            }
            else
            {
                Put(key, JsonText.Copy(v));
            }
        }
        if (other._expect != null)
        {
            _expect = other._expect;
        }
    }

    /// <summary>Sets a field in place, as the property would; null takes it out.</summary>
    internal void SetField(string key, object? value) => Put(key, value);

    /// <summary>Sets the expect rule.</summary>
    internal void SetExpect(Expect? rule) => _expect = rule;

    /// <summary>The fields as the SDK's options object, in their order, <c>expect</c> left to <see cref="Expect"/>.</summary>
    internal JsObject Fields()
    {
        var o = new JsObject();
        foreach (string key in _order)
        {
            object? v = _values[key];
            o.Set(key, v switch
            {
                BudgetMap b => b.ToJs(),
                FloorMap f => f.ToJs(),
                _ => JsonText.Copy(v),
            });
        }
        return o;
    }

    /// <summary>
    /// The definition these options declare for <paramref name="name"/>, before the client's
    /// defaults: what a source compares to decide whether a job changed.
    /// </summary>
    public Definition Describe(string name)
    {
        var fields = Fields();
        fields.Set("name", name);
        return Cronwatch.Expect.ToStored(fields, Expect);
    }

    /// <summary>The options' fields as JSON; an expect rule as it is stored.</summary>
    public override string ToString()
    {
        var fields = Fields();
        if (Expect != null)
        {
            fields.Set("expect", Expect.ToString());
        }
        return "JobOptions" + fields.ToJson();
    }

    /// <summary>A job's budget: metric names and ceilings, in the order given.</summary>
    public sealed class BudgetMap : IEnumerable<KeyValuePair<string, double>>
    {
        private readonly JobOptions _owner;
        private readonly JsObject _ceilings = new();

        internal BudgetMap(JobOptions owner)
        {
            _owner = owner;
        }

        /// <summary>A metric's ceiling.</summary>
        public double this[string metric]
        {
            get => _ceilings.Get(metric) is double d ? d : throw new KeyNotFoundException(metric);
            set
            {
                ArgumentNullException.ThrowIfNull(metric);
                _ceilings.Set(metric, value);
                _owner.Touch("budget");
            }
        }

        /// <summary>Adds a ceiling, for a collection initializer.</summary>
        public void Add(string metric, double ceiling) => this[metric] = ceiling;

        /// <summary>How many metrics have a ceiling.</summary>
        public int Count => _ceilings.Count;

        internal JsObject ToJs() => _ceilings.Copy();

        /// <inheritdoc/>
        public IEnumerator<KeyValuePair<string, double>> GetEnumerator()
        {
            foreach (var e in _ceilings)
            {
                yield return new KeyValuePair<string, double>(e.Key, (double)e.Value!);
            }
        }

        IEnumerator IEnumerable.GetEnumerator() => GetEnumerator();
    }

    /// <summary>A job's floor: metric names and floors, in the order given.</summary>
    public sealed class FloorMap : IEnumerable<KeyValuePair<string, double>>
    {
        private readonly JobOptions _owner;
        private readonly JsObject _floors = new();

        internal FloorMap(JobOptions owner)
        {
            _owner = owner;
        }

        /// <summary>A metric's floor.</summary>
        public double this[string metric]
        {
            get => _floors.Get(metric) is double d ? d : throw new KeyNotFoundException(metric);
            set
            {
                ArgumentNullException.ThrowIfNull(metric);
                _floors.Set(metric, value);
                _owner.Touch("floor");
            }
        }

        /// <summary>Adds a floor, for a collection initializer.</summary>
        public void Add(string metric, double floor) => this[metric] = floor;

        /// <summary>How many metrics have a floor.</summary>
        public int Count => _floors.Count;

        internal JsObject ToJs() => _floors.Copy();

        /// <inheritdoc/>
        public IEnumerator<KeyValuePair<string, double>> GetEnumerator()
        {
            foreach (var e in _floors)
            {
                yield return new KeyValuePair<string, double>(e.Key, (double)e.Value!);
            }
        }

        IEnumerator IEnumerable.GetEnumerator() => GetEnumerator();
    }
}
