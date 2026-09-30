using System;
using System.Globalization;
using System.Runtime.CompilerServices;

namespace Cronwatch.Hosting.Tests;

/// <summary>
/// The tests run in UTC, and under <c>CRONWATCH_CULTURE</c> when it is set, as the core's tests
/// do (see <c>Cronwatch.Tests.UtcSetup</c>).
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
