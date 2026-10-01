using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using Cronwatch.Internal;

namespace Cronwatch.Alerts;

/// <summary>Configures <see cref="TwilioChannel"/>. Its <see cref="ToString"/> never shows a credential or a number.</summary>
[DebuggerDisplay("{ToString(),nq}")]
public sealed class TwilioOptions
{
    /// <summary>The account SID, <c>AC...</c>. It is in the URL whichever credentials sign the request.</summary>
    public string? AccountSid { get; init; }

    /// <summary>The account's auth token. Or give an API key SID and secret instead.</summary>
    public string? AuthToken { internal get; init; }

    /// <summary>An API key SID, <c>SK...</c>, with <see cref="ApiKeySecret"/>, in place of the auth token.</summary>
    public string? ApiKeySid { internal get; init; }

    /// <summary>The API key's secret.</summary>
    public string? ApiKeySecret { internal get; init; }

    /// <summary>A Twilio number in E.164 form, <c>+15005550006</c>. Or give a messaging service SID.</summary>
    public string? From { get; init; }

    /// <summary>A messaging service SID, <c>MG...</c>, in place of <see cref="From"/>.</summary>
    public string? MessagingServiceSid { get; init; }

    /// <summary>The numbers in E.164 form; each gets its own text. Blank ones are left out.</summary>
    public IList<string> To { get; init; } = new List<string>();

    /// <summary>Also text when a job recovers. Default false: a text is for what needs a person.</summary>
    public bool Recovered { get; init; }

    /// <summary>How many SMS segments a text may use, held to 1 to 10. Default 3. (A <c>double?</c> before 1.0, the SDK's number.)</summary>
    public int? Segments { get; init; }

    /// <summary>A link back to the job in your dashboard. Null or <c>""</c> is no link.</summary>
    public Func<Alert, string?>? Link { get; init; }

    /// <summary>Sends this channel's requests; by default the client's transport.</summary>
    public ITransport? Transport { get; init; }

    /// <summary>Names what is set, never a credential or a number.</summary>
    public override string ToString() =>
        "TwilioOptions(accountSid " + ChannelShared.Set(AccountSid)
        + (string.IsNullOrEmpty(ApiKeySid) ? ", authToken " + ChannelShared.Set(AuthToken) : ", apiKeySid set, apiKeySecret " + ChannelShared.Set(ApiKeySecret))
        + ", to " + To.Count.ToString(CultureInfo.InvariantCulture) + ", recovered " + (Recovered ? "true" : "false") + ")";
}

/// <summary>
/// Texts alerts through Twilio (<c>alerts/twilio.ts</c>), to every number at once: <c>POST
/// https://api.twilio.com/2010-04-01/Accounts/&lt;AccountSid&gt;/Messages.json</c>, form
/// encoded, with basic auth. The alert counts as delivered when any number took it; each number
/// that refused it is reported to the client's error handler. It fails only when every number did.
/// </summary>
public sealed class TwilioChannel : IChannel
{
    /// <summary>The most segments a text may use, which keeps it inside Twilio's 1600 character limit.</summary>
    public const int MaxSegments = 10;

    /// <summary>The longest Body Twilio takes.</summary>
    internal const int MaxBody = 1600;

    // The GSM 03.38 alphabet: a message in it takes 153 characters a segment (when split),
    // anything else is UCS-2 at 67. The extension table costs two.
    private const string Gsm =
        "@\u00a3$\u00a5\u00e8\u00e9\u00f9\u00ec\u00f2\u00c7\n\u00d8\u00f8\r\u00c5\u00e5\u0394_\u03a6\u0393\u039b\u03a9\u03a0\u03a8\u03a3\u0398\u039e\u00c6\u00e6\u00df\u00c9 !\"#\u00a4%&'()*+,-./0123456789:;<=>?\u00a1ABCDEFGHIJKLMNOPQRSTUVWXYZ\u00c4\u00d6\u00d1\u00dc\u00a7\u00bfabcdefghijklmnopqrstuvwxyz\u00e4\u00f6\u00f1\u00fc\u00e0";

    private const string GsmExtended = "^{}\\[~]|\u20ac\f";

    private readonly string _url;
    private readonly string _authorization;
    private readonly string _password;
    private readonly string _from;
    private readonly string _messagingServiceSid;
    private readonly List<string> _to;
    private readonly bool _recovered;
    private readonly double _segments;
    private readonly Func<Alert, string?>? _link;
    private readonly ITransport? _transport;

    /// <summary>The channel.</summary>
    /// <exception cref="CronwatchException">Without an account SID, credentials, a sender or a number.</exception>
    public TwilioChannel(TwilioOptions options)
    {
        ArgumentNullException.ThrowIfNull(options);
        // A pasted credential often carries a stray space or newline, which the Authorization
        // header would refuse.
        string sid = ChannelShared.Trimmed(options.AccountSid);
        if (sid.Length == 0)
        {
            throw ChannelShared.Invalid("Twilio needs an AccountSid");
        }
        string keySid = ChannelShared.Trimmed(options.ApiKeySid);
        string user = keySid.Length == 0 ? sid : keySid;
        _password = keySid.Length == 0 ? ChannelShared.Trimmed(options.AuthToken) : ChannelShared.Trimmed(options.ApiKeySecret);
        if (_password.Length == 0)
        {
            throw ChannelShared.Invalid("Twilio needs an AuthToken, or an ApiKeySid and ApiKeySecret");
        }
        if (string.IsNullOrEmpty(options.From) && string.IsNullOrEmpty(options.MessagingServiceSid))
        {
            throw ChannelShared.Invalid("Twilio needs a From number or a MessagingServiceSid");
        }
        _to = [];
        foreach (string? n in options.To ?? [])
        {
            string t = ChannelShared.Trimmed(n);
            if (t.Length > 0)
            {
                _to.Add(t);
            }
        }
        if (_to.Count == 0)
        {
            throw ChannelShared.Invalid("Twilio needs at least one To number");
        }
        _url = "https://api.twilio.com/2010-04-01/Accounts/" + ChannelShared.EncodeUriComponent(sid) + "/Messages.json";
        _authorization = ChannelShared.BasicAuth(user, _password);
        _from = options.From ?? "";
        _messagingServiceSid = options.MessagingServiceSid ?? "";
        _recovered = options.Recovered;
        _segments = options.Segments ?? double.NaN;
        _link = options.Link;
        _transport = options.Transport;
    }

    /// <inheritdoc/>
    public string Name => "twilio";

    /// <inheritdoc/>
    public async Task SendAsync(Alert alert, ChannelContext context, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(alert);
        ArgumentNullException.ThrowIfNull(context);
        if (alert.Type == AlertType.Recovered && !_recovered)
        {
            return;
        }
        string body = SmsBody(alert, ChannelShared.Link(_link, alert), _segments);
        ITransport transport = ChannelShared.Transport(_transport, context);
        var sends = new Task<string?>[_to.Count];
        for (int i = 0; i < _to.Count; i++)
        {
            var form = new List<KeyValuePair<string, string>> { new("To", _to[i]) };
            form.Add(_messagingServiceSid.Length > 0 ? new("MessagingServiceSid", _messagingServiceSid) : new("From", _from));
            form.Add(new("Body", body));
            sends[i] = TextAsync(transport, ChannelShared.Form(form), cancellationToken);
        }
        string?[] errors = await Task.WhenAll(sends).ConfigureAwait(false);
        cancellationToken.ThrowIfCancellationRequested();
        var failed = new List<int>();
        for (int i = 0; i < errors.Length; i++)
        {
            if (errors[i] != null)
            {
                failed.Add(i);
            }
        }
        if (failed.Count == 0)
        {
            return;
        }
        int n = _to.Count;
        if (failed.Count == n)
        {
            string message = errors[failed[0]]!;
            throw Post.Fail(n > 1 ? message + " (" + failed.Count.ToString(CultureInfo.InvariantCulture) + " of " + n.ToString(CultureInfo.InvariantCulture) + " numbers failed)" : message);
        }
        // Delivered to someone: counted as sent, so a retry never texts the numbers that took it again.
        foreach (int i in failed)
        {
            context.ReportError(
                errors[i] + " (to " + MaskNumber(_to[i]) + "; " + (n - failed.Count).ToString(CultureInfo.InvariantCulture) + " of "
                + n.ToString(CultureInfo.InvariantCulture) + " numbers took the alert)");
        }
    }

    /// <summary>One text: null when it went, else why not.</summary>
    private async Task<string?> TextAsync(ITransport transport, string form, CancellationToken cancellationToken)
    {
        try
        {
            await ChannelShared.SendAsync(
                transport,
                "Twilio",
                _url,
                ChannelShared.Headers("content-type", "application/x-www-form-urlencoded", "authorization", _authorization),
                form,
                [_password],
                cancellationToken).ConfigureAwait(false);
            return null;
        }
        catch (Exception e) when (e is not OperationCanceledException || !cancellationToken.IsCancellationRequested)
        {
            return string.IsNullOrEmpty(e.Message) ? e.GetType().Name : e.Message;
        }
    }

    /// <summary>A number with all but its last four digits hidden, for an error message.</summary>
    internal static string MaskNumber(string number)
    {
        int n = number.Length;
        return n <= 4 ? number : new string('*', Math.Min(n - 4, 8)) + Js.Tail(number, 4);
    }

    /// <summary>The code points of a text, each as its one or two UTF-16 units (a lone surrogate alone).</summary>
    private static List<string> CodePoints(string text)
    {
        var output = new List<string>();
        for (int i = 0; i < text.Length;)
        {
            int size = char.IsSurrogatePair(text, i) ? 2 : 1;
            output.Add(text.Substring(i, size));
            i += size;
        }
        return output;
    }

    /// <summary>
    /// The segments <paramref name="text"/> takes. A character is never split across two: an
    /// extension character (two septets) or a surrogate pair (two UCS-2 units) that would straddle
    /// a boundary starts the next segment, as phones pack them.
    /// </summary>
    internal static int SmsSegments(string text)
    {
        var points = CodePoints(text);
        var units = new List<int>();
        bool gsm = true;
        foreach (string cp in points)
        {
            if (cp.Length == 1 && Gsm.Contains(cp[0], StringComparison.Ordinal))
            {
                units.Add(1);
            }
            else if (cp.Length == 1 && GsmExtended.Contains(cp[0], StringComparison.Ordinal))
            {
                units.Add(2);
            }
            else
            {
                gsm = false;
                break;
            }
        }
        int single = 160;
        int per = 153;
        if (!gsm)
        {
            single = 70;
            per = 67;
            units.Clear();
            foreach (string cp in points)
            {
                units.Add(cp.Length);
            }
        }
        int total = 0;
        foreach (int u in units)
        {
            total += u;
        }
        if (total <= single)
        {
            return 1;
        }
        int count = 1;
        int used = 0;
        foreach (int u in units)
        {
            if (used + u > per)
            {
                count++;
                used = 0;
            }
            used += u;
        }
        return count;
    }

    /// <summary>Whether <paramref name="text"/> fits within <paramref name="segments"/> SMS segments and Twilio's Body limit.</summary>
    private static bool Fits(string text, int segments) => text.Length <= MaxBody && SmsSegments(text) <= segments;

    /// <summary>A segment count held to 1 to <see cref="MaxSegments"/>; 3 for anything not a number.</summary>
    internal static int SegmentBudget(double segments) =>
        !double.IsFinite(segments) ? 3 : (int)Math.Min(MaxSegments, Math.Max(1, Math.Floor(segments)));

    /// <summary>
    /// The title, then as many lines of the message (and the triage) as fit, then the link. The
    /// link is kept whole; the text before it is cut to make room.
    /// </summary>
    internal static string SmsBody(Alert a, string link, double segments)
    {
        int budget = SegmentBudget(segments);
        string tail = link.Length == 0 ? "" : "\n" + link;
        var lines = new List<string> { a.Title };
        foreach (string l in a.Message.Split('\n'))
        {
            if (Js.Trim(l).Length > 0)
            {
                lines.Add(l);
            }
        }
        string triage = ChannelShared.Triage(a);
        if (triage.Length > 0)
        {
            lines.Add("Triage: " + triage);
        }
        string text = "";
        foreach (string line in lines)
        {
            string next = text.Length == 0 ? line : text + "\n" + line;
            if (Fits(next + tail, budget))
            {
                text = next;
                continue;
            }
            // Part of this line, cut on a code point and marked.
            var chars = CodePoints(line);
            int lo = 0;
            int hi = chars.Count;
            string before = text.Length == 0 ? "" : text + "\n";
            while (lo < hi)
            {
                int mid = (lo + hi + 1) / 2;
                string candidate = before + Join(chars, mid) + "...";
                if (Fits(candidate + tail, budget))
                {
                    lo = mid;
                }
                else
                {
                    hi = mid - 1;
                }
            }
            if (lo > 0)
            {
                text = before + Join(chars, lo) + "...";
            }
            break;
        }
        // Only a link too long for any budget gets here too long; Twilio would refuse it whole.
        return Post.Cut(text + tail, MaxBody);
    }

    private static string Join(List<string> points, int count)
    {
        var b = new StringBuilder();
        for (int i = 0; i < count; i++)
        {
            b.Append(points[i]);
        }
        return b.ToString();
    }

    /// <summary>Names the channel.</summary>
    public override string ToString() => "TwilioChannel";
}
