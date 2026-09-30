using System;
using System.Data.Common;
using System.Globalization;
using System.Threading;
using System.Threading.Tasks;
using MySqlConnector;
using Npgsql;
using Xunit;

namespace Cronwatch.Tests;

/// <summary>
/// The database servers the tests reach: each from its <c>CRONWATCH_TEST_*</c> variable, a URL
/// such as <c>postgres://postgres:pw@127.0.0.1:5432/cw</c> or
/// <c>mysql://root:pw@127.0.0.1:3306/cw</c>, turned into the driver's connection string. A test
/// that needs one it has not got skips, saying which variable would run it.
/// </summary>
internal static class Databases
{
    public const string PgVariable = "CRONWATCH_TEST_PG";
    public const string MySqlVariable = "CRONWATCH_TEST_MYSQL";
    public const string MariaDbVariable = "CRONWATCH_TEST_MARIADB";
    public const string PgCronVariable = "CRONWATCH_TEST_PGCRON";

    private static int s_prefix;

    /// <summary>The variable's URL, or null when it is unset or empty.</summary>
    public static string? Url(string variable)
    {
        string? url = Environment.GetEnvironmentVariable(variable);
        return string.IsNullOrWhiteSpace(url) ? null : url;
    }

    /// <summary>The variable's URL, or skips the test.</summary>
    public static string Require(string variable) =>
        Url(variable) ?? throw SkipException(variable);

    private static Exception SkipException(string variable)
    {
        Assert.Skip(variable + " is not set");
        return new InvalidOperationException();
    }

    /// <summary>A table prefix of the test's own, so tests on one database never meet.</summary>
    public static string Prefix(string name) =>
        "t" + Environment.ProcessId.ToString(CultureInfo.InvariantCulture) + "_" + Interlocked.Increment(ref s_prefix).ToString(CultureInfo.InvariantCulture) + "_" + name + "_";

    /// <summary>Npgsql's connection string for a <c>postgres://</c> URL.</summary>
    public static string PgConnectionString(string url)
    {
        var u = new Uri(url);
        var b = new NpgsqlConnectionStringBuilder
        {
            Host = u.Host,
            Port = u.IsDefaultPort || u.Port < 0 ? 5432 : u.Port,
            Database = u.AbsolutePath.Trim('/'),
            Username = User(u),
            Password = Password(u),
        };
        return b.ConnectionString;
    }

    /// <summary>MySqlConnector's connection string for a <c>mysql://</c> or <c>mariadb://</c> URL.</summary>
    public static string MySqlConnectionString(string url, bool useAffectedRows = false)
    {
        var u = new Uri(url);
        var b = new MySqlConnectionStringBuilder
        {
            Server = u.Host,
            Port = (uint)(u.IsDefaultPort || u.Port < 0 ? 3306 : u.Port),
            Database = u.AbsolutePath.Trim('/'),
            UserID = User(u),
            Password = Password(u),
            UseAffectedRows = useAffectedRows,
        };
        return b.ConnectionString;
    }

    private static string User(Uri u)
    {
        string info = u.UserInfo;
        int colon = info.IndexOf(':', StringComparison.Ordinal);
        return Uri.UnescapeDataString(colon < 0 ? info : info[..colon]);
    }

    private static string Password(Uri u)
    {
        string info = u.UserInfo;
        int colon = info.IndexOf(':', StringComparison.Ordinal);
        return colon < 0 ? "" : Uri.UnescapeDataString(info[(colon + 1)..]);
    }

    /// <summary>A Postgres data source for the URL.</summary>
    public static NpgsqlDataSource Postgres(string url) => NpgsqlDataSource.Create(PgConnectionString(url));

    /// <summary>A MySQL or MariaDB data source for the URL.</summary>
    public static MySqlDataSource MySql(string url, bool useAffectedRows = false) => new(MySqlConnectionString(url, useAffectedRows));

    /// <summary>Runs statements on a connection of their own, outside any store.</summary>
    public static async Task ExecAsync(DbDataSource source, params string[] statements)
    {
        await using var c = await source.OpenConnectionAsync();
        foreach (string statement in statements)
        {
            await using var cmd = c.CreateCommand();
            cmd.CommandText = statement;
            await cmd.ExecuteNonQueryAsync();
        }
    }
}
