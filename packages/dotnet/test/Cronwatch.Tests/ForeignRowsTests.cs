using System;
using System.Collections.Generic;
using System.Linq;
using System.Threading.Tasks;
using Cronwatch.Internal;
using Cronwatch.Web;
using Microsoft.Data.Sqlite;
using Xunit;

namespace Cronwatch.Tests;

/// <summary>
/// <c>conformance/store.json</c>'s <c>foreignRows</c> on SQLite: rows another writer left (a
/// definition, metrics, or state that is not JSON or not an object, times stored as text, a queued
/// alert of the wrong shape) are each read leniently, and affect only their own job: a check, a
/// silence, and every page over all of them at once report only the jobs whose definitions cannot
/// be read, and answer as the SDK does.
/// </summary>
public class ForeignRowsTests
{
    private static readonly string[] JobColumns = ["name", "definition", "created_at", "updated_at"];

    private static readonly string[] RunColumns = ["id", "job", "status", "started_at", "finished_at", "duration_ms", "error", "output", "metrics", "trigger"];

    private static readonly string[] StateColumns = ["job", "state"];

    private static JsObject Fixture => Fixtures.Object(Fixtures.Load("store"), "foreignRows");

    /// <summary>A fixture value as SQLite holds it: a whole number as an INTEGER, another as a REAL.</summary>
    private static object Sql(object? v) => v switch
    {
        null => DBNull.Value,
        double d when Math.Floor(d) == d && Math.Abs(d) < 9007199254740992 => (long)d,
        _ => v,
    };

    /// <summary>Writes one row, each column's value as given, as another writer would.</summary>
    private static async Task Insert(string file, string table, JsObject row)
    {
        string[] columns = table switch
        {
            "jobs" => JobColumns,
            "runs" => RunColumns,
            _ => StateColumns,
        };
        await using var c = new SqliteConnection("Data Source=" + file + ";Pooling=False");
        await c.OpenAsync();
        using var cmd = c.CreateCommand();
        cmd.CommandText = "INSERT INTO cronwatch_" + table + " (" + string.Join(", ", columns) + ") VALUES ("
            + string.Join(", ", columns.Select((_, i) => "$v" + i)) + ")";
        for (int i = 0; i < columns.Length; i++)
        {
            cmd.Parameters.AddWithValue("$v" + i, Sql(row.Get(columns[i])));
        }
        await cmd.ExecuteNonQueryAsync();
    }

    /// <summary>A state row's text as stored, parsed.</summary>
    private static async Task<object?> RawState(string file, string job)
    {
        await using var c = new SqliteConnection("Data Source=" + file + ";Pooling=False");
        await c.OpenAsync();
        using var cmd = c.CreateCommand();
        cmd.CommandText = "SELECT state FROM cronwatch_state WHERE job = $job";
        cmd.Parameters.AddWithValue("$job", job);
        object? text = await cmd.ExecuteScalarAsync();
        return text is string s ? Json.Parse(s) : null;
    }

    private static JsObject Read(StoredJob job) => new JsObject()
        .Set("name", job.Name)
        .Set("definition", job.Definition.ToObject())
        .Set("createdAt", job.CreatedAt)
        .Set("updatedAt", job.UpdatedAt);

    [Fact]
    public async Task Each_foreign_row_reads_leniently()
    {
        var fails = new Fixtures.Failures();
        int i = 0;
        foreach (JsObject c in Fixtures.Objects(Fixture, "rows"))
        {
            string table = Fixtures.String(c, "table")!;
            JsObject row = Fixtures.Object(c, "row");
            string what = "rows " + i++ + " (" + table + ")";
            using var dir = new TempDir();
            string file = dir.File("foreign.db");
            var store = SqlStore.Sqlite(StoreTests.Sqlite(file));
            await using (store)
            {
                await store.InitAsync();
                await Insert(file, table, row);
                if (table == "jobs")
                {
                    string name = Fixtures.String(row, "name")!;
                    StoredJob got = CronwatchClient.ReadStoredJob((await store.GetJobAsync(name))!);
                    fails.Same(what + " got", Read(got), c.Get("read"));
                    StoredJob listed = CronwatchClient.ReadStoredJob(Assert.Single(await store.ListJobsAsync()));
                    fails.Same(what + " listed", Read(listed), c.Get("read"));
                    bool readable = c.Get("readable") is not false;
                    fails.Same(what + " readable", !got.Definition.Unreadable, readable);
                }
                else if (table == "runs")
                {
                    string id = Fixtures.String(row, "id")!;
                    fails.Same(what + " getRun", (await store.GetRunAsync(id))!.ToValue(), c.Get("read"));
                    Run listed = Assert.Single(await store.ListRunsAsync(Fixtures.String(row, "job")!, 10));
                    fails.Same(what + " listRuns", listed.ToValue(), c.Get("read"));
                }
                else
                {
                    string job = Fixtures.String(row, "job")!;
                    fails.Same(what, Evaluate.NormalizeState(await store.GetStateAsync(job), job).ToValue(), c.Get("read"));
                }
            }
        }
        Assert.True(fails.Compared > 0);
        fails.Check("store foreignRows.rows");
    }

    /// <summary>The job each error was reported for: its where ends in the job's name.</summary>
    private static List<string> Reported(Support.Errors errors) =>
        errors.Wheres().Select(w => w[(w.LastIndexOf(' ') + 1)..]).Distinct().Order(StringComparer.Ordinal).ToList();

    [Fact]
    public async Task A_check_a_silence_and_every_page_over_foreign_rows()
    {
        JsObject f = Fixture;
        JsObject check = Fixtures.Object(f, "check");
        using var dir = new TempDir();
        string file = dir.File("foreign.db");
        var store = SqlStore.Sqlite(StoreTests.Sqlite(file));
        await store.InitAsync();
        foreach (JsObject c in Fixtures.Objects(f, "rows"))
        {
            await Insert(file, Fixtures.String(c, "table")!, Fixtures.Object(c, "row"));
        }
        foreach (JsObject row in Fixtures.Objects(check, "extraJobs"))
        {
            await Insert(file, "jobs", row);
        }
        foreach (JsObject row in Fixtures.Objects(check, "extraRuns"))
        {
            await Insert(file, "runs", row);
        }
        var fails = new Fixtures.Failures();
        await using var m = Support.Make(store: store, clock: Support.Clock(Fixtures.Integer(check, "now")));

        // 1. The check: only the jobs whose definitions cannot be read are reported.
        CheckResult result = await m.Cw.CheckAsync();
        fails.Same("reported", Reported(m.Errors), check.Get("reported"));
        var alerts = m.Alerts.List().Select(a => (object?)new JsObject().Set("type", a.Type.Value).Set("job", a.Job).Set("at", a.At)).ToList();
        fails.Same("alerts", alerts, check.Get("alerts"));
        var health = new JsObject();
        foreach (JobSummary job in result.Jobs.OrderBy(j => j.Name, StringComparer.Ordinal))
        {
            health.Set(job.Name, job.Health.Value);
        }
        fails.Same("health", health, check.Get("health"));

        // 2. A silence over a state row that is not JSON: nothing reported, the row replaced.
        JsObject silence = Fixtures.Object(check, "silence");
        int before = m.Errors.Entries.Count;
        string silenced = Fixtures.String(silence, "job")!;
        await m.Cw.SilenceAsync(silenced, Fixtures.String(silence, "for")!);
        fails.Same("silence reported", m.Errors.Wheres().Skip(before).ToList(), silence.Get("reported"));
        fails.Same("silence state", await RawState(file, silenced), silence.Get("state"));

        // 3. Every state row as stored: one a read changed nothing in is still the foreign value.
        foreach (var e in Fixtures.Object(check, "states"))
        {
            fails.Same("state " + e.Key, await RawState(file, e.Key), e.Value);
        }

        // 4. Every page answers, and only the unreadable jobs are reported.
        JsObject read = Fixtures.Object(check, "read");
        m.Errors.Entries.Clear();
        Routes routes = m.Cw.Routes(new RoutesOptions { Token = "tok" });
        foreach (JsObject page in Fixtures.Objects(read, "pages"))
        {
            string path = Fixtures.String(page, "path")!;
            CronwatchResponse answer = await routes.HandleAsync(new CronwatchRequest("GET", path)
            {
                Headers = [new("host", "app.test"), new("authorization", "Bearer tok")],
            });
            fails.Same("page " + path, (double)answer.Status, page.Get("status"));
        }
        fails.Same("read reported", Reported(m.Errors), read.Get("reported"));
        Assert.True(fails.Compared > 0);
        fails.Check("store foreignRows.check");
    }
}
