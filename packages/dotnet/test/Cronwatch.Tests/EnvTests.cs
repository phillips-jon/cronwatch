using System;
using System.Collections.Generic;
using Cronwatch.Internal;
using Xunit;

namespace Cronwatch.Tests;

/// <summary>
/// The SDK's <c>env.test.ts</c> table: <c>CRONWATCH_ENV</c>, then <c>APP_ENV</c>, then .NET's own
/// (<c>ASPNETCORE_ENVIRONMENT</c> in <c>NODE_ENV</c>'s place), the first that is not blank once
/// trimmed, lowercased, with the aliases.
/// </summary>
public class EnvTests
{
    [Theory]
    [InlineData(null, null, null, "")]
    [InlineData(null, null, "development", "development")]
    [InlineData(null, null, "test", "development")]
    [InlineData(null, null, "production", "production")]
    [InlineData(null, "local", "production", "development")]
    [InlineData("production", "dev", "development", "production")]
    [InlineData("staging", null, "development", "staging")]
    [InlineData("  PROD ", null, null, "production")]
    [InlineData(null, "Testing", null, "development")]
    [InlineData(null, "DEV", null, "development")]
    [InlineData("", "   ", "production", "production")]
    [InlineData(" \t", null, null, "")]
    public void The_environment_is_read_as_every_port_reads_it(string? cronwatchEnv, string? appEnv, string? own, string want)
    {
        var variables = new Dictionary<string, string?>(StringComparer.Ordinal)
        {
            ["CRONWATCH_ENV"] = cronwatchEnv,
            ["APP_ENV"] = appEnv,
            ["ASPNETCORE_ENVIRONMENT"] = own,
        };
        Assert.Equal(want, Env.Environment(null, name => variables.GetValueOrDefault(name)));
        // The app's own environment stands where ASPNETCORE_ENVIRONMENT does, above it.
        variables["ASPNETCORE_ENVIRONMENT"] = null;
        Assert.Equal(want, Env.Environment(own, name => variables.GetValueOrDefault(name)));
    }
}
