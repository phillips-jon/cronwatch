using System.Text.Json;
using System.Threading.Channels;
using Cronwatch;
using Xunit;

// Outside the Cronwatch namespace, as an app's own code is: a name the library shares with a
// namespace an app commonly imports beside it would make this file fail to compile.
namespace AppWithCommonImports;

/// <summary>An app importing Cronwatch beside System.Text.Json and System.Threading.Channels.</summary>
public class NameClashTests
{
    [Fact]
    public void Cronwatch_takes_no_name_from_the_namespaces_an_app_imports_beside_it()
    {
        // System.Text.Json's exception and System.Threading.Channels' factory, by their simple names.
        var queue = Channel.CreateUnbounded<int>();
        Assert.True(queue.Writer.TryWrite(1));
        Assert.ThrowsAny<JsonException>(() => JsonDocument.Parse("{"));
        Assert.NotNull(CustomChannel.Create("pager", (_, _, _) => System.Threading.Tasks.Task.CompletedTask));
    }
}
