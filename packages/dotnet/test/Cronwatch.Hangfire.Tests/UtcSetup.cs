using System;
using System.Globalization;
using System.Runtime.CompilerServices;

namespace Cronwatch.Hangfire.Tests;

/// <summary>
/// The tests run in UTC, as the fixtures were written. On Linux and macOS .NET reads <c>TZ</c>
/// for <see cref="TimeZoneInfo.Local"/>, so the test host sets it before any test runs (and every
/// child process, node's included, inherits it). On Windows <c>TZ</c> is not read, so a test that
/// depends on the local zone names one instead.
/// </summary>
/// <remarks>
/// <c>CRONWATCH_CULTURE</c> (CI sets <c>tr-TR</c> for a second run) makes that culture every
/// thread's current culture and UI culture for the whole assembly, so a format or comparison that
/// reads the culture fails a byte-for-byte replay.
/// </remarks>
internal static class UtcSetup
{
#pragma warning disable CA2255 // The test assembly is the one place a module initializer belongs.
    [ModuleInitializer]
#pragma warning restore CA2255
    internal static void Initialize()
    {
        Environment.SetEnvironmentVariable("TZ", "UTC");
        TimeZoneInfo.ClearCachedData();
        string? culture = Environment.GetEnvironmentVariable("CRONWATCH_CULTURE");
        if (!string.IsNullOrEmpty(culture))
        {
            var c = CultureInfo.GetCultureInfo(culture);
            CultureInfo.DefaultThreadCurrentCulture = c;
            CultureInfo.DefaultThreadCurrentUICulture = c;
            CultureInfo.CurrentCulture = c;
            CultureInfo.CurrentUICulture = c;
        }
    }
}
