using Xunit;

namespace Cronwatch.Tests;

/// <summary>
/// The cross-port check: the SDK keeps queued alerts as plain JSON, so a field a newer release
/// added to an alert, its run, its details or a sending entry is written back as it was read, and
/// an alert of a type this release does not know keeps its details.
/// </summary>
public class QueuedAlertTests
{
    private const string Run =
        "{\"id\":\"r1\",\"job\":\"j\",\"status\":\"failed\",\"startedAt\":1,\"finishedAt\":2,\"durationMs\":1,\"error\":\"boom\",\"output\":null,\"metrics\":{},\"trigger\":\"schedule\",\"attempt\":2}";

    private const string Failed =
        "{\"type\":\"failed\",\"run\":" + Run + ",\"details\":{\"consecutiveFailures\":3,\"threshold\":1,\"streak\":\"x\"},\"job\":\"j\",\"definition\":{\"name\":\"j\"},\"title\":\"t\",\"message\":\"m\",\"at\":5,\"futureAlertField\":{\"a_b\":1}}";

    private const string Future =
        "{\"type\":\"future\",\"run\":null,\"details\":{\"zeta\":1,\"a_b\":[1]},\"job\":\"j\",\"definition\":{\"name\":\"j\"},\"title\":\"t\",\"message\":\"m\",\"at\":6,\"triage\":null}";

    private const string OverBudget =
        "{\"type\":\"over_budget\",\"run\":null,\"details\":{\"breaches\":[{\"metric\":\"rows\",\"value\":5,\"limit\":1,\"basis\":\"budget\",\"unit\":\"n\"}],\"total\":1},\"job\":\"j\",\"definition\":{\"name\":\"j\"},\"title\":\"t\",\"message\":\"m\",\"at\":7}";

    [Fact]
    public void An_alert_keeps_every_field_it_does_not_know()
    {
        foreach (string json in new[] { Failed, Future, OverBudget })
        {
            Assert.Equal(json, Alert.FromJson(json).ToJson());
        }
        Assert.Equal(Alert.FromJson(Failed), Alert.FromJson(Failed));
        Assert.Equal(
            "{\"zeta\":1,\"a_b\":[1]}",
            Alert.FromJson(Future).Details.ToValue().ToJson());
        Assert.Equal(
            "{\"type\":\"future\",\"run\":null,\"details\":{\"zeta\":1,\"a_b\":[1]},\"job\":\"j\",\"definition\":{\"name\":\"j\"},\"title\":\"t\",\"message\":\"m\",\"at\":6,\"triage\":\"why\"}",
            Alert.FromJson(Future).WithTriage("why").ToJson());
    }

    [Fact]
    public void Queued_and_sending_alerts_write_back_as_read()
    {
        string json =
            "{\"job\":\"j\",\"open\":{\"failed\":5},\"consecutiveFailures\":3,\"silencedUntil\":null,\"lastAlertAt\":null,\"pendingRecovery\":[],\"undelivered\":["
            + Failed + "," + Future
            + "],\"sending\":[{\"until\":9,\"alert\":" + OverBudget + ",\"futureEntryKey\":true}]}";
        Assert.Equal(json, JobState.FromJson(json).ToJson());
    }
}
