using System;
using System.Collections.Generic;
using System.Globalization;
using System.Text;
using Cronwatch.Internal;
using Xunit;

namespace Cronwatch.Tests;

/// <summary>
/// Seeded properties over JSON and the stored records: text written and read back is the same
/// text, and a stored row of any shape reads without throwing and writes back as it read.
/// <c>CRONWATCH_TRIES=N</c> multiplies the tries; a failure names its seed.
/// </summary>
public class JsonProperties
{
    private static int Tries(int n) =>
        n * (int.TryParse(Environment.GetEnvironmentVariable("CRONWATCH_TRIES"), NumberStyles.Integer, CultureInfo.InvariantCulture, out int k) && k > 0 ? k : 1);

    /// <summary>A small generator of JSON values, strings with surrogates and control characters among them.</summary>
    private sealed class Values(int seed)
    {
        private readonly Random _random = new(seed);

        public string Text()
        {
            int n = _random.Next(0, 12);
            var b = new StringBuilder();
            for (int i = 0; i < n; i++)
            {
                b.Append(_random.Next(8) switch
                {
                    0 => (char)_random.Next(0, 0x20),
                    1 => (char)_random.Next(0xd800, 0xe000),
                    2 => '"',
                    3 => '\\',
                    4 => (char)_random.Next(0x80, 0xd800),
                    _ => (char)_random.Next(0x20, 0x7f),
                });
            }
            return b.ToString();
        }

        public double Number() => _random.Next(6) switch
        {
            0 => _random.Next(-1000, 1000),
            1 => _random.NextDouble() * Math.Pow(10, _random.Next(-30, 30)),
            2 => BitConverter.Int64BitsToDouble(_random.NextInt64()) is var d && double.IsFinite(d) ? d : 0,
            3 => 1e21,
            4 => 1e-7,
            _ => -_random.NextDouble(),
        };

        public object? Value(int depth)
        {
            switch (_random.Next(depth > 3 ? 4 : 6))
            {
                case 0:
                    return null;
                case 1:
                    return _random.Next(2) == 0;
                case 2:
                    return Number();
                case 3:
                    return Text();
                case 4:
                    var list = new List<object?>();
                    for (int i = _random.Next(4); i > 0; i--)
                    {
                        list.Add(Value(depth + 1));
                    }
                    return list;
                default:
                    var o = new JsObject();
                    for (int i = _random.Next(5); i > 0; i--)
                    {
                        o.Set(_random.Next(4) == 0 ? _random.Next(20).ToString(CultureInfo.InvariantCulture) : Text(), Value(depth + 1));
                    }
                    return o;
            }
        }
    }

    [Fact]
    public void Json_written_and_read_back_is_the_same_text()
    {
        for (int seed = 0; seed < Tries(500); seed++)
        {
            object? v = new Values(seed).Value(0);
            string text = Json.Stringify(v);
            string again = Json.Stringify(Json.Parse(text));
            Assert.True(text == again, "seed " + seed + ": " + text + " read back as " + again);
        }
    }

    [Fact]
    public void Numbers_read_back_as_the_same_double()
    {
        for (int seed = 0; seed < Tries(2000); seed++)
        {
            double d = new Values(seed).Number();
            string text = Js.FormatNumber(d);
            Assert.True(double.Parse(text, CultureInfo.InvariantCulture) == d, "seed " + seed + ": " + text);
        }
    }

    [Fact]
    public void A_stored_state_of_any_shape_reads_and_writes_back_as_it_read()
    {
        for (int seed = 0; seed < Tries(500); seed++)
        {
            var values = new Values(seed);
            var row = new JsObject().Set("job", "a");
            foreach (string key in new[] { "open", "consecutiveFailures", "silencedUntil", "lastAlertAt", "pendingRecovery", "undelivered", "version", "extra" })
            {
                if (values.Value(3) is var v && v is not null)
                {
                    row.Set(key, v);
                }
            }
            JobState state = JobState.FromJson(row.ToJson());
            string written = state.ToJson();
            Assert.True(written == JobState.FromJson(written).ToJson(), "seed " + seed + ": " + row.ToJson());
            Assert.InRange(state.CountedVersion, 0, Js.MaxSafeInteger);
        }
    }

    [Fact]
    public void Durations_through_the_options_are_the_sdks_or_refused_with_its_message()
    {
        var clock = Support.Clock();
        for (int seed = 0; seed < Tries(300); seed++)
        {
            var values = new Values(seed);
            string text = seed % 3 == 0 ? values.Text() : (seed % 97).ToString(CultureInfo.InvariantCulture) + (seed % 2 == 0 ? "m" : "h" + (seed % 60) + "m");
            try
            {
                var cw = new CronwatchClient(new CronwatchOptions { Clock = clock, ProcessExitHook = false, Alerts = [] });
                var job = cw.Job("d", new JobOptions { Grace = text });
                Assert.Equal(text, job.Definition.Get("grace"));
            }
            catch (CronwatchException e)
            {
                Assert.Equal(CronwatchErrorKind.Invalid, e.Kind);
                Assert.False(string.IsNullOrEmpty(e.Message), "seed " + seed);
            }
        }
    }
}
