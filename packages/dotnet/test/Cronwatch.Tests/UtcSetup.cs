using System;
using System.Runtime.CompilerServices;

namespace Cronwatch.Tests;

/// <summary>
/// The tests run in UTC, as the fixtures were written. On Linux and macOS .NET reads <c>TZ</c>
/// for <see cref="TimeZoneInfo.Local"/>, so the test host sets it before any test runs (and every
/// child process, node's included, inherits it). On Windows <c>TZ</c> is not read, so a test that
/// depends on the local zone names one instead.
/// </summary>
internal static class UtcSetup
{
#pragma warning disable CA2255 // The test assembly is the one place a module initializer belongs.
    [ModuleInitializer]
#pragma warning restore CA2255
    internal static void Initialize()
    {
        Environment.SetEnvironmentVariable("TZ", "UTC");
        TimeZoneInfo.ClearCachedData();
    }
}
