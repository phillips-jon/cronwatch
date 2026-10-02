using System;
using System.Collections.Generic;
using System.Linq;
using System.Security.Cryptography;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using Cronwatch.Bridge;
using Cronwatch.Internal;
using Xunit;
using static Cronwatch.Tests.Support;

namespace Cronwatch.Tests;

/// <summary>The bridge the integrations share: the Java port's <c>BridgeTest</c>, with every audit's cases.</summary>
public class BridgeTests
{
    private static readonly TimeSpan Settle = TimeSpan.FromSeconds(30);

    [Fact]
    public void The_app_tag_is_the_php_ports()
    {
        string x39 = new('x', 39);
        var cases = new Dictionary<string, string>
        {
            ["Billing"] = "laravel-scheduler:billing",
            ["  My App! v2 "] = "laravel-scheduler:my-app-v2",
            ["acme_web.prod-1"] = "laravel-scheduler:acme_web.prod-1",
            ["!!!"] = "laravel-scheduler:6dd07555",
            [new string('x', 50)] = "laravel-scheduler:" + x39 + "-62f01267",
            ["\u00dcn\u00efcode \u00c4pp"] = "laravel-scheduler:n-code-pp",
            ["\u212a"] = "laravel-scheduler:f7781178",
        };
        foreach (var c in cases)
        {
            Assert.Equal(c.Value, SchedulerBridge.AppTag("laravel-scheduler", c.Key));
        }
        // The PHP port's own cases.
        Assert.Equal("fw:laravel", SchedulerBridge.AppTag("fw", "Laravel"));
        Assert.Equal("fw:billing-api", SchedulerBridge.AppTag("fw", "  Billing API! "));
        Assert.Equal("fw:app-1d4ce23f0a88", SchedulerBridge.AppTag("fw", "app-1d4ce23f0a88"));
        Assert.Equal("fw:" + Md5("\u00c9\u00c9")[..8], SchedulerBridge.AppTag("fw", "\u00c9\u00c9"));
        string longName = new string('x', 60) + "!";
        Assert.Equal("fw:" + x39 + "-" + Md5(longName)[..8], SchedulerBridge.AppTag("fw", longName));
    }

    private static string Md5(string s) => Convert.ToHexStringLower(MD5.HashData(Encoding.UTF8.GetBytes(s)));

    [Fact]
    public void The_app_name_comes_from_the_fallback_or_the_entry_assembly()
    {
        if (Environment.GetEnvironmentVariable("CRONWATCH_APP_ID") != null)
        {
            return; // the variable wins, and the process's environment is every test's
        }
        Assert.Equal("billing", SchedulerBridge.AppName(" billing "));
        Assert.False(string.IsNullOrEmpty(SchedulerBridge.AppName()));
    }

    [Fact]
    public void Every_text_is_exact_to_the_millisecond()
    {
        Assert.Equal("every 1h30m", SchedulerBridge.EveryText(TimeSpan.FromMinutes(90)));
        Assert.Equal("every 1d12h1s500ms", SchedulerBridge.EveryText(TimeSpan.FromMilliseconds((36 * 3_600_000L) + 1500)));
        Assert.Equal("every 0ms", SchedulerBridge.EveryText(TimeSpan.Zero));
        Assert.Equal("every 1ms", SchedulerBridge.EveryText(TimeSpan.FromTicks(6000)));
    }

    [Fact]
    public void Valid_names_are_the_clients()
    {
        Assert.True(SchedulerBridge.ValidName("NightlyReports.build"));
        Assert.False(SchedulerBridge.ValidName("Outer+Inner.Run"));
        Assert.False(SchedulerBridge.ValidName(new string('x', 121)));
    }

    /// <summary>A scheduler that runs at hour:00 UTC every <paramref name="step"/> days from the epoch.</summary>
    private static FireTimes Daily(long hour, long step) => (start, end) =>
    {
        long day = Js.FloorDiv(start, 86_400_000L);
        while (At(day, hour) > start || day % step != 0)
        {
            day--;
        }
        var output = new List<long> { At(day, hour) };
        while (true)
        {
            day += step;
            output.Add(At(day, hour));
            if ((end == null && output.Count > SchedulerBridge.SampleRuns) || (end is long e && At(day, hour) > e))
            {
                return output;
            }
        }
    };

    private static long At(long day, long hour) => (day * 86_400_000L) + (hour * 3_600_000L);

    [Fact]
    public void Check_fires_compares_the_schedulers_own_runs()
    {
        long now = Js.DateUtc(2026, 8, 1, 0, 0, 0, 0);
        SchedulerBridge.CheckFires(Daily(2, 1), "0 2 * * *", "UTC", "x", "a scheduler", true, now);
        var e = Assert.Throws<ScheduleException>(() => SchedulerBridge.CheckFires(Daily(2, 2), "0 2 * * *", "UTC", "cronwatch: x", "a scheduler", true, now));
        Assert.Contains("cronwatch: x is \"0 2 * * *\" in UTC, but after a run at", e.Message, StringComparison.Ordinal);
        Assert.Contains("a scheduler runs it next at", e.Message, StringComparison.Ordinal);
        Assert.Throws<ScheduleException>(() => SchedulerBridge.CheckFires(Daily(3, 1), "0 2 * * *", "UTC", "x", "a scheduler", true, now));
        FireTimes never = (start, end) => throw ScheduleException.NeverFires("no fire time");
        e = Assert.Throws<ScheduleException>(() => SchedulerBridge.CheckFires(never, "0 2 * * *", "UTC", "x", "a scheduler", true, now));
        Assert.EndsWith("which never fires: no fire time", e.Message, StringComparison.Ordinal);
        e = Assert.Throws<ScheduleException>(() => SchedulerBridge.CheckFires(Daily(2, 1), "not a cron", "UTC", "x", "a scheduler", true, now));
        Assert.Contains("which CronWatch cannot read", e.Message, StringComparison.Ordinal);
    }

    [Fact]
    public void Walking_finds_the_fire_at_or_before_and_the_ones_after()
    {
        // A scheduler that fires on every whole hour, asked only for the next one.
        FireTimes hourly = SchedulerBridge.Walking(at => (Js.FloorDiv(at, 3_600_000L) * 3_600_000L) + 3_600_000L, "hourly");
        long start = Js.DateUtc(2026, 0, 1, 5, 30, 0, 0);
        var runs = hourly(start, null);
        Assert.Equal(SchedulerBridge.SampleRuns + 1, runs.Count);
        Assert.Equal(Js.DateUtc(2026, 0, 1, 5, 0, 0, 0), runs[0]);
        Assert.Equal(Js.DateUtc(2026, 0, 1, 6, 0, 0, 0), runs[1]);
        var until = hourly(start, Js.DateUtc(2026, 0, 1, 8, 0, 0, 0));
        Assert.Equal(Js.DateUtc(2026, 0, 1, 9, 0, 0, 0), until[^1]);
        SchedulerBridge.CheckFires(hourly, "0 * * * *", "UTC", "x", "hourly", true, start);
        FireTimes never = SchedulerBridge.Walking(_ => null, "Nothing");
        var e = Assert.Throws<ScheduleException>(() => never(start, null));
        Assert.StartsWith("Nothing finds no fire time after ", e.Message, StringComparison.Ordinal);
    }

    [Fact]
    public void Check_fires_names_a_time_the_clock_change_skips()
    {
        // A scheduler that skips 02:30 in New York the night clocks go forward, where CronWatch
        // (croner) moves it past the jump.
        TimeZoneInfo ny = CronZones.Find("America/New_York")!;
        ParsedSchedule cron = Schedules.Parse("30 2 * * *", "America/New_York");
        FireTimes runs = (start, end) =>
        {
            var output = new List<long>();
            long at = start - (3 * 86_400_000L);
            while (true)
            {
                if (Schedules.NextFire(cron, at, null) is not long fire)
                {
                    return output;
                }
                at = fire;
                if (CronZones.WallAt(fire / 1000, ny)[3] != 2)
                {
                    continue; // the moved fire: this scheduler skips the day
                }
                if (fire <= start)
                {
                    output.Clear();
                }
                output.Add(fire);
                if ((end == null && output.Count > SchedulerBridge.SampleRuns) || (end is long e && fire > e))
                {
                    return output;
                }
            }
        };
        long now = Js.DateUtc(2026, 8, 1, 0, 0, 0, 0);
        var ex = Assert.Throws<ScheduleException>(() => SchedulerBridge.CheckFires(runs, "30 2 * * *", "America/New_York", "job", "a scheduler", true, now));
        Assert.Contains(
            "due at a time that does not exist in America/New_York on 2026-03-08, when clocks go forward from 02:00 to 03:00",
            ex.Message,
            StringComparison.Ordinal);
    }

    [Fact]
    public void A_cron_is_walked_once_per_job_expression_zone_and_year()
    {
        var checks = new FireTimeChecks();
        long now = Js.DateUtc(2026, 8, 1, 0, 0, 0, 0);
        int walked = 0;
        string Walk()
        {
            walked++;
            return "0 2 * * *";
        }
        Assert.Equal(("0 2 * * *", (string?)null), checks.Check("a", "0 0 2 * * ?", "UTC", now, Walk));
        Assert.Equal(("0 2 * * *", (string?)null), checks.Check("a", "0 0 2 * * ?", "UTC", now + 60_000, Walk));
        checks.EndRead();
        Assert.Equal(1, walked);
        checks.Check("a", "0 0 2 * * ?", "UTC", Js.DateUtc(2027, 0, 1, 0, 0, 0, 0), Walk);
        Assert.Equal(2, walked);
        var problem = checks.Check("b", "x", "UTC", now, () => throw new ScheduleException("cannot"));
        Assert.Equal((null, "cannot"), problem);
        checks.EndRead();
        // What the last read did not ask about is dropped.
        checks.EndRead();
        checks.Check("a", "0 0 2 * * ?", "UTC", now, Walk);
        Assert.Equal(3, walked);
        Assert.Equal(4, checks.Walks);
    }

    [Fact]
    public void Overlapping_reads_keep_what_either_asked_about()
    {
        var checks = new FireTimeChecks();
        long now = Js.DateUtc(2026, 8, 1, 0, 0, 0, 0);
        string Walk() => "0 2 * * *";
        // A read loop and a check job read at once: the one that ends first drops nothing the
        // other has asked about, so the next read walks nothing again.
        checks.BeginRead();
        checks.Check("a", "0 0 2 * * ?", "UTC", now, Walk);
        checks.BeginRead();
        checks.Check("a", "0 0 2 * * ?", "UTC", now, Walk);
        checks.Check("b", "0 0 3 * * ?", "UTC", now, Walk);
        checks.EndRead();
        checks.Check("b", "0 0 3 * * ?", "UTC", now, Walk);
        checks.Check("c", "0 0 4 * * ?", "UTC", now, Walk);
        checks.EndRead();
        Assert.Equal(3, checks.Walks);
        checks.BeginRead();
        foreach (string job in new[] { "a", "b", "c" })
        {
            checks.Check(job, "0 0 " + (job[0] - 'a' + 2) + " * * ?", "UTC", now, Walk);
        }
        checks.EndRead();
        Assert.Equal(3, checks.Walks);
        // Once every read has ended, what the last ones did not ask about is dropped.
        checks.BeginRead();
        checks.Check("a", "0 0 2 * * ?", "UTC", now, Walk);
        checks.EndRead();
        checks.BeginRead();
        checks.Check("b", "0 0 3 * * ?", "UTC", now, Walk);
        checks.EndRead();
        Assert.Equal(4, checks.Walks);
    }

    private static Entry E(string name, string label, string schedule) => new(name, label, schedule, "");

    private static async Task<string> Stored(IStore store, string name)
    {
        StoredJob? job = await store.GetJobAsync(name);
        Assert.True(job != null, name + " is not stored");
        return job.Definition.ToJson();
    }

    [Fact]
    public async Task A_watch_declares_entries_and_unschedules_the_gone()
    {
        await using var m = Make();
        var w = new Watch(m.Cw, "gocron", "billing", "gocron");
        var nightly = new Entry("nightly", "entry 1", "0 2 * * *", "UTC", null, new JobOptions { Grace = "5m" }, new JobOptions { Budget = { ["cost"] = 2 }, Floor = { ["rows"] = 1 }, Tags = ["reports"] });
        var odd = new Entry("odd", "entry 4", "", "", "cronwatch: entry 4 cannot be read");
        w.Declare([nightly, E("twice", "entry 2", "0 3 * * *"), E("twice", "entry 3", "0 4 * * *"), odd]);
        await m.Cw.CheckAsync();
        Assert.Equal(
            "{\"grace\":\"5m\",\"schedule\":\"0 2 * * *\",\"timezone\":\"UTC\",\"budget\":{\"cost\":2},\"floor\":{\"rows\":1},\"tags\":[\"reports\",\"gocron\",\"gocron:billing\"],\"name\":\"nightly\"}",
            await Stored(m.Store, "nightly"));
        Assert.Equal("{\"tags\":[\"gocron\",\"gocron:billing\"],\"name\":\"twice\"}", await Stored(m.Store, "twice"));
        Assert.Equal("{\"tags\":[\"gocron\",\"gocron:billing\"],\"name\":\"odd\"}", await Stored(m.Store, "odd"));
        Assert.Equal(
            "declaring entry 2: cronwatch: \"twice\" is run by 2 gocron entries on different schedules (0 3 * * *; 0 4 * * *), so it is watched without a schedule; give each a name of its own\n"
            + "declaring entry 4: cronwatch: entry 4 cannot be read",
            string.Join("\n", m.Errors.Entries.Select(e => e.Where + ": " + e.Error.Message)));

        // Declaring again changes nothing and reports nothing again; an entry gone keeps its runs
        // and loses its schedule.
        Job first = w.Job("nightly")!;
        w.Declare([nightly, E("twice", "entry 2", "0 3 * * *"), E("twice", "entry 3", "0 4 * * *")]);
        Assert.Same(first, w.Job("nightly"));
        Assert.Equal(2, m.Errors.Entries.Count);
        w.Declare([]);
        Assert.True(await w.SettleAsync(Settle));
        await m.Cw.CheckAsync();
        Assert.Equal(
            "{\"description\":\"A scheduled task (no longer scheduled)\",\"tags\":[\"reports\",\"gocron\",\"gocron:billing\"],\"grace\":\"5m\",\"budget\":{\"cost\":2},\"floor\":{\"rows\":1},\"name\":\"nightly\"}",
            await Stored(m.Store, "nightly"));
    }

    [Fact]
    public async Task A_job_forgotten_from_the_dashboard_is_declared_again_at_the_watchs_next_read()
    {
        await using var m = Make();
        var w = new Watch(m.Cw, "gocron", "billing", "gocron");
        w.Declare([E("nightly", "entry 1", "0 2 * * *")]);
        Assert.True(await w.SettleAsync(Settle));
        await m.Cw.ForgetAsync("nightly");
        Assert.Null(await m.Store.GetJobAsync("nightly"));

        // The scheduler still runs it, unchanged: the next read declares it again, with its
        // schedule, rather than taking it for unchanged, and a check keeps it.
        w.Declare([E("nightly", "entry 1", "0 2 * * *")]);
        Assert.True(await w.SettleAsync(Settle));
        Assert.True(w.Declares("nightly"));
        Assert.Contains("\"schedule\":\"0 2 * * *\"", await Stored(m.Store, "nightly"), StringComparison.Ordinal);
        await m.Cw.CheckAsync();
        Assert.Contains("\"schedule\":\"0 2 * * *\"", await Stored(m.Store, "nightly"), StringComparison.Ordinal);
    }

    [Fact]
    public async Task Unschedule_takes_only_this_apps_jobs()
    {
        var store = new MemoryStore();
        await using (var earlier = Make(store))
        {
            foreach (var (name, tag) in new[] { ("invoices", "gocron:billing"), ("dunning", "gocron:billing"), ("reindex", "gocron:search") })
            {
                earlier.Cw.Job(name, new JobOptions { Schedule = "0 1 * * *", Tags = ["gocron", tag], Timeout = "2h", Description = "Bills" });
            }
            await earlier.Cw.CheckAsync();
        }
        await using var m = Make(store);
        var w = new Watch(m.Cw, "gocron", "billing", "gocron");
        Assert.Empty(await w.UnscheduleAsync());
        w.Declare([E("invoices", "x", "0 1 * * *")]);
        Assert.Equal(["dunning"], await w.UnscheduleAsync());
        // Written without a check (the Go audit: a process that never checks left the schedule
        // in the store).
        Assert.Contains("no longer scheduled", await Stored(store, "dunning"), StringComparison.Ordinal);
        await m.Cw.CheckAsync();
        Assert.Equal(
            "{\"description\":\"Bills (no longer scheduled)\",\"tags\":[\"gocron\",\"gocron:billing\"],\"timeout\":\"2h\",\"name\":\"dunning\"}",
            await Stored(store, "dunning"));
        Assert.Contains("\"schedule\":\"0 1 * * *\"", await Stored(store, "reindex"), StringComparison.Ordinal);
        Assert.Contains("\"schedule\":\"0 1 * * *\"", await Stored(store, "invoices"), StringComparison.Ordinal);
    }

    [Fact]
    public async Task A_fallback_keeps_the_stored_definition()
    {
        var store = new MemoryStore();
        string before;
        await using (var scheduler = Make(store))
        {
            scheduler.Cw.Job("report", new JobOptions
            {
                Grace = "5m",
                Schedule = "0 2 * * *",
                Timezone = "UTC",
                Timeout = 7_200_000,
                MaxDuration = "30m",
                Budget = { ["cost"] = 2, ["rows"] = 10 },
                Floor = { ["rows"] = 1 },
                FailuresBeforeAlert = 2,
                Description = "Nightly",
                Tags = ["river", "river:billing"],
                Expect = "Report written",
            });
            await scheduler.Cw.CheckAsync();
            before = await Stored(store, "report");
        }
        await using (var worker = Make(store))
        {
            var w = new Watch(worker.Cw, "river", "billing", "River");
            Job? job = await w.FallbackAsync("report", new JobOptions());
            Assert.NotNull(job);
            Assert.Equal(before, job.Definition.ToJson());
            Assert.Same(job, await w.FallbackAsync("report", new JobOptions()));
            await job.RunAsync((ctx, ct) => Task.CompletedTask);
            Run run = (await worker.Cw.RunsAsync("report", 1))[0];
            Assert.Equal("Output did not contain \"Report written\"", run.Error);
            Assert.Equal(before, await Stored(store, "report"));
        }
        // A job of another app's is not taken for this one's.
        await using var fresh = Make(store);
        var other = new Watch(fresh.Cw, "river", "search", "River");
        Job? made = await other.FallbackAsync("report", new JobOptions { Grace = "1m" });
        Assert.NotNull(made);
        Assert.Equal("{\"grace\":\"1m\",\"tags\":[\"river\",\"river:search\"],\"name\":\"report\"}", made.Definition.ToJson());
    }

    // The cross-port check: a fallback forgotten from the dashboard was kept, so the client never
    // declared it again, and UnscheduleAsync then took the schedule another process stored out.
    [Fact]
    public async Task A_forgotten_fallback_is_declared_again_and_keeps_its_schedule()
    {
        var store = new MemoryStore();
        string before;
        await using (var scheduler = Make(store))
        {
            scheduler.Cw.Job("report", new JobOptions { Schedule = "0 2 * * *", Tags = ["river", "river:billing"] });
            await scheduler.Cw.CheckAsync();
            before = await Stored(store, "report");
        }
        await using var worker = Make(store);
        var w = new Watch(worker.Cw, "river", "billing", "River");
        Job? first = await w.FallbackAsync("report", new JobOptions());
        Assert.NotNull(first);
        await worker.Cw.ForgetAsync("report");
        Assert.Null(w.Job("report"));
        await using (var scheduler = Make(store))
        {
            scheduler.Cw.Job("report", new JobOptions { Schedule = "0 2 * * *", Tags = ["river", "river:billing"] });
            await scheduler.Cw.CheckAsync();
        }
        Job? again = await w.FallbackAsync("report", new JobOptions());
        Assert.NotNull(again);
        Assert.NotSame(first, again);
        Assert.Equal(before, again.Definition.ToJson());
        await again.RunAsync((ctx, ct) => Task.CompletedTask);
        w.Declare([E("invoices", "x", "0 1 * * *")]);
        Assert.True(await w.SettleAsync(Settle));
        Assert.Empty(await w.UnscheduleAsync());
        Assert.Equal(before, await Stored(store, "report"));
    }

    // The Go audit: a process that only schedules neither runs nor checks, and kept its
    // declarations in memory, so the store never held its jobs.
    [Fact]
    public async Task Declaring_writes_the_jobs_to_the_store()
    {
        await using var m = Make();
        var w = new Watch(m.Cw, "asynq", "billing", "Asynq");
        w.Declare([E("invoices", "x", "0 1 * * *")]);
        Assert.True(await w.SettleAsync(Settle));
        Assert.Equal("{\"schedule\":\"0 1 * * *\",\"tags\":[\"asynq\",\"asynq:billing\"],\"name\":\"invoices\"}", await Stored(m.Store, "invoices"));
        Assert.Empty(m.Errors.Entries);
    }

    // The Go audit: a job another process of the app took the schedule out of (an older release
    // still up during a deploy) stayed unscheduled until this process restarted.
    [Fact]
    public async Task A_job_another_process_unscheduled_is_put_back()
    {
        var store = new MemoryStore();
        await using var newer = Make(store);
        await using var older = Make(store);
        var wn = new Watch(newer.Cw, "gocron", "billing", "gocron");
        wn.Declare([E("old", "a", "0 1 * * *"), E("added", "b", "0 2 * * *")]);
        Assert.True(await wn.SettleAsync(Settle));
        await newer.Cw.CheckAsync();

        var wo = new Watch(older.Cw, "gocron", "billing", "gocron");
        wo.Declare([E("old", "a", "0 1 * * *")]);
        await wo.UnscheduleAsync();
        await older.Cw.CheckAsync();
        Assert.DoesNotContain("\"schedule\"", await Stored(store, "added"), StringComparison.Ordinal);

        await wn.UnscheduleAsync();
        Assert.Equal("{\"schedule\":\"0 2 * * *\",\"tags\":[\"gocron\",\"gocron:billing\"],\"name\":\"added\"}", await Stored(store, "added"));
    }

    [Fact]
    public async Task A_fallback_does_not_declare_over_a_store_it_could_not_read()
    {
        var store = new OddStore();
        string before;
        await using (var scheduler = Make(store))
        {
            scheduler.Cw.Job("report", new JobOptions { Schedule = "0 2 * * *", Tags = ["river", "river:billing"] });
            await scheduler.Cw.CheckAsync();
            before = await Stored(store, "report");
        }
        await using var worker = Make(store);
        var w = new Watch(worker.Cw, "river", "billing", "River");
        store.Failing = true;
        Assert.Null(await w.FallbackAsync("report", new JobOptions()));
        Assert.Single(worker.Errors.Entries);
        store.Failing = false;
        Job? job = await w.FallbackAsync("report", new JobOptions());
        Assert.NotNull(job);
        await job.RunAsync((ctx, ct) => Task.CompletedTask);
        Assert.Equal(before, await Stored(store, "report"));
    }

    // The Rust audit: a store that panicked while a declaration was written left the writer
    // marked busy, so nothing was written again and settle waited for good.
    [Fact]
    public async Task A_declaration_whose_store_throws_does_not_stop_the_next()
    {
        var store = new OddStore();
        await using var m = Make(store);
        var w = new Watch(m.Cw, "river", "billing", "River");
        store.ThrowsOnce = true;
        w.Declare([E("first", "x", "0 1 * * *")]);
        Assert.True(await w.SettleAsync(Settle));
        var errors = m.Errors.Entries.ToList();
        Assert.Single(errors);
        Assert.Equal("declaring first", errors[0].Where);
        Assert.Contains("the store fell over", errors[0].Error.Message + errors[0].Error.InnerException?.Message, StringComparison.Ordinal);
        w.Declare([E("first", "x", "0 1 * * *"), E("second", "y", "0 2 * * *")]);
        Assert.True(await w.SettleAsync(Settle));
        Assert.Contains("0 2 * * *", await Stored(store, "second"), StringComparison.Ordinal);
    }

    // The Rust audit: a declaration's write whose store hung held the writer for good.
    [Fact]
    public async Task A_declaration_whose_store_hangs_is_given_up()
    {
        var store = new OddStore();
        var hang = new TaskCompletionSource();
        await using var m = Make(store);
        try
        {
            await store.InitAsync();
            var w = new Watch(m.Cw, "river", "billing", "River") { SaveLimit = TimeSpan.FromMilliseconds(200) };
            store.Hang = hang.Task;
            w.Declare([E("first", "x", "0 1 * * *")]);
            Assert.True(await w.SettleAsync(Settle), "the writer gave up and settled");
            Assert.Equal(
                ["declaring first: writing the declaration of \"first\" took longer than 0 seconds; gave up"],
                m.Errors.Entries.Select(e => e.Where + ": " + e.Error.Message).ToList());
            store.Hang = null;
        }
        finally
        {
            hang.SetResult();
        }
    }

    // The Go audit: an entry declared while unschedule read the store was taken for gone, and its
    // job lost its schedule for the life of the process.
    [Fact]
    public async Task Unschedule_keeps_an_entry_declared_meanwhile()
    {
        var store = new OddStore();
        await using (var earlier = Make(store))
        {
            earlier.Cw.Job("added", new JobOptions { Schedule = "0 2 * * *", Tags = ["gocron", "gocron:billing"] });
            await earlier.Cw.CheckAsync();
        }
        await using var m = Make(store);
        var w = new Watch(m.Cw, "gocron", "billing", "gocron");
        Entry[] entries = [E("first", "x", "0 1 * * *")];
        w.Declare(entries);
        Assert.True(await w.SettleAsync(Settle));
        store.Meanwhile = () => w.Declare([.. entries, E("added", "y", "0 2 * * *")]);
        Assert.Empty(await w.UnscheduleAsync());
        Assert.Equal("0 2 * * *", m.Cw.DefinedJobs[1].Schedule);
        Assert.True(await w.SettleAsync(Settle));
        Assert.Contains("\"schedule\":\"0 2 * * *\"", await Stored(store, "added"), StringComparison.Ordinal);
    }

    [Fact]
    public async Task Unschedule_reports_a_store_it_could_not_read()
    {
        var store = new OddStore();
        await using var m = Make(store);
        var w = new Watch(m.Cw, "gocron", "billing", "gocron");
        w.Declare([E("first", "x", "0 1 * * *")]);
        Assert.True(await w.SettleAsync(Settle));
        store.Meanwhile = () => throw new InvalidOperationException("the store is down");
        var e = await Assert.ThrowsAsync<CronwatchException>(w.UnscheduleAsync);
        Assert.Contains("the store is down", e.Message + e.InnerException?.Message, StringComparison.Ordinal);
    }

    [Fact]
    public async Task Options_of_rebuilds_an_expect_pattern_and_a_custom_function()
    {
        await using var m = Make();
        Definition def = SchedulerBridge.Definition(m.Cw, "x", new JobOptions { Expect = Expect.Matches("done \\d+", "i") });
        Assert.Equal(def.ToJson(), SchedulerBridge.Definition(m.Cw, "x", SchedulerBridge.OptionsOf(def)).ToJson());
        Job job = m.Cw.Job("x", SchedulerBridge.OptionsOf(def));
        await job.RunAsync((ctx, ct) =>
        {
            ctx.Log("Done 12");
            return Task.CompletedTask;
        });
        m.Clock.Advance(1000);
        await job.RunAsync((ctx, ct) =>
        {
            ctx.Log("nothing");
            return Task.CompletedTask;
        });
        var runs = await m.Cw.RunsAsync("x", 2);
        Assert.Equal("Output did not match /done \\d+/i", runs[0].Error);
        Assert.Null(runs[1].Error);

        Definition custom = SchedulerBridge.Definition(m.Cw, "y", new JobOptions { Expect = Expect.That(_ => false) });
        Assert.Equal("{\"name\":\"y\",\"expect\":\"custom function\"}", SchedulerBridge.Definition(m.Cw, "y", SchedulerBridge.OptionsOf(custom)).ToJson());

        // A pattern the engine does not read is kept as stored, and passes every output.
        Definition unread = Definition.FromJson("{\"name\":\"z\",\"expect\":\"matches /(?<=a)+b/\"}");
        Assert.Equal(unread.ToJson(), SchedulerBridge.Definition(m.Cw, "z", SchedulerBridge.OptionsOf(unread)).ToJson());

        Definition contains = Definition.FromJson("{\"name\":\"c\",\"expect\":\"contains \\\"a \\\\\\\"quoted\\\\\\\" word\\\"\"}");
        Assert.Equal(contains.ToJson(), SchedulerBridge.Definition(m.Cw, "c", SchedulerBridge.OptionsOf(contains)).ToJson());
    }

    [Fact]
    public async Task Sync_within_gives_up_on_a_hung_sync()
    {
        await using var m = Make();
        var hang = new TaskCompletionSource();
        try
        {
            Assert.False(await SchedulerBridge.SyncWithinAsync(m.Cw, TimeSpan.FromMilliseconds(100), "quartz", () => hang.Task));
            Assert.Equal(["quartz: the sync took longer than 0 seconds; gave up"], m.Errors.Entries.Select(e => e.Where + ": " + e.Error.Message).ToList());
            Assert.True(await SchedulerBridge.SyncWithinAsync(m.Cw, Settle, "quartz", () => Task.CompletedTask));
            Assert.False(await SchedulerBridge.SyncWithinAsync(m.Cw, Settle, "quartz", () => throw new InvalidOperationException("no")));
            Assert.Equal("quartz: no", m.Errors.Entries.Select(e => e.Where + ": " + e.Error.Message).ToList()[1]);
        }
        finally
        {
            hang.SetResult();
        }
    }

    /// <summary>
    /// A memory store that fails its reads of jobs while <see cref="Failing"/>, throws once from
    /// a declaration's write, holds writes at <see cref="Hang"/>, and runs
    /// <see cref="Meanwhile"/> as it lists the jobs.
    /// </summary>
    private sealed class OddStore : IStore, IUpdateRunIfStore, ICompareAndSetStateStore, IDeleteRunIfStore
    {
        private readonly MemoryStore _inner = new();

        public volatile bool Failing;
        public volatile bool ThrowsOnce;

        public Task? Hang { get; set; }

        public Action? Meanwhile { get; set; }

        public Task InitAsync(CancellationToken cancellationToken = default) => _inner.InitAsync(cancellationToken);

        public async Task UpsertJobAsync(Definition definition, long now, CancellationToken cancellationToken = default)
        {
            if (ThrowsOnce)
            {
                ThrowsOnce = false;
                throw new InvalidOperationException("the store fell over");
            }
            if (Hang is { } hang)
            {
                await hang;
            }
            await _inner.UpsertJobAsync(definition, now, cancellationToken);
        }

        public Task<StoredJob?> GetJobAsync(string name, CancellationToken cancellationToken = default) =>
            Failing ? throw new InvalidOperationException("the store is down") : _inner.GetJobAsync(name, cancellationToken);

        public Task<IReadOnlyList<StoredJob>> ListJobsAsync(CancellationToken cancellationToken = default)
        {
            if (Failing)
            {
                throw new InvalidOperationException("the store is down");
            }
            var meanwhile = Meanwhile;
            Meanwhile = null;
            meanwhile?.Invoke();
            return _inner.ListJobsAsync(cancellationToken);
        }

        public Task DeleteJobAsync(string name, CancellationToken cancellationToken = default) => _inner.DeleteJobAsync(name, cancellationToken);

        public Task InsertRunAsync(Run run, CancellationToken cancellationToken = default) => _inner.InsertRunAsync(run, cancellationToken);

        public Task UpdateRunAsync(Run run, CancellationToken cancellationToken = default) => _inner.UpdateRunAsync(run, cancellationToken);

        public Task<Run?> GetRunAsync(string id, CancellationToken cancellationToken = default) => _inner.GetRunAsync(id, cancellationToken);

        public Task<IReadOnlyList<Run>> ListRunsAsync(string job, int limit, CancellationToken cancellationToken = default) => _inner.ListRunsAsync(job, limit, cancellationToken);

        public Task<Run?> LastRunAsync(string job, CancellationToken cancellationToken = default) => _inner.LastRunAsync(job, cancellationToken);

        public Task<IReadOnlyList<Run>> RunningRunsAsync(CancellationToken cancellationToken = default) => _inner.RunningRunsAsync(cancellationToken);

        public Task<JobState?> GetStateAsync(string job, CancellationToken cancellationToken = default) => _inner.GetStateAsync(job, cancellationToken);

        public Task SetStateAsync(JobState state, CancellationToken cancellationToken = default) => _inner.SetStateAsync(state, cancellationToken);

        public Task<long> PruneAsync(long before, CancellationToken cancellationToken = default) => _inner.PruneAsync(before, cancellationToken);

        public Task<bool> UpdateRunIfAsync(Run run, IReadOnlyList<RunStatus> from, CancellationToken cancellationToken = default) => _inner.UpdateRunIfAsync(run, from, cancellationToken);

        public Task<bool> CompareAndSetStateAsync(JobState state, long expected, CancellationToken cancellationToken = default) => _inner.CompareAndSetStateAsync(state, expected, cancellationToken);

        public Task<bool> DeleteRunIfAsync(string id, string job, RunStatus status, CancellationToken cancellationToken = default) => _inner.DeleteRunIfAsync(id, job, status, cancellationToken);
    }
}
