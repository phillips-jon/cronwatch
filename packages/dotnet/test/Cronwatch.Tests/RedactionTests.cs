using System;
using System.Linq;
using System.Threading.Tasks;
using Cronwatch.Internal;
using Xunit;
using static Cronwatch.Tests.Support;

namespace Cronwatch.Tests;

/// <summary>
/// The SDK's <c>redaction.test.ts</c> cases for the cut: output and errors are redacted before
/// they are capped, so the 16 KB cut never keeps the rest of a secret whose label it cut off.
/// </summary>
public class RedactionTests
{
    private const string Trimmed = "[earlier output trimmed]\n";

    [Fact]
    public async Task A_secret_split_by_the_16_KB_cut_is_redacted_whole()
    {
        string pem = "-----BEGIN PRIVATE KEY-----\n"
            + string.Join("\n", Enumerable.Range(0, 25).Select(i => string.Concat(Enumerable.Repeat("QUJD", 15)) + i.ToString("D4", System.Globalization.CultureInfo.InvariantCulture)))
            + "\n-----END PRIVATE KEY-----";
        const string bearer = "Authorization: Bearer opaqueTOKENvalue1234567890";
        await using var m = Make();

        // The cut lands inside the key's body, and in a second run just after "Bear".
        await m.Cw.RunAsync("pem", (j, ct) =>
        {
            j.Log(new string('x', OutputText.OutputCap));
            j.Log(pem[..900]);
            j.Log(pem[900..]);
            j.Log("done");
            return Task.CompletedTask;
        });
        string pemOutput = (await m.Cw.RunsAsync("pem", 1))[0].Output!;
        Assert.DoesNotContain("QUJD", pemOutput, StringComparison.Ordinal);
        Assert.EndsWith("[redacted]\ndone", pemOutput, StringComparison.Ordinal);

        string tail = new('y', OutputText.OutputCap - 30);
        await m.Cw.Job("bearer").RunAsync((j, ct) => Task.FromResult(bearer + "\n" + tail));
        string bearerOutput = (await m.Cw.RunsAsync("bearer", 1))[0].Output!;
        Assert.DoesNotContain("opaqueTOKEN", bearerOutput, StringComparison.Ordinal);
        Assert.True(bearerOutput.Length <= OutputText.OutputCap + Trimmed.Length);

        // Errors, recorded runs and flushed lines the same way.
        await Quietly(() => m.Cw.RunAsync("thrown", (j, ct) =>
            throw new InvalidOperationException(new string('e', OutputText.OutputCap) + " " + bearer + " " + new string('z', OutputText.OutputCap - 40))));
        Assert.DoesNotContain("opaqueTOKEN", (await m.Cw.RunsAsync("thrown", 1))[0].Error!, StringComparison.Ordinal);

        m.Cw.Job("imported");
        await m.Cw.RecordRunAsync(new Run
        {
            Id = "i1",
            Job = "imported",
            Status = RunStatus.Ok,
            StartedAt = 1,
            FinishedAt = 2,
            DurationMs = 1,
            Output = bearer + "\n" + tail,
            Trigger = "source",
        });
        Assert.DoesNotContain("opaqueTOKEN", (await m.Cw.GetRunAsync("i1"))!.Output!, StringComparison.Ordinal);

        RunHandle handle = await m.Cw.Job("flushed").StartAsync();
        handle.Log(bearer);
        handle.Log(tail);
        await handle.FlushAsync();
        Assert.DoesNotContain("opaqueTOKEN", (await m.Cw.GetRunAsync(handle.Id))!.Output!, StringComparison.Ordinal);
        await handle.FinishAsync();
        Assert.DoesNotContain("opaqueTOKEN", (await m.Cw.GetRunAsync(handle.Id))!.Output!, StringComparison.Ordinal);

        // A run's error text given as a string is redacted before it is cut, too.
        RunHandle failing = await m.Cw.Job("failing").StartAsync();
        await failing.FailAsync(bearer + "\n" + tail);
        Assert.DoesNotContain("opaqueTOKEN", (await m.Cw.GetRunAsync(failing.Id))!.Error!, StringComparison.Ordinal);
    }

    [Fact]
    public void Text_past_the_redaction_window_never_keeps_what_came_right_after_its_cut()
    {
        // The window starts part way into a key's body, whose header is before it: the body's
        // rest cannot be told from text, so it is never kept.
        string body = string.Concat(Enumerable.Repeat("QUJD", 4000));
        string text = "-----BEGIN PRIVATE KEY-----\n" + body + "\n" + new string('k', OutputText.OutputCap + OutputText.RedactEdge - 8000);
        string kept = OutputText.RedactAndCap(text, OutputText.RedactSecrets);
        Assert.StartsWith(Trimmed, kept, StringComparison.Ordinal);
        Assert.Equal(Trimmed.Length + OutputText.OutputCap, kept.Length);
        Assert.DoesNotContain("QUJD", kept, StringComparison.Ordinal);

        // A redaction that shrinks the window cannot pull its first units into view.
        string Shrinking(string t) => t.Replace(new string('s', 100), "", StringComparison.Ordinal);
        string shrunk = OutputText.RedactAndCap(string.Concat(Enumerable.Repeat("QUJD", 100)) + new string('s', OutputText.OutputCap + OutputText.RedactEdge), Shrinking);
        Assert.Equal(Trimmed, shrunk);

        // Short text is redacted whole, then capped as before; NULs go either side of redact.
        Assert.Equal("password=[redacted]", OutputText.RedactAndCap("password=x", OutputText.RedactSecrets));
        Assert.Equal("ab", OutputText.RedactAndCap("a\0b", t => t + "\0"));
        Assert.Equal(Trimmed + new string('x', OutputText.OutputCap), OutputText.RedactAndCap(new string('x', OutputText.OutputCap + 5), OutputText.RedactSecrets));
    }
}
