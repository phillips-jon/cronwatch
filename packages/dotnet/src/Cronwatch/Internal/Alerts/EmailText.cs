using System;
using System.Collections.Generic;
using System.Text;

namespace Cronwatch.Internal;

/// <summary>The options every email channel shares, checked.</summary>
/// <param name="From">The sender.</param>
/// <param name="To">The recipients, trimmed, none blank.</param>
/// <param name="SubjectPrefix">Put in front of the title, or "".</param>
/// <param name="Link">A link back to the job, or null.</param>
internal sealed record EmailSettings(string From, IReadOnlyList<string> To, string SubjectPrefix, Func<Alert, string?>? Link)
{
    /// <summary>
    /// The settings, checked once, when the channel is made: a sender, and the to addresses with
    /// blanks dropped and each trimmed.
    /// </summary>
    public static EmailSettings Of(string name, string? from, IEnumerable<string>? to, string? subjectPrefix, Func<Alert, string?>? link)
    {
        if (string.IsNullOrEmpty(from))
        {
            throw ChannelShared.Invalid(name + " needs a From address");
        }
        var kept = new List<string>();
        foreach (string? a in to ?? [])
        {
            string t = ChannelShared.Trimmed(a);
            if (t.Length > 0)
            {
                kept.Add(t);
            }
        }
        if (kept.Count == 0)
        {
            throw ChannelShared.Invalid(name + " needs at least one To address");
        }
        return new EmailSettings(from, kept, subjectPrefix ?? "", link);
    }

    /// <summary>The count of recipients only.</summary>
    public override string ToString() => "EmailSettings(" + To.Count + " recipients)";
}

/// <summary>One alert as a mail.</summary>
internal sealed record EmailMail(string From, IReadOnlyList<string> To, string Subject, string Text, string Html);

/// <summary>
/// What every email channel sends (<c>alerts/email.ts</c>): one subject, a plain text body and a
/// small HTML body, so an alert reads the same whichever provider carries it.
/// </summary>
internal static class EmailText
{
    /// <summary>The mail for an alert.</summary>
    public static EmailMail Compose(Alert a, EmailSettings s)
    {
        string link = SafeLink(ChannelShared.Link(s.Link, a));
        string prefix = s.SubjectPrefix.Length == 0 ? "" : s.SubjectPrefix + " ";
        // One line: a newline in a subject is a header injection or a rejected send.
        string subject = Post.Cut(OneLine(prefix + a.Title), 250);
        return new EmailMail(s.From, s.To, subject, ChannelShared.PlainText(a, link), Html(a, link));
    }

    /// <summary><c>.replace(/[\r\n]+/g, " ")</c>.</summary>
    public static string OneLine(string text)
    {
        var b = new StringBuilder(text.Length);
        bool breaking = false;
        foreach (char c in text)
        {
            if (c is '\r' or '\n')
            {
                if (!breaking)
                {
                    b.Append(' ');
                }
                breaking = true;
            }
            else
            {
                b.Append(c);
                breaking = false;
            }
        }
        return b.ToString();
    }

    /// <summary>Escapes text for HTML content and double quoted attributes.</summary>
    public static string EscapeHtml(string text) =>
        text.Replace("&", "&amp;", StringComparison.Ordinal)
            .Replace("<", "&lt;", StringComparison.Ordinal)
            .Replace(">", "&gt;", StringComparison.Ordinal)
            .Replace("\"", "&quot;", StringComparison.Ordinal)
            .Replace("'", "&#39;", StringComparison.Ordinal);

    /// <summary>Only http and https links are put in a mail; anything else is dropped.</summary>
    public static string SafeLink(string link)
    {
        // ASCII letters only, as /^https?:\/\//i reads them.
        string lower = WhatwgUrl.AsciiLower(link[..Math.Min(8, link.Length)]);
        return lower.StartsWith("http://", StringComparison.Ordinal) || lower.StartsWith("https://", StringComparison.Ordinal) ? link : "";
    }

    private static string Html(Alert a, string link)
    {
        var parts = new List<string>
        {
            "<!doctype html>",
            "<html><body style=\"margin:0;padding:16px;font-family:Georgia,serif;color:#1d1b16;background:#ffffff\">",
            "<p style=\"margin:0 0 12px;font-size:18px\"><strong>" + EscapeHtml(a.Title) + "</strong></p>",
            "<pre style=\"margin:0 0 12px;padding:12px;background:#f6f3ec;white-space:pre-wrap;word-break:break-word;font:13px/1.45 Menlo,Consolas,monospace\">"
                + EscapeHtml(a.Message) + "</pre>",
        };
        string triage = ChannelShared.Triage(a);
        if (triage.Length > 0)
        {
            parts.Add("<p style=\"margin:0 0 12px\"><em>Triage:</em> " + EscapeHtml(triage) + "</p>");
        }
        if (link.Length > 0)
        {
            parts.Add("<p style=\"margin:0\"><a href=\"" + EscapeHtml(link) + "\">Open " + EscapeHtml(a.Job) + "</a></p>");
        }
        parts.Add("</body></html>");
        return string.Join('\n', parts);
    }

    /// <summary>
    /// <c>Name &lt;a@b.c&gt;</c> split into its parts; a bare address has no name (email.ts's
    /// <c>parseAddress</c>: <c>/^\s*(.*?)\s*&lt;([^&lt;&gt;]+)&gt;\s*$/</c>, then the name without
    /// the double quotes around it).
    /// </summary>
    public static JsObject ParseAddress(string text)
    {
        var bare = new JsObject().Set("email", Js.Trim(text));
        string s = Js.TrimEnd(text);
        if (!s.EndsWith('>'))
        {
            return bare;
        }
        string inner = s[..^1];
        int at = inner.LastIndexOf('<');
        if (at < 0)
        {
            return bare;
        }
        string address = inner[(at + 1)..];
        if (address.Length == 0 || address.Contains('>', StringComparison.Ordinal))
        {
            return bare;
        }
        string name = Js.Trim(inner[..at]);
        // JavaScript's . matches no line terminator.
        foreach (char c in name)
        {
            if (c is '\n' or '\r' or '\u2028' or '\u2029')
            {
                return bare;
            }
        }
        if (name.Length >= 2 && name.StartsWith('"') && name.EndsWith('"'))
        {
            name = name[1..^1];
        }
        var o = new JsObject().Set("email", Js.Trim(address));
        if (name.Length > 0)
        {
            o.Set("name", name);
        }
        return o;
    }
}
