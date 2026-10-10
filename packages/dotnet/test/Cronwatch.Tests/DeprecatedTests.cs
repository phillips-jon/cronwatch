using System;
using System.Collections.Generic;
using System.Text;
using System.Threading.Tasks;
using Cronwatch.Alerts;
using Cronwatch.Web;
using Xunit;

#pragma warning disable CS0618 // the deprecated names are what this file tests

namespace Cronwatch.Tests;

/// <summary>
/// The deprecated names (the 1.0 plan, D11): each still compiles where it did and does what its
/// replacement does. A rename stays through 1.x; a helper public by accident goes in 1.0.
/// </summary>
public class DeprecatedTests
{
    [Fact]
    public async Task WebRequest_and_WebResponse_still_drive_the_routes_and_a_handler()
    {
        await using var cw = new CronwatchClient(new CronwatchOptions
        {
            CronSecret = "hourly-word",
            ProcessExitHook = false,
            Clock = Support.Clock(),
            OnWarning = _ => { },
        });
        Routes routes = cw.Routes(new RoutesOptions { Token = "t0ken" });
        WebResponse answer = await routes.HandleAsync(new WebRequest("GET", "/cronwatch/api/jobs")
        {
            Headers = [new("host", "app.test"), new("authorization", "Bearer t0ken")],
        });
        Assert.Equal(200, answer.Status);
        Assert.Equal("{\"ok\":true,\"jobs\":[]}", answer.Text());
        Assert.Equal("application/json; charset=utf-8", answer.Header("content-type"));
        CronwatchResponse same = answer;
        Assert.Equal(answer.Status, same.Status);

        // A body given to the former type reaches the routes.
        cw.Job("s");
        WebResponse silenced = await routes.HandleAsync(new WebRequest("POST", "/cronwatch/api/jobs/s/silence")
        {
            Headers = [new("host", "app.test"), new("authorization", "Bearer t0ken"), new("content-type", "application/json")],
            Body = Encoding.UTF8.GetBytes("{\"for\":\"2h\"}"),
        });
        Assert.Equal(200, silenced.Status);
        Assert.Equal(JobHealth.Silenced, (await cw.JobSummaryAsync("s"))!.Health);

        // A handler's function may still return the former type, which is its answer.
        Handler h = cw.Job("hourly").Handler((job, req, ct) => Task.FromResult(new WebResponse(418).WithBody("teapot")));
        CronwatchResponse teapot = await h.HandleAsync(new WebRequest("POST", "/") { Headers = [new("authorization", "Bearer hourly-word")] });
        Assert.Equal(418, teapot.Status);
        Assert.Equal("teapot", teapot.Text());
        Assert.Equal("failed", (await cw.RunsAsync("hourly", 1))[0].Status.Value);
    }

    [Fact]
    public void The_former_store_interfaces_extend_their_replacements()
    {
        Assert.True(typeof(IUpdateRunIfStore).IsAssignableFrom(typeof(IConditionalRunStore)));
        Assert.True(typeof(ICompareAndSetStateStore).IsAssignableFrom(typeof(IStateCasStore)));
        Assert.True(typeof(IDeleteRunIfStore).IsAssignableFrom(typeof(IRunDeletingStore)));
        // The stores the library ships answer to both names.
        IStore memory = new MemoryStore();
        Assert.True(memory is IConditionalRunStore and IStateCasStore and IRunDeletingStore);
        Assert.True(typeof(IStateCasStore).IsAssignableFrom(typeof(SqlStore)));
    }

    /// <summary>
    /// A store written before 0.11 that implemented the former interfaces explicitly, as C# often
    /// does an optional interface: it still compiles, and each method is what the client calls.
    /// </summary>
    private sealed class ExplicitlyFormer(IStore inner) : IStore, IConditionalRunStore, IStateCasStore, IRunDeletingStore
    {
        public readonly Support.Wrapped Inner = new(inner);
        public int Updates;
        public int Sets;
        public int Deletes;

        Task<bool> IConditionalRunStore.UpdateRunIfAsync(Run run, IReadOnlyList<RunStatus> from, System.Threading.CancellationToken cancellationToken)
        {
            System.Threading.Interlocked.Increment(ref Updates);
            return Inner.UpdateRunIfAsync(run, from, cancellationToken);
        }

        Task<bool> IStateCasStore.CompareAndSetStateAsync(JobState state, long expected, System.Threading.CancellationToken cancellationToken)
        {
            System.Threading.Interlocked.Increment(ref Sets);
            return Inner.CompareAndSetStateAsync(state, expected, cancellationToken);
        }

        Task<bool> IRunDeletingStore.DeleteRunIfAsync(string id, string job, RunStatus status, System.Threading.CancellationToken cancellationToken)
        {
            System.Threading.Interlocked.Increment(ref Deletes);
            return Inner.DeleteRunIfAsync(id, job, status, cancellationToken);
        }

        public Task InitAsync(System.Threading.CancellationToken cancellationToken = default) => Inner.InitAsync(cancellationToken);
        public Task UpsertJobAsync(Definition definition, long now, System.Threading.CancellationToken cancellationToken = default) => Inner.UpsertJobAsync(definition, now, cancellationToken);
        public Task<IReadOnlyList<StoredJob>> ListJobsAsync(System.Threading.CancellationToken cancellationToken = default) => Inner.ListJobsAsync(cancellationToken);
        public Task<StoredJob?> GetJobAsync(string name, System.Threading.CancellationToken cancellationToken = default) => Inner.GetJobAsync(name, cancellationToken);
        public Task DeleteJobAsync(string name, System.Threading.CancellationToken cancellationToken = default) => Inner.DeleteJobAsync(name, cancellationToken);
        public Task InsertRunAsync(Run run, System.Threading.CancellationToken cancellationToken = default) => Inner.InsertRunAsync(run, cancellationToken);
        public Task UpdateRunAsync(Run run, System.Threading.CancellationToken cancellationToken = default) => Inner.UpdateRunAsync(run, cancellationToken);
        public Task<Run?> GetRunAsync(string id, System.Threading.CancellationToken cancellationToken = default) => Inner.GetRunAsync(id, cancellationToken);
        public Task<IReadOnlyList<Run>> ListRunsAsync(string job, int limit, System.Threading.CancellationToken cancellationToken = default) => Inner.ListRunsAsync(job, limit, cancellationToken);
        public Task<Run?> LastRunAsync(string job, System.Threading.CancellationToken cancellationToken = default) => Inner.LastRunAsync(job, cancellationToken);
        public Task<IReadOnlyList<Run>> RunningRunsAsync(System.Threading.CancellationToken cancellationToken = default) => Inner.RunningRunsAsync(cancellationToken);
        public Task<JobState?> GetStateAsync(string job, System.Threading.CancellationToken cancellationToken = default) => Inner.GetStateAsync(job, cancellationToken);
        public Task SetStateAsync(JobState state, System.Threading.CancellationToken cancellationToken = default) => Inner.SetStateAsync(state, cancellationToken);
        public Task<long> PruneAsync(long before, System.Threading.CancellationToken cancellationToken = default) => Inner.PruneAsync(before, cancellationToken);
    }

    [Fact]
    public async Task A_store_that_implemented_the_former_interfaces_explicitly_compiles_and_is_used()
    {
        var store = new ExplicitlyFormer(new MemoryStore());
        await using var m = Support.Make(store: store);
        Job job = m.Cw.Job("j");
        await job.RunAsync((_, _) => Task.CompletedTask);
        await m.Cw.SilenceAsync("j", "1h");
        Assert.True(store.Updates > 0);
        Assert.True(store.Sets > 0);
        // Taken through the new names, the calls reach the explicit implementations.
        Assert.False(await ((IDeleteRunIfStore)store).DeleteRunIfAsync("none", "j", RunStatus.Running));
        Assert.Equal(1, store.Deletes);
    }

    [Fact]
    public void A_WebRequest_made_from_a_CronwatchRequest_reads_as_it()
    {
        var request = new CronwatchRequest("POST", "/cronwatch/api/check")
        {
            Headers = [new("host", "app.test")],
            IsTls = true,
            Mount = "/cronwatch",
            DeclaredLength = 5,
        };
        WebRequest former = request;
        Assert.True(former.IsTls);
        Assert.Equal("/cronwatch", former.Mount);
        Assert.Equal(5L, former.DeclaredLength);
        Assert.Equal("app.test", former.Header("host"));
        Assert.Same(request, (CronwatchRequest)former);
        WebRequest made = WebRequest.FromCronwatchRequest(request);
        Assert.True(made.IsTls);
        Assert.Equal("/cronwatch", made.Mount);
    }

    [Fact]
    public async Task A_store_written_against_a_former_interface_is_still_used()
    {
        var store = new FormerCas();
        await using var m = Support.Make(store: store);
        m.Cw.Job("j");
        await m.Cw.SilenceAsync("j", "1h");
        Assert.True(store.Calls > 0);
    }

    /// <summary>A store of an app's own, written before 0.11 against <see cref="IStateCasStore"/>.</summary>
    private sealed class FormerCas : Support.Wrapped, IStateCasStore
    {
        public int Calls;

        Task<bool> ICompareAndSetStateStore.CompareAndSetStateAsync(JobState state, long expected, System.Threading.CancellationToken cancellationToken)
        {
            System.Threading.Interlocked.Increment(ref Calls);
            return CompareAndSetStateAsync(state, expected, cancellationToken);
        }
    }

    [Fact]
    public void Slack_and_Discord_Webhook_are_the_channel_types_shortcuts()
    {
        Assert.Equal(SlackChannel.Webhook("https://hooks.slack.example/T/B/x").Name, Cronwatch.Alerts.Slack.Webhook("https://hooks.slack.example/T/B/x").Name);
        Assert.IsType<DiscordChannel>(Cronwatch.Alerts.Discord.Webhook("https://discord.example/api/webhooks/1/x"));
        Assert.Throws<CronwatchException>(() => Cronwatch.Alerts.Slack.Webhook(""));
    }

    [Fact]
    public void The_json_helpers_made_internal_still_answer()
    {
        Assert.Equal("\"a\\\"b\"", Json.Quote("a\"b"));
        Assert.Equal(Json.Stringify("a\"b"), Json.Quote("a\"b"));
        Assert.Equal("number", Json.Kind(1.5));
        Assert.True(Json.TryNumber(2L, out double n) && n == 2);
        var o = new JsObject().Set("a", new List<object?> { 1.0 });
        Assert.Equal(o.ToJson(), Json.Stringify(Json.Copy(o)));
        Assert.Equal(256, Json.MaxDepth);
    }

    [Fact]
    public void The_store_kits_fixture_helpers_still_answer()
    {
        Assert.Equal(StoreTesting.StoreContract.MakeRun("r", "j", RunStatus.Ok, 5), StoreTesting.StoreContract.NewRun("r", "j", RunStatus.Ok, 5));
        Assert.Equal(StoreTesting.ForeignRowChecks.FarStarts, StoreTesting.ForeignRows.FarStarts);
    }

    [Fact]
    public void The_store_kit_promises_only_the_contract()
    {
        foreach (var type in new[] { typeof(StoreTesting.StoreReplay), typeof(StoreTesting.FinishOnce), typeof(StoreTesting.ForeignRows) })
        {
            Assert.NotNull(Attribute.GetCustomAttribute(type, typeof(ObsoleteAttribute)));
        }
        Assert.NotNull(Attribute.GetCustomAttribute(typeof(StoreTesting.StoreContract).GetMethod("NewRun")!, typeof(ObsoleteAttribute)));
        Assert.Null(Attribute.GetCustomAttribute(typeof(StoreTesting.StoreContract), typeof(ObsoleteAttribute)));
        Assert.Null(Attribute.GetCustomAttribute(typeof(StoreTesting.StoreContract).GetMethod("RunAsync")!, typeof(ObsoleteAttribute)));
    }

    [Fact]
    public void WebAdapters_is_Adapters()
    {
        Assert.Equal(Adapters.Target("/cafÃ©"), WebAdapters.Target("/cafÃ©"));
        var fields = new List<KeyValuePair<string, string>> { new("for", "2h"), new("a b", "c&d") };
        Assert.Equal(Adapters.FormBody(fields), WebAdapters.FormBody(fields));
    }
}
