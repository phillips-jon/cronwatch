using System;
using System.IO;
using System.Runtime.CompilerServices;
using System.Threading.Tasks;
using Cronwatch.Internal;
using Xunit;

namespace Cronwatch.Tests;

/// <summary>An exception written as the SDK writes an error: <c>Name: message</c> and five frames.</summary>
public class ErrorTextTests
{
    private sealed class ReportException(string message) : IOException(message);

    private sealed class MyError<T>(string message) : Exception(message)
    {
        public T? Value { get; init; }
    }

    private sealed class NullMessage : Exception
    {
        public override string Message => null!;
    }

    private sealed class UnreadableMessage : Exception
    {
        public override string Message => throw new InvalidOperationException("no");
    }

    private static Exception Caught(Action a)
    {
        try
        {
            a();
        }
        catch (Exception e)
        {
            return e;
        }
        throw new InvalidOperationException("nothing thrown");
    }

    private static async Task<Exception> CaughtAsync(Func<Task> f)
    {
        try
        {
            await f();
        }
        catch (Exception e)
        {
            return e;
        }
        throw new InvalidOperationException("nothing thrown");
    }

    [MethodImpl(MethodImplOptions.NoInlining)]
    private static void Throw() => throw new ReportException("disk full");

    [MethodImpl(MethodImplOptions.NoInlining)]
    private static void Deep(int n)
    {
        if (n == 0)
        {
            Throw();
        }
        Deep(n - 1);
    }

    [MethodImpl(MethodImplOptions.NoInlining)]
    private static async Task BuildAsync()
    {
        await Task.Yield();
        throw new ReportException("async");
    }

    private static string[] Lines(string text) => text.Split('\n');

    [Fact]
    public void A_throw_is_its_simple_name_message_and_frames()
    {
        string text = OutputText.ErrorMessage(Caught(Throw));
        string[] lines = Lines(text);
        Assert.Equal("ReportException: disk full", lines[0]);
        Assert.Matches(@"^    at Cronwatch\.Tests\.ErrorTextTests\.Throw \(ErrorTextTests\.cs:\d+\)$", lines[1]);
    }

    [Fact]
    public void Five_frames_innermost_first()
    {
        string[] lines = Lines(OutputText.ErrorMessage(Caught(() => Deep(8))));
        Assert.Equal(6, lines.Length);
        Assert.Contains("ErrorTextTests.Throw (", lines[1], StringComparison.Ordinal);
        for (int k = 2; k < 6; k++)
        {
            Assert.Contains("ErrorTextTests.Deep (ErrorTextTests.cs:", lines[k], StringComparison.Ordinal);
        }
    }

    [Fact]
    public async Task An_async_method_is_written_as_the_method_a_person_wrote()
    {
        var e = await CaughtAsync(BuildAsync);
        string[] lines = Lines(OutputText.ErrorMessage(e));
        Assert.Equal("ReportException: async", lines[0]);
        Assert.Matches(@"^    at Cronwatch\.Tests\.ErrorTextTests\.BuildAsync \(ErrorTextTests\.cs:\d+\)$", lines[1]);
        foreach (string line in lines)
        {
            Assert.DoesNotContain("MoveNext", line, StringComparison.Ordinal);
            Assert.DoesNotContain("ExceptionDispatchInfo", line, StringComparison.Ordinal);
            Assert.DoesNotContain("TaskAwaiter", line, StringComparison.Ordinal);
            Assert.DoesNotContain("System.Runtime.CompilerServices", line, StringComparison.Ordinal);
        }
    }

    [Fact]
    public void A_generic_type_is_named_without_its_arity()
    {
        Assert.StartsWith("MyError: boom", OutputText.ErrorMessage(new MyError<int>("boom")), StringComparison.Ordinal);
    }

    [Fact]
    public void An_aggregate_of_one_is_that_one()
    {
        var one = new AggregateException(new ReportException("inner"));
        Assert.Equal("ReportException: inner", OutputText.ErrorMessage(one));
        var two = new AggregateException("both", new ReportException("a"), new ReportException("b"));
        Assert.StartsWith("AggregateException: both", OutputText.ErrorMessage(two), StringComparison.Ordinal);
        // A Task's wait wraps the exception once; the text is the exception the job threw.
        var waited = Caught(() => Task.Run(Throw).Wait());
        Assert.StartsWith("ReportException: disk full\n    at Cronwatch.Tests.ErrorTextTests.Throw (", OutputText.ErrorMessage(waited), StringComparison.Ordinal);
    }

    [Fact]
    public void A_missing_or_unreadable_message_is_empty()
    {
        Assert.Equal("NullMessage: ", OutputText.ErrorMessage(new NullMessage()));
        Assert.Equal("UnreadableMessage: ", OutputText.ErrorMessage(new UnreadableMessage()));
    }

    [Fact]
    public void Inner_exceptions_are_not_written()
    {
        var e = new InvalidOperationException("outer", new IOException("inner"));
        Assert.Equal("InvalidOperationException: outer", OutputText.ErrorMessage(e));
    }

    [Fact]
    public void Methods_are_written_as_a_person_wrote_them()
    {
        Assert.Equal("Example.Reports.BuildAsync", OutputText.Method("Example.Reports+<BuildAsync>d__4", "MoveNext"));
        Assert.Equal("Example.Box.RunAsync", OutputText.Method("Example.Box`1+<RunAsync>d__2", "MoveNext"));
        Assert.Equal("Example.Reports.Items", OutputText.Method("Example.Reports+<Items>d__7", "MoveNext"));
        Assert.Equal("Example.Reports.Outer.Build", OutputText.Method("Example.Reports+Outer", "Build"));
        Assert.Equal("Example.Reports.<>c.<Run>b__0_0", OutputText.Method("Example.Reports+<>c", "<Run>b__0_0"));
        Assert.Equal("Example.List.Add", OutputText.Method("Example.List`1[[System.Int32, System.Private.CoreLib]]", "Add"));
        Assert.Equal("Main", OutputText.Method(null, "Main"));
        Assert.Null(OutputText.Method("System.Runtime.CompilerServices.AsyncTaskMethodBuilder`1", "Start"));
        Assert.Null(OutputText.Method("System.Runtime.ExceptionServices.ExceptionDispatchInfo", "Throw"));
        Assert.Null(OutputText.Method("System.Threading.Tasks.Task", "Wait"));
    }

    [Fact]
    public void A_value_that_is_not_an_exception_is_itself_or_its_json()
    {
        Assert.Equal("plain", OutputText.ErrorMessage((object)"plain"));
        Assert.Equal("{\"code\":5}", OutputText.ErrorMessage(new JsObject().Set("code", 5)));
        Assert.Equal("[1,\"two\",null]", OutputText.ErrorMessage(new System.Collections.Generic.List<object?> { 1, "two", null }));
        Assert.Equal("null", OutputText.ErrorMessage((object?)null));
        // Something JSON cannot write is written as its ToString, as String(error) would be.
        Assert.Equal("a thing", OutputText.ErrorMessage(new Thing()));
    }

    private sealed class Thing
    {
        public override string ToString() => "a thing";
    }

    [Fact]
    public void The_cap_keeps_the_tail_and_nuls_go_first()
    {
        Assert.Equal("ab", OutputText.Cap("a\0b\0"));
        string longText = new string('x', OutputText.OutputCap) + "tail";
        string capped = OutputText.Cap(longText);
        Assert.Equal("[earlier output trimmed]\n", capped[..25]);
        Assert.EndsWith("tail", capped, StringComparison.Ordinal);
        Assert.Equal(25 + OutputText.OutputCap, capped.Length);
        // A cut through a pair keeps the lone half, as JavaScript's slice does.
        string pair = string.Concat(System.Linq.Enumerable.Repeat("\ud83d\ude00", OutputText.OutputCap)) + "a";
        Assert.Equal('\ude00', OutputText.Cap(pair)[25]);
    }
}
