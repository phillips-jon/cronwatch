using System;
using System.Collections.Generic;

namespace Cronwatch.Internal;

/// <summary>Percentile and median (the SDK's <c>stats.ts</c>).</summary>
internal static class Stats
{
    private static double[] Sorted(IReadOnlyList<double> values)
    {
        var output = new double[values.Count];
        for (int i = 0; i < output.Length; i++)
        {
            output[i] = values[i];
        }
        Array.Sort(output);
        return output;
    }

    /// <summary>
    /// The nearest-rank value, with the rank worked out in the same floating point steps as
    /// JavaScript's, so a .NET and a Node process pick the same run; null for no values.
    /// </summary>
    public static double? Percentile(IReadOnlyList<double> values, double p)
    {
        if (values.Count == 0)
        {
            return null;
        }
        double[] s = Sorted(values);
        double n = s.Length;
        int index = (int)Math.Min(n - 1, Math.Max(0, Math.Ceiling(p / 100 * n) - 1));
        return s[index];
    }

    /// <summary>The middle value, or the mean of the two in the middle; null for no values.</summary>
    public static double? Median(IReadOnlyList<double> values)
    {
        if (values.Count == 0)
        {
            return null;
        }
        double[] s = Sorted(values);
        int mid = s.Length / 2;
        return s.Length % 2 == 0 ? (s[mid - 1] + s[mid]) / 2 : s[mid];
    }
}
