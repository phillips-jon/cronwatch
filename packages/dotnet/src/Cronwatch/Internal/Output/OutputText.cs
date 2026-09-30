using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Text;

namespace Cronwatch.Internal;

/// <summary>
/// The SDK's <c>output.ts</c>: the output cap, error text and secret redaction. Lengths and cuts
/// are in UTF-16 code units, as JavaScript counts them (a .NET string is one), so the same output
/// is capped at the same character here and in every other port.
/// </summary>
internal static class OutputText
{
    /// <summary>How much output a run keeps: 16 KB of UTF-16 code units, the tail.</summary>
    public const int OutputCap = 16 * 1024;

    /// <summary>What replaces a secret.</summary>
    public const string Redacted = "[redacted]";

    /// <summary>How many frames an error's text keeps.</summary>
    public const int MaxFrames = 5;

    /// <summary>
    /// Removes NULs (Postgres refuses them, and the whole run row would be lost with it), then
    /// keeps the last <see cref="OutputCap"/> code units behind a line saying the rest was
    /// trimmed. A cut through a surrogate pair keeps the lone half, as JavaScript does; it becomes
    /// U+FFFD once written out as UTF-8.
    /// </summary>
    public static string Cap(string text)
    {
        string clean = text.Contains('\0', StringComparison.Ordinal) ? text.Replace("\0", "", StringComparison.Ordinal) : text;
        if (clean.Length <= OutputCap)
        {
            return clean;
        }
        return "[earlier output trimmed]\n" + clean[^OutputCap..];
    }

    /// <summary>
    /// An error as a JavaScript stack reads, capped like output: <c>Name: message</c>, then up to
    /// five frames, each <c>"\n    at &lt;frame&gt;"</c>.
    /// </summary>
    public static string ErrorMessage(string name, string message, IReadOnlyList<string> frames)
    {
        var b = new StringBuilder(name).Append(": ").Append(message);
        for (int k = 0; k < Math.Min(MaxFrames, frames.Count); k++)
        {
            b.Append("\n    at ").Append(frames[k]);
        }
        return Cap(b.ToString());
    }

    /// <summary>
    /// An exception as the SDK writes an error: its name (the type's simple name without a
    /// generic arity, as JavaScript's <c>error.name</c> is short), its message (empty when there
    /// is none, as <c>new Error()</c> has an empty one), and up to five frames, innermost first,
    /// each <c>Example.Reports.Build (Reports.cs:42)</c>. An <see cref="AggregateException"/>
    /// holding one exception is written as that exception, as <c>await</c> hands it over; inner
    /// exceptions are otherwise not written, as the SDK writes only the error's own stack.
    /// </summary>
    public static string ErrorMessage(Exception error)
    {
        while (error is AggregateException { InnerExceptions.Count: 1 } one)
        {
            error = one.InnerExceptions[0];
        }
        return ErrorMessage(ErrorName(error), MessageOf(error), Frames(error));
    }

    /// <summary>
    /// What the SDK writes for anything thrown: an exception as <see cref="ErrorMessage(Exception)"/>,
    /// a string as it is, anything else as its JSON (or its <c>ToString</c> when it has none),
    /// capped like output.
    /// </summary>
    public static string ErrorMessage(object? error)
    {
        if (error is Exception e)
        {
            return ErrorMessage(e);
        }
        if (error is string s)
        {
            return Cap(s);
        }
        string text;
        try
        {
            text = Json.Stringify(error);
        }
        catch (ArgumentException)
        {
            text = error?.ToString() ?? "null";
        }
        return Cap(text);
    }

    /// <summary>The type's simple name, without a generic arity (<c>MyError</c>, not <c>MyError`1</c>).</summary>
    public static string ErrorName(Exception error) => WithoutArity(error.GetType().Name);

    /// <summary>The exception's message, empty when it has none or reading it throws.</summary>
    public static string MessageOf(Exception error)
    {
        try
        {
            return error.Message ?? "";
        }
        catch (Exception)
        {
            return "";
        }
    }

    private static string WithoutArity(string name)
    {
        int tick = name.IndexOf('`', StringComparison.Ordinal);
        return tick < 0 ? name : name[..tick];
    }

    /// <summary>
    /// Up to five of the exception's frames, innermost first, as a JavaScript stack writes them:
    /// the method, then the file and line in parentheses when there is a file. The runtime's own
    /// plumbing (the async method builders, awaiters and <c>ExceptionDispatchInfo</c>) is left
    /// out, as <c>Exception.ToString()</c> leaves it out, and an async method's state machine is
    /// written as the method a person wrote.
    /// </summary>
    public static List<string> Frames(Exception error)
    {
        var output = new List<string>(MaxFrames);
        StackFrame[] frames;
        try
        {
            frames = new StackTrace(error, true).GetFrames();
        }
        catch (Exception)
        {
            return output;
        }
        foreach (var f in frames)
        {
            if (output.Count >= MaxFrames)
            {
                break;
            }
            string? text = Frame(f);
            if (text != null)
            {
                output.Add(text);
            }
        }
        return output;
    }

    /// <summary>One frame, or null for a frame of the runtime's plumbing or one with no method.</summary>
    internal static string? Frame(StackFrame f)
    {
        DiagnosticMethodInfo? info = DiagnosticMethodInfo.Create(f);
        if (info == null)
        {
            return null;
        }
        string? method = Method(info.DeclaringTypeName, info.Name);
        if (method == null)
        {
            return null;
        }
        string? file = f.GetFileName();
        if (string.IsNullOrEmpty(file))
        {
            return method;
        }
        int line = f.GetFileLineNumber();
        string name = Path.GetFileName(file);
        return line > 0
            ? method + " (" + name + ":" + line.ToString(CultureInfo.InvariantCulture) + ")"
            : method + " (" + name + ")";
    }

    private static readonly string[] Plumbing =
    [
        "System.Runtime.CompilerServices.",
        "System.Runtime.ExceptionServices.",
        "System.Threading.Tasks.",
        "System.Threading.ExecutionContext",
    ];

    /// <summary>
    /// A frame's method as a person wrote it: <c>Namespace.Type.Method</c>, a nested type's
    /// <c>+</c> as a dot, generic arities left out, and an async method's or iterator's state
    /// machine (<c>Type+&lt;BuildAsync&gt;d__4.MoveNext</c>) as <c>Type.BuildAsync</c>. Null for
    /// the runtime's plumbing.
    /// </summary>
    internal static string? Method(string? declaringType, string name)
    {
        string type = declaringType ?? "";
        foreach (string p in Plumbing)
        {
            if (type.StartsWith(p, StringComparison.Ordinal))
            {
                return null;
            }
        }
        // A generic type's arguments are written in brackets after its arity.
        int bracket = type.IndexOf('[', StringComparison.Ordinal);
        if (bracket >= 0)
        {
            type = type[..bracket];
        }
        string[] parts = type.Split('+');
        for (int k = 0; k < parts.Length; k++)
        {
            parts[k] = WithoutArity(parts[k]);
        }
        string last = parts.Length > 0 ? parts[^1] : "";
        if (parts.Length > 1 && last.StartsWith('<'))
        {
            int close = last.IndexOf('>', StringComparison.Ordinal);
            if (close > 1 && close + 1 < last.Length && last[close + 1] == 'd')
            {
                // <BuildAsync>d__4: the state machine of BuildAsync.
                return string.Join('.', parts[..^1]) + "." + last[1..close];
            }
        }
        string joined = string.Join('.', parts);
        return joined.Length == 0 ? name : joined + "." + name;
    }

    /// <summary>One of the SDK's secret patterns and what replaces a match.</summary>
    private sealed record SecretPattern(JsRegex Re, Func<JsreMatch, string> Replacement)
    {
        public static SecretPattern Template(string source, string flags, string replacement)
        {
            var re = JsRegex.Compile(source, flags);
            // Only $1 is named in the SDK's replacements.
            return new SecretPattern(re, m => replacement.Replace("$1", m.Text(1), StringComparison.Ordinal));
        }
    }

    /// <summary>
    /// The SDK's patterns (<c>packages/sdk/src/output.ts</c>, <c>SECRET_PATTERNS</c>), as
    /// JavaScript source, character for character. Bounded quantifiers throughout, so a long line
    /// cannot make these backtrack. They apply in this order, each to the text the ones before it
    /// left.
    /// </summary>
    private static readonly SecretPattern[] Patterns =
    [
        // A PEM private key, header to footer. Without a footer (the output was trimmed) it runs
        // to the end of the base64 body. A "-" that starts five dashes ends the body, so the
        // footer is never swallowed into it.
        SecretPattern.Template(
            @"-----BEGIN (?:[A-Z0-9]{1,20} ){0,3}PRIVATE KEY-----(?:[A-Za-z0-9+/=\s,:]|-(?!----)){0,16384}(?:-----END (?:[A-Z0-9]{1,20} ){0,3}PRIVATE KEY-----)?",
            "g",
            Redacted),
        // password=..., API_KEY: ..., "client_secret": "...", TOKEN='...', token=...,
        // :password=>"..." (but not max_tokens: 800). A quoted value is blanked to its closing
        // quote, spaces and all, and keeps its quotes.
        new SecretPattern(
            JsRegex.Compile(
                @"\b([A-Za-z0-9_-]{0,40}(?:secret|token|passw(?:or)?d|pwd|api[_-]?key|access[_-]?key|private[_-]?key|credential)[A-Za-z0-9_-]{0,40}(?<![Tt][Oo][Kk][Ee][Nn][Ss])""?\s{0,3}(?:=>|[=:])\s{0,3})(?:("")[^""\n]{1,4096}""|(')[^'\n]{1,4096}'|[""']?[^\s""',;&]{1,4096})",
                "gi"),
            m =>
            {
                string quote = m.Group(2) != null ? m.Text(2) : m.Text(3);
                return m.Text(1) + quote + Redacted + quote;
            }),
        // Authorization: Basic <base64> and Authorization: Token <token>, also as a JSON or hash
        // entry.
        SecretPattern.Template(
            @"\b((?:proxy-)?authorization[""']?\s{0,3}(?:=>|[=:])\s{0,3}[""']?\s{0,3}(?:basic|token)\s{1,3})[A-Za-z0-9._~+/=:-]{1,4096}",
            "gi",
            "$1" + Redacted),
        // Credentials inside a URL: postgres://user:password@host. The password runs to the last
        // "@" before a "/" or a space, so one that contains "@" is blanked whole.
        SecretPattern.Template(@"(\b[a-z][a-z0-9+.-]{0,30}:\/\/[^\s/:@]{0,256}:)[^\s/]{1,256}@", "gi", "$1" + Redacted + "@"),
        // Authorization: Bearer <token>
        SecretPattern.Template(@"\b(Bearer\s{1,3})[A-Za-z0-9._~+/=-]{8,4096}", "g", "$1" + Redacted),
        // A bare JWT: three base64url segments, the first starting eyJ.
        SecretPattern.Template(@"\beyJ[A-Za-z0-9_-]{4,4096}\.[A-Za-z0-9_-]{4,4096}\.[A-Za-z0-9_-]{0,4096}", "g", Redacted),
        // Incoming webhook URLs carry their secret in the path.
        SecretPattern.Template(@"(\bhooks\.slack\.com\/(?:services|workflows|triggers)\/)[A-Za-z0-9/_-]{1,255}", "gi", "$1" + Redacted),
        SecretPattern.Template(@"(\bdiscord(?:app)?\.com\/api\/(?:v\d{1,2}\/)?webhooks\/)[A-Za-z0-9/_-]{1,255}", "gi", "$1" + Redacted),
        // Well-known token shapes: AWS, GitHub, Slack, Stripe, Anthropic, OpenAI and Google
        // style keys.
        SecretPattern.Template(@"\b(?:AKIA|ASIA)[0-9A-Z]{16}\b", "g", Redacted),
        SecretPattern.Template(@"\b(?:gh[pousr]_[A-Za-z0-9]{30,255}|github_pat_[A-Za-z0-9_]{20,255})\b", "g", Redacted),
        SecretPattern.Template(@"\bxox[abposr]-[A-Za-z0-9-]{10,255}", "g", Redacted),
        SecretPattern.Template(@"\b[rsp]k_(?:live|test)_[A-Za-z0-9]{10,255}\b", "g", Redacted),
        SecretPattern.Template(@"\bwhsec_[A-Za-z0-9+/=]{16,255}", "g", Redacted),
        SecretPattern.Template(@"\bsk-[A-Za-z0-9_-]{20,255}", "g", Redacted),
        SecretPattern.Template(@"\bAIza[0-9A-Za-z_-]{35}(?![0-9A-Za-z_-])", "g", Redacted),
    ];

    /// <summary>
    /// The default redact: blanks values that look like secrets (key=value pairs with secret-ish
    /// names, Authorization headers, URL credentials, bearer tokens, JWTs, PEM private keys,
    /// webhook URLs and well-known token formats) before output or an error is stored, shown or
    /// sent anywhere.
    /// </summary>
    public static string RedactSecrets(string text)
    {
        string output = text;
        foreach (var p in Patterns)
        {
            output = p.Re.Replace(output, p.Replacement);
        }
        return output;
    }
}
