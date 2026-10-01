using System;
using System.Collections.Generic;
using System.Data;
using System.Data.Common;
using System.Globalization;
using System.Threading;
using System.Threading.Tasks;
using System.Transactions;
using Cronwatch.Internal;

namespace Cronwatch;

/// <summary>
/// Keeps CronWatch's jobs, runs and state in the app's own database through ADO.NET: the SDK's
/// tables (<c>stores/sql.ts</c>), the same names, columns and statements, and the SDK's JSON in
/// the JSON columns byte for byte, so a .NET process shares a database with a Node, Ruby, Python,
/// PHP, Go, Rust, Elixir or Java one. The app brings its driver and its
/// <see cref="DbDataSource"/> (its pool); no driver is a dependency of this library. The tables
/// are made when the client first calls <see cref="InitAsync"/>.
/// </summary>
/// <remarks>
/// <para>
/// On SQLite (Microsoft.Data.Sqlite, whose <c>SqliteFactory.Instance.CreateDataSource(...)</c> is
/// a data source) the store opens one connection once and keeps it for its statements, in turn, as
/// the SDK's store holds one: an in-memory database is one per connection, and SQLite has one
/// writer at a time anyway. That connection is put in WAL mode (with the SDK's retry of a busy
/// database while switching), then <c>busy_timeout</c> 5000 and <c>synchronous</c> NORMAL.
/// </para>
/// <para>
/// On MySQL 8.0.13 or newer and MariaDB 10.6 or newer (MySqlConnector) the dialect is the PHP,
/// Go, Rust, Elixir and Java ports': the same tables with <c>VARCHAR(255)</c> keys, the JSON
/// columns as <c>LONGTEXT</c> holding the SDK's JSON byte for byte (never MySQL's <c>JSON</c>
/// type, which rewrites it), names compared by byte (<c>utf8mb4_bin</c>), and a run's trigger cut
/// to 255 characters on a code point. A conditional write that answered 0 is read back, so a
/// connection that counts changed rather than matched rows (<c>UseAffectedRows=true</c>) cannot
/// make a write that landed read as refused.
/// </para>
/// <para>
/// On Postgres, MySQL and MariaDB every statement runs on a connection the store opens for it, in
/// autocommit. Every
/// connection the store opens is opened with the ambient transaction suppressed
/// (<see cref="TransactionScopeOption.Suppress"/>), so the store's writes never join a
/// <see cref="TransactionScope"/> the app has open, and a failed run does not vanish with the
/// rollback it caused.
/// </para>
/// </remarks>
public sealed class SqlStore : IStore, IUpdateRunIfStore, ICompareAndSetStateStore, IDeleteRunIfStore, IAsyncDisposable,
#pragma warning disable CS0618 // the former names, kept through 1.x
    IConditionalRunStore, IStateCasStore, IRunDeletingStore
#pragma warning restore CS0618
{
    private static readonly TimeSpan BusyRetry = TimeSpan.FromSeconds(2);

    private readonly DbDataSource _dataSource;
    private readonly SqlDialect _dialect;
    private readonly string _prefix;
    private readonly SqlText.Statements _sql;

    // SQLite's one connection, and the turn its statements take.
    private readonly SemaphoreSlim _turn = new(1, 1);
    private DbConnection? _connection;

    private SqlStore(DbDataSource dataSource, SqlDialect dialect, string prefix)
    {
        _dataSource = dataSource ?? throw new ArgumentNullException(nameof(dataSource));
        _dialect = dialect;
        _prefix = prefix;
        _sql = new SqlText.Statements(dialect, prefix);
    }

    /// <summary>
    /// A store over the app's SQLite data source, with the tables named <c>cronwatch_jobs</c>,
    /// <c>cronwatch_runs</c> and <c>cronwatch_state</c>. Nothing is read or written until
    /// <see cref="InitAsync"/>.
    /// </summary>
    public static SqlStore Sqlite(DbDataSource dataSource) => new(dataSource, SqlDialect.Sqlite, SqlText.DefaultPrefix);

    /// <summary>
    /// A store over the app's Postgres data source, with the SDK's tables and statements
    /// (<c>JSONB</c> for the JSON, <c>BIGINT</c> times, names sorted <c>COLLATE "C"</c>). Many
    /// processes can start at once: <see cref="InitAsync"/> makes the tables under an advisory
    /// lock per prefix.
    /// </summary>
    public static SqlStore Postgres(DbDataSource dataSource) => new(dataSource, SqlDialect.Postgres, SqlText.DefaultPrefix);

    /// <summary>
    /// A store over the app's MySQL (8.0.13 or newer) or MariaDB (10.6 or newer) data source, with
    /// the dialect the other ports share: <c>LONGTEXT</c> holding the SDK's JSON,
    /// <c>utf8mb4_bin</c>, <c>ON DUPLICATE KEY</c>. MySQL commits <c>CREATE TABLE</c> at once, so
    /// <see cref="InitAsync"/> is best left to the client's first use. Nothing is read or written
    /// until <see cref="InitAsync"/>.
    /// </summary>
    public static SqlStore MySql(DbDataSource dataSource) => new(dataSource, SqlDialect.MySql, SqlText.DefaultPrefix);

    /// <summary>
    /// A store for whatever database the data source reaches, read from its connection's type name
    /// (<c>SqliteConnection</c>, <c>NpgsqlConnection</c>, <c>MySqlConnection</c>, which serves
    /// MariaDB too) without referencing any of them.
    /// </summary>
    /// <exception cref="CronwatchException">Of kind <see cref="CronwatchErrorKind.Invalid"/> for another database.</exception>
    public static SqlStore For(DbDataSource dataSource)
    {
        ArgumentNullException.ThrowIfNull(dataSource);
        using DbConnection c = dataSource.CreateConnection();
        string name = c.GetType().Name;
        if (name.Contains("Sqlite", StringComparison.OrdinalIgnoreCase))
        {
            return Sqlite(dataSource);
        }
        if (name.Contains("Npgsql", StringComparison.OrdinalIgnoreCase) || name.Contains("Postgres", StringComparison.OrdinalIgnoreCase))
        {
            return Postgres(dataSource);
        }
        if (name.Contains("MySql", StringComparison.OrdinalIgnoreCase) || name.Contains("MariaDb", StringComparison.OrdinalIgnoreCase))
        {
            return MySql(dataSource);
        }
        // The type's name is the driver's, never a credential, but it is not quoted either.
        throw CronwatchException.Invalid(
            "SqlStore: the data source's database is not one SqlStore knows (SQLite, Postgres, MySQL or MariaDB)");
    }

    /// <summary>
    /// A store like this one whose tables start with <paramref name="prefix"/>: lowercase letters,
    /// digits and underscores, not starting with a digit, at most 47 characters. Default
    /// <c>cronwatch_</c>. Call it before the store is used.
    /// </summary>
    /// <exception cref="CronwatchException">Of kind <see cref="CronwatchErrorKind.Invalid"/>, with the SDK's message.</exception>
    public SqlStore WithPrefix(string prefix)
    {
        try
        {
            return new SqlStore(_dataSource, _dialect, SqlText.TablePrefix(prefix));
        }
        catch (ArgumentException e)
        {
            throw CronwatchException.Invalid(e.Message);
        }
    }

    /// <summary>The prefix of the store's tables.</summary>
    public string Prefix => _prefix;

    /// <summary>The store's database: <c>sqlite</c>, <c>postgres</c> or <c>mysql</c> (MySQL and MariaDB).</summary>
    public string Dialect => _dialect switch
    {
        SqlDialect.Sqlite => "sqlite",
        SqlDialect.Postgres => "postgres",
        _ => "mysql",
    };

    /// <summary>Names the dialect and the prefix, never the data source, which may carry credentials.</summary>
    public override string ToString() => "SqlStore(" + Dialect + ", prefix " + _prefix + ")";

    // ---- connections

    private static TransactionScope Suppressed() =>
        new(TransactionScopeOption.Suppress, TransactionScopeAsyncFlowOption.Enabled);

    /// <summary>
    /// Runs <paramref name="work"/> on SQLite's kept connection, in turn, or on a connection of its
    /// own from the data source for Postgres, MySQL and MariaDB; every connection opened outside the app's ambient
    /// transaction.
    /// </summary>
    private async Task<T> WithAsync<T>(Func<DbConnection, Task<T>> work, CancellationToken ct)
    {
        if (_dialect == SqlDialect.Sqlite)
        {
            await _turn.WaitAsync(ct).ConfigureAwait(false);
            try
            {
                DbConnection c = await OpenAsync(ct).ConfigureAwait(false);
                try
                {
                    return await work(c).ConfigureAwait(false);
                }
                catch (DbException)
                {
                    // A connection that failed as a connection is let go, and the next statement
                    // opens another.
                    if (c.State != ConnectionState.Open)
                    {
                        _connection = null;
                        await c.DisposeAsync().ConfigureAwait(false);
                    }
                    throw;
                }
            }
            finally
            {
                _turn.Release();
            }
        }
        DbConnection conn;
        using (Suppressed())
        {
            conn = await _dataSource.OpenConnectionAsync(ct).ConfigureAwait(false);
        }
        await using (conn.ConfigureAwait(false))
        {
            return await work(conn).ConfigureAwait(false);
        }
    }

    /// <summary>
    /// SQLite's connection, opened with its pragmas on first use. No busy handler until WAL is on:
    /// switching journal mode can answer busy at once while another process is doing the same on
    /// a new file, so that is retried here. The connection is kept only once every pragma has gone
    /// through; a failed open is tried afresh next time.
    /// </summary>
    private async Task<DbConnection> OpenAsync(CancellationToken ct)
    {
        if (_connection is { State: ConnectionState.Open } kept)
        {
            return kept;
        }
        _connection = null;
        DbConnection opened;
        using (Suppressed())
        {
            opened = await _dataSource.OpenConnectionAsync(ct).ConfigureAwait(false);
        }
        try
        {
            await PragmaAsync(opened, "PRAGMA busy_timeout = 0", ct).ConfigureAwait(false);
            await WalAsync(opened, ct).ConfigureAwait(false);
            await PragmaAsync(opened, "PRAGMA busy_timeout = 5000", ct).ConfigureAwait(false);
            await PragmaAsync(opened, "PRAGMA synchronous = NORMAL", ct).ConfigureAwait(false);
        }
        catch
        {
            await opened.DisposeAsync().ConfigureAwait(false);
            throw;
        }
        _connection = opened;
        return opened;
    }

    private static async Task PragmaAsync(DbConnection c, string text, CancellationToken ct)
    {
        using DbCommand cmd = c.CreateCommand();
#pragma warning disable CA2100 // the pragmas are constants
        cmd.CommandText = text;
#pragma warning restore CA2100
        await cmd.ExecuteNonQueryAsync(ct).ConfigureAwait(false);
    }

    // Puts the connection in WAL mode, retrying while SQLite answers busy, with a short growing
    // pause, for up to two seconds in all (busy.ts retryBusy).
    private static async Task WalAsync(DbConnection c, CancellationToken ct)
    {
        long waited = 0;
        for (int attempt = 0; ; attempt++)
        {
            try
            {
                await PragmaAsync(c, "PRAGMA journal_mode = WAL", ct).ConfigureAwait(false);
                return;
            }
            catch (DbException e) when (Busy(e) && waited < (long)BusyRetry.TotalMilliseconds)
            {
                long pause = Math.Min(Math.Min(10L << Math.Min(attempt, 10), 200), (long)BusyRetry.TotalMilliseconds - waited);
                await Task.Delay(TimeSpan.FromMilliseconds(pause), ct).ConfigureAwait(false);
                waited += pause;
            }
        }
    }

    /// <summary>
    /// Whether SQLite answered SQLITE_BUSY or SQLITE_LOCKED (5 and 6, or an extended code of
    /// them). Microsoft.Data.Sqlite names the code in its message (<c>SQLite Error 5: ...</c>);
    /// <see cref="System.Runtime.InteropServices.ExternalException.ErrorCode"/> is the exception's
    /// HRESULT, E_FAIL (0x80004005), whose low byte would read as 5 for every error.
    /// </summary>
    internal static bool Busy(DbException e)
    {
        string text = e.Message;
        const string marker = "SQLite Error ";
        int at = text.IndexOf(marker, StringComparison.Ordinal);
        if (at >= 0)
        {
            int i = at + marker.Length;
            int code = 0;
            while (i < text.Length && text[i] >= '0' && text[i] <= '9' && code < 1_000_000)
            {
                code = code * 10 + (text[i] - '0');
                i++;
            }
            if ((code & 0xff) is 5 or 6)
            {
                return true;
            }
        }
        return text.Contains("SQLITE_BUSY", StringComparison.Ordinal)
            || text.Contains("SQLITE_LOCKED", StringComparison.Ordinal)
            || text.Contains("database is locked", StringComparison.Ordinal)
            || text.Contains("database table is locked", StringComparison.Ordinal);
    }

    /// <summary>A pragma's value on SQLite's kept connection, for the tests.</summary>
    internal Task<string> PragmaValueAsync(string name) => WithAsync(
        async c =>
        {
            using DbCommand cmd = c.CreateCommand();
#pragma warning disable CA2100 // the tests' own pragma names
            cmd.CommandText = "PRAGMA " + name;
#pragma warning restore CA2100
            object? v = await cmd.ExecuteScalarAsync().ConfigureAwait(false);
            return Convert.ToString(v, CultureInfo.InvariantCulture) ?? "";
        },
        default);

    // ---- parameters and rows

    /// <summary>A statement's parameter: text, a whole number, or JSON text; null for NULL.</summary>
    private readonly record struct Param(object? Value, bool IsText);

    private static Param Text(string? v) => new(v, true);

    private static Param Int(long? v) => new(v, false);

    private static Param JsonParam(string v) => new(v, true);

    private DbCommand Command(DbConnection c, string text, IReadOnlyList<Param> ps)
    {
        DbCommand cmd = c.CreateCommand();
#pragma warning disable CA2100 // statements are the store's own text, values are bound
        cmd.CommandText = text;
#pragma warning restore CA2100
        for (int i = 0; i < ps.Count; i++)
        {
            DbParameter p = cmd.CreateParameter();
            if (_dialect == SqlDialect.Sqlite)
            {
                p.ParameterName = "?" + (i + 1).ToString(CultureInfo.InvariantCulture);
            }
            var v = ps[i];
            if (v.Value == null)
            {
                p.DbType = v.IsText ? DbType.String : DbType.Int64;
                p.Value = DBNull.Value;
            }
            else if (v.IsText)
            {
                p.DbType = DbType.String;
                // A lone surrogate is written as U+FFFD, as a JavaScript string is written as UTF-8.
                p.Value = Js.WellFormed((string)v.Value);
            }
            else
            {
                p.DbType = DbType.Int64;
                p.Value = (long)v.Value;
            }
            cmd.Parameters.Add(p);
        }
        return cmd;
    }

    private async Task<long> UpdateAsync(DbConnection c, string text, IReadOnlyList<Param> ps, CancellationToken ct)
    {
        using DbCommand cmd = Command(c, text, ps);
        return await cmd.ExecuteNonQueryAsync(ct).ConfigureAwait(false);
    }

    private Task<long> RunAsync(string text, IReadOnlyList<Param> ps, CancellationToken ct) =>
        WithAsync(c => UpdateAsync(c, text, ps, ct), ct);

    /// <summary>Runs a query, answering its rows: each a map of lowercase column names to values.</summary>
    private Task<List<Dictionary<string, object>>> QueryAsync(string text, IReadOnlyList<Param> ps, CancellationToken ct) => WithAsync(
        async c =>
        {
            using DbCommand cmd = Command(c, text, ps);
            DbDataReader reader = await cmd.ExecuteReaderAsync(ct).ConfigureAwait(false);
            await using (reader.ConfigureAwait(false))
            {
                var rows = new List<Dictionary<string, object>>();
                while (await reader.ReadAsync(ct).ConfigureAwait(false))
                {
                    var row = new Dictionary<string, object>(StringComparer.Ordinal);
                    for (int i = 0; i < reader.FieldCount; i++)
                    {
                        if (await reader.IsDBNullAsync(i, ct).ConfigureAwait(false))
                        {
                            continue;
                        }
                        object v = reader.GetValue(i);
                        if (v is not (string or long or int or short or double or float or decimal or bool or byte[]))
                        {
                            // Postgres's jsonb and anything else unusual: its text.
                            v = reader.GetString(i);
                        }
                        row[reader.GetName(i).ToLowerInvariant()] = v;
                    }
                    rows.Add(row);
                }
                return rows;
            }
        },
        ct);

    /// <summary>A column as text, null for NULL.</summary>
    private static string? TextOf(Dictionary<string, object> row, string name) => row.TryGetValue(name, out object? v)
        ? v switch
        {
            double d => Json.Stringify(d),
            float f => Json.Stringify((double)f),
            long or int or short or decimal => Convert.ToString(v, CultureInfo.InvariantCulture),
            byte[] bytes => System.Text.Encoding.UTF8.GetString(bytes),
            _ => Convert.ToString(v, CultureInfo.InvariantCulture),
        }
        : null;

    /// <summary>
    /// A column as a whole number, null for NULL: text is read as a number, and a fraction is cut
    /// to its whole part, held at the ends of the range.
    /// </summary>
    private static long? IntegerOf(Dictionary<string, object> row, string name)
    {
        if (!row.TryGetValue(name, out object? v))
        {
            return null;
        }
        switch (v)
        {
            case long l:
                return l;
            case int i:
                return i;
            case short s:
                return s;
            case double d:
                return Js.ToLong(d);
            case float f:
                return Js.ToLong(f);
            case decimal m:
                return Js.ToLong((double)m);
            case bool b:
                return b ? 1 : 0;
            default:
                string t = Js.Trim(Convert.ToString(v, CultureInfo.InvariantCulture) ?? "");
                if (long.TryParse(t, NumberStyles.AllowLeadingSign, CultureInfo.InvariantCulture, out long parsed))
                {
                    return parsed;
                }
                return double.TryParse(t, NumberStyles.Float, CultureInfo.InvariantCulture, out double dd) ? Js.ToLong(dd) : 0;
        }
    }

    private static string TextOr(Dictionary<string, object> row, string name) => TextOf(row, name) ?? "";

    private static StoredJob JobOf(Dictionary<string, object> row)
    {
        string name = TextOr(row, "name");
        object? value;
        try
        {
            value = Json.Parse(TextOr(row, "definition"));
        }
        catch (JsonParseException e)
        {
            throw new InvalidOperationException("job " + name + ": " + e.Message, e);
        }
        // JSON of another shape (another writer's, or a hand edit) is a definition with nothing in
        // it, as the SDK reads it: one such row must not fail every read of the jobs.
        var definition = Definition.Own(value as JsObject ?? new JsObject());
        return new StoredJob(name, definition, IntegerOf(row, "created_at") ?? 0, IntegerOf(row, "updated_at") ?? 0);
    }

    private static Run RunOf(Dictionary<string, object> row)
    {
        string id = TextOr(row, "id");
        Metrics metrics = Metrics.Empty;
        string? metricsText = TextOf(row, "metrics");
        if (metricsText != null)
        {
            try
            {
                // Metrics another writer stored that are not all numbers keep the ones that are,
                // so one such row cannot fail the reads it is part of.
                metrics = Metrics.Lenient(Json.Parse(metricsText));
            }
            catch (JsonParseException e)
            {
                throw new InvalidOperationException("run " + id + ": " + e.Message, e);
            }
        }
        return new Run
        {
            Id = id,
            Job = TextOr(row, "job"),
            Status = new RunStatus(TextOr(row, "status")),
            StartedAt = IntegerOf(row, "started_at") ?? 0,
            FinishedAt = IntegerOf(row, "finished_at"),
            DurationMs = IntegerOf(row, "duration_ms"),
            Error = TextOf(row, "error"),
            Output = TextOf(row, "output"),
            Metrics = metrics,
            Trigger = TextOr(row, "trigger"),
        };
    }

    private async Task<IReadOnlyList<Run>> RunsAsync(string text, IReadOnlyList<Param> ps, CancellationToken ct)
    {
        var output = new List<Run>();
        foreach (var row in await QueryAsync(text, ps, ct).ConfigureAwait(false))
        {
            output.Add(RunOf(row));
        }
        return output;
    }

    /// <summary>Runs statements, each with <paramref name="ps"/>, in one transaction of the store's own.</summary>
    private Task TransactionAsync(IReadOnlyList<string> statements, IReadOnlyList<Param> ps, string? lockKey, CancellationToken ct) => WithAsync<bool>(
        async c =>
        {
            DbTransaction tx = await c.BeginTransactionAsync(ct).ConfigureAwait(false);
            await using (tx.ConfigureAwait(false))
            {
                if (lockKey != null)
                {
                    using DbCommand lk = Command(c, "SELECT pg_advisory_xact_lock(hashtext($1))", [Text(lockKey)]);
                    lk.Transaction = tx;
                    await lk.ExecuteNonQueryAsync(ct).ConfigureAwait(false);
                }
                foreach (string statement in statements)
                {
                    using DbCommand cmd = Command(c, statement, ps);
                    cmd.Transaction = tx;
                    await cmd.ExecuteNonQueryAsync(ct).ConfigureAwait(false);
                }
                await tx.CommitAsync(ct).ConfigureAwait(false);
            }
            return true;
        },
        ct);

    // Postgres refuses U+0000 in TEXT and JSONB, and a refused write loses the whole row, so every
    // dialect writes text without it: a run's trigger, output, error and metric names, and every
    // key and string of a definition and a state. Identifiers (a job's name, a run's id) are
    // written as given; the client refuses one with a NUL before it gets here.
    private static List<Param> InsertRunParams(Run r) =>
    [
        Text(r.Id), Text(r.Job), Text(r.Status.Value), Int(r.StartedAt), Int(r.FinishedAt), Int(r.DurationMs),
        Text(NulText.StripNulOrNull(r.Error)), Text(NulText.StripNulOrNull(r.Output)),
        JsonParam(NulText.StripJsonNul(r.Metrics.ToJson())), Text(NulText.StripNul(r.Trigger)),
    ];

    private static List<Param> UpdateRunParams(Run r) =>
    [
        Text(r.Status.Value), Int(r.FinishedAt), Int(r.DurationMs), Text(NulText.StripNulOrNull(r.Error)),
        Text(NulText.StripNulOrNull(r.Output)), JsonParam(NulText.StripJsonNul(r.Metrics.ToJson())), Text(r.Id),
    ];

    // ---- the store

    /// <summary>
    /// Makes the tables. On Postgres many processes starting at once would race <c>CREATE TABLE IF
    /// NOT EXISTS</c>, so they take turns under an advisory lock per prefix, in one transaction.
    /// </summary>
    public async Task InitAsync(CancellationToken cancellationToken = default)
    {
        var statements = SqlText.Schema(_dialect, _prefix);
        if (_dialect == SqlDialect.Postgres)
        {
            await TransactionAsync(statements, [], "cronwatch:" + _prefix, cancellationToken).ConfigureAwait(false);
            return;
        }
        await WithAsync<bool>(
            async c =>
            {
                foreach (string statement in statements)
                {
                    await UpdateAsync(c, statement, [], cancellationToken).ConfigureAwait(false);
                }
                return true;
            },
            cancellationToken).ConfigureAwait(false);
    }

    /// <inheritdoc/>
    public Task UpsertJobAsync(Definition definition, long now, CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(definition);
        return RunAsync(_sql.UpsertJob, [Text(definition.Name), JsonParam(NulText.StripJsonNul(definition.ToJson())), Int(now), Int(now)], cancellationToken);
    }

    /// <inheritdoc/>
    public async Task<StoredJob?> GetJobAsync(string name, CancellationToken cancellationToken = default)
    {
        var rows = await QueryAsync(_sql.GetJob, [Text(name)], cancellationToken).ConfigureAwait(false);
        return rows.Count == 0 ? null : JobOf(rows[0]);
    }

    /// <inheritdoc/>
    public async Task<IReadOnlyList<StoredJob>> ListJobsAsync(CancellationToken cancellationToken = default)
    {
        var output = new List<StoredJob>();
        foreach (var row in await QueryAsync(_sql.ListJobs, [], cancellationToken).ConfigureAwait(false))
        {
            output.Add(JobOf(row));
        }
        return output;
    }

    /// <summary>Removes the job, its runs and its state in one transaction.</summary>
    public Task DeleteJobAsync(string name, CancellationToken cancellationToken = default) =>
        TransactionAsync([_sql.DeleteRuns, _sql.DeleteState, _sql.DeleteJob], [Text(name)], null, cancellationToken);

    /// <inheritdoc/>
    public Task InsertRunAsync(Run run, CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(run);
        Run r = run;
        if (_dialect == SqlDialect.MySql)
        {
            // MySQL's trigger column is VARCHAR(255), which refuses anything longer (the others
            // are TEXT): a long trigger is cut to 255 characters on a code point to fit rather
            // than lose the whole run.
            string trigger = NulText.StripNul(r.Trigger);
            int end = CodePointEnd(trigger, 255);
            if (end < trigger.Length)
            {
                r = r with { Trigger = trigger[..end] };
            }
        }
        return RunAsync(_sql.InsertRun, InsertRunParams(r), cancellationToken);
    }

    /// <summary>Where the first <paramref name="count"/> code points of the text end.</summary>
    private static int CodePointEnd(string text, int count)
    {
        int i = 0;
        for (int n = 0; n < count && i < text.Length; n++)
        {
            i += char.IsHighSurrogate(text[i]) && i + 1 < text.Length && char.IsLowSurrogate(text[i + 1]) ? 2 : 1;
        }
        return i;
    }

    /// <inheritdoc/>
    public Task UpdateRunAsync(Run run, CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(run);
        return RunAsync(_sql.UpdateRun, UpdateRunParams(run), cancellationToken);
    }

    /// <inheritdoc/>
    public async Task<bool> UpdateRunIfAsync(Run run, IReadOnlyList<RunStatus> from, CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(run);
        ArgumentNullException.ThrowIfNull(from);
        if (from.Count == 0)
        {
            return false;
        }
        var ps = UpdateRunParams(run);
        foreach (var s in from)
        {
            ps.Add(Text(s.Value));
        }
        if (await RunAsync(_sql.UpdateRunIf(from.Count), ps, cancellationToken).ConfigureAwait(false) > 0)
        {
            return true;
        }
        return _dialect == SqlDialect.MySql && await LandedAsync(run, from, cancellationToken).ConfigureAwait(false);
    }

    /// <summary>
    /// Whether an update of a run that MySQL answered 0 for landed all the same: a connection that
    /// counts only the rows an UPDATE changed answers 0 for a row that already held these values
    /// (and matched). The stored run is read back and compared with what was written, metrics
    /// whatever order their keys came back in.
    /// </summary>
    private async Task<bool> LandedAsync(Run run, IReadOnlyList<RunStatus> from, CancellationToken ct)
    {
        Run? stored = await GetRunAsync(run.Id, ct).ConfigureAwait(false);
        if (stored == null || !stored.Status.Equals(run.Status))
        {
            return false;
        }
        bool among = false;
        foreach (var s in from)
        {
            among |= s.Equals(stored.Status);
        }
        return among
            && stored.FinishedAt == run.FinishedAt
            && stored.DurationMs == run.DurationMs
            && stored.Error == Written(run.Error)
            && stored.Output == Written(run.Output)
            && SameMetrics(stored.Metrics, run.Metrics);
    }

    /// <summary>Text as the store writes it: well formed, without U+0000.</summary>
    private static string? Written(string? text) => text == null ? null : NulText.StripNul(Js.WellFormed(text));

    private static bool SameMetrics(Metrics stored, Metrics sent)
    {
        var want = new Dictionary<string, double>(StringComparer.Ordinal);
        foreach (var m in sent)
        {
            want[NulText.StripNul(Js.WellFormed(m.Key))] = m.Value;
        }
        if (want.Count != stored.Count)
        {
            return false;
        }
        foreach (var m in stored)
        {
            if (!want.TryGetValue(m.Key, out double v) || !v.Equals(m.Value))
            {
                return false;
            }
        }
        return true;
    }

    /// <summary>Deletes a run only while it is of <paramref name="job"/> and in <paramref name="status"/>, in one statement.</summary>
    public async Task<bool> DeleteRunIfAsync(string id, string job, RunStatus status, CancellationToken cancellationToken = default) =>
        await RunAsync(_sql.DeleteRunIf, [Text(id), Text(job), Text(status.Value)], cancellationToken).ConfigureAwait(false) > 0;

    /// <inheritdoc/>
    public async Task<Run?> GetRunAsync(string id, CancellationToken cancellationToken = default)
    {
        var output = await RunsAsync(_sql.GetRun, [Text(id)], cancellationToken).ConfigureAwait(false);
        return output.Count == 0 ? null : output[0];
    }

    /// <inheritdoc/>
    public Task<IReadOnlyList<Run>> ListRunsAsync(string job, int limit, CancellationToken cancellationToken = default) =>
        RunsAsync(_sql.ListRuns, [Text(job), Int(limit)], cancellationToken);

    /// <inheritdoc/>
    public async Task<Run?> LastRunAsync(string job, CancellationToken cancellationToken = default)
    {
        var output = await ListRunsAsync(job, 1, cancellationToken).ConfigureAwait(false);
        return output.Count == 0 ? null : output[0];
    }

    /// <inheritdoc/>
    public Task<IReadOnlyList<Run>> RunningRunsAsync(CancellationToken cancellationToken = default) =>
        RunsAsync(_sql.RunningRuns, [], cancellationToken);

    /// <summary>The job's state. A state that is not JSON, or not an object, fails the read.</summary>
    public async Task<JobState?> GetStateAsync(string job, CancellationToken cancellationToken = default)
    {
        var rows = await QueryAsync(_sql.GetState, [Text(job)], cancellationToken).ConfigureAwait(false);
        return rows.Count == 0 ? null : JobState.FromJson(TextOr(rows[0], "state"));
    }

    /// <inheritdoc/>
    public Task SetStateAsync(JobState state, CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(state);
        return RunAsync(_sql.SetState, [Text(state.Job), JsonParam(NulText.StripJsonNul(state.ToJson()))], cancellationToken);
    }

    /// <inheritdoc/>
    public async Task<bool> CompareAndSetStateAsync(JobState state, long expected, CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(state);
        string body = NulText.StripJsonNul(state.ToJson());
        if (_dialect == SqlDialect.MySql && expected == 0)
        {
            return await CasFromZeroAsync(state.Job, body, cancellationToken).ConfigureAwait(false);
        }
        if (expected != 0)
        {
            return await RunAsync(_sql.CasUpdate, [JsonParam(body), Text(state.Job), Int(expected)], cancellationToken).ConfigureAwait(false) > 0;
        }
        return await RunAsync(_sql.CasInsert, [Text(state.Job), JsonParam(body)], cancellationToken).ConfigureAwait(false) > 0;
    }

    /// <summary>
    /// MySQL's compare-and-set from version 0, in two steps that each decide alone: a row at
    /// version 0 (or without one) is updated, and failing that the row is inserted, which a row
    /// already there refuses. A refused insert is another process's write, unless the row holds
    /// exactly what this write sent, when the write landed and only its answer was lost (a row at
    /// version 0 that already held these values, which a connection counting changed rows answers
    /// 0 for, or a connection dropped after the commit), as the PHP port's <c>stateLanded()</c>
    /// reads it.
    /// </summary>
    private async Task<bool> CasFromZeroAsync(string job, string body, CancellationToken ct)
    {
        if (await RunAsync(_sql.CasFromZero, [JsonParam(body), Text(job)], ct).ConfigureAwait(false) > 0)
        {
            return true;
        }
        try
        {
            await RunAsync(_sql.CasInsert, [Text(job), JsonParam(body)], ct).ConfigureAwait(false);
            return true;
        }
        catch (DbException)
        {
            JobState? stored = await GetStateAsync(job, ct).ConfigureAwait(false);
            if (stored == null)
            {
                throw;
            }
            return stored.ToJson() == Js.WellFormed(body);
        }
    }

    /// <inheritdoc/>
    public Task<long> PruneAsync(long before, CancellationToken cancellationToken = default) =>
        RunAsync(_sql.Prune, [Int(before)], cancellationToken);

    /// <summary>
    /// Closes SQLite's connection, which the next use opens again. The data source is the app's,
    /// and stays open.
    /// </summary>
    public async ValueTask DisposeAsync()
    {
        await _turn.WaitAsync().ConfigureAwait(false);
        try
        {
            DbConnection? c = _connection;
            _connection = null;
            if (c != null)
            {
                await c.DisposeAsync().ConfigureAwait(false);
            }
        }
        finally
        {
            _turn.Release();
        }
    }
}
