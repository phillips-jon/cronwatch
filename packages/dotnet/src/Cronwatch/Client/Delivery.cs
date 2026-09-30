using System;
using System.Collections.Generic;
using System.Threading;
using System.Threading.Tasks;
using Cronwatch.Internal;

namespace Cronwatch;

/// <summary>Delivery: channels, triage, and the queue of alerts no channel accepted.</summary>
public sealed partial class CronwatchClient
{
    internal const int MaxUndelivered = 20;

    private static string AlertKey(Alert a) => a.Type.Value + "|" + Js.FormatLong(a.At) + "|" + (a.Run == null ? "" : a.Run.Id);

    /// <summary>Composes each draft, sends it (or queues it when delivering at check), and records what went where.</summary>
    internal async Task<IReadOnlyList<Alert>> DispatchAsync(IReadOnlyList<AlertDraft> drafts, Definition def, long now)
    {
        var composed = new List<Alert>();
        if (drafts.Count == 0)
        {
            return composed;
        }
        var delivered = new List<Alert>();
        var failed = new List<Alert>();
        foreach (var draft in drafts)
        {
            Alert alert = AlertFormat.ComposeAlert(draft, def, now);
            if (_deferDelivery)
            {
                failed.Add(alert);
                Count(alert, "queued");
            }
            else
            {
                if (_triage != null && alert.Type != AlertType.Recovered)
                {
                    alert = await AddTriageAsync(alert, Timings.Triage).ConfigureAwait(false);
                }
                (await DeliverAsync(alert).ConfigureAwait(false) ? delivered : failed).Add(alert);
            }
            composed.Add(alert);
        }
        await RecordDeliveryAsync(def.Name, delivered, failed, [], now).ConfigureAwait(false);
        return composed;
    }

    /// <summary>What one check has spent retrying alerts, across all jobs.</summary>
    internal sealed class RetryBudget
    {
        public TimeSpan Spent { get; set; }
    }

    /// <summary>
    /// Retries a job's queued alerts once, oldest first, within what is left of the check's
    /// budget; one that no longer describes the job is dropped.
    /// </summary>
    internal async Task<IReadOnlyList<Alert>> RetryUndeliveredAsync(string name, JobState state, long now, RetryBudget budget)
    {
        var pending = (IReadOnlyList<Alert>?)state.Undelivered ?? [];
        if (pending.Count == 0 || Evaluate.IsSilenced(state, now) || _deferDelivery)
        {
            return [];
        }
        var dropped = new List<Alert>();
        var delivered = new List<Alert>();
        var failed = new List<Alert>();
        var fresh = new List<Alert>();
        foreach (var a in pending)
        {
            (Evaluate.StaleAlert(a, state) ? dropped : fresh).Add(a);
        }
        foreach (var a in fresh)
        {
            TimeSpan left = Timings.RetryBudget - budget.Spent;
            if (left <= TimeSpan.Zero)
            {
                break;
            }
            long started = _time.GetTimestamp();
            Alert alert = a;
            // An alert queued by a process that delivers at check time was never triaged. One
            // that was tried is not tried again.
            if (_triage != null && alert.Type != AlertType.Recovered && !alert.TriageTried)
            {
                alert = await AddTriageAsync(alert, left < Timings.Triage ? left : Timings.Triage).ConfigureAwait(false);
            }
            (await DeliverAsync(alert).ConfigureAwait(false) ? delivered : failed).Add(alert);
            budget.Spent += _time.GetElapsedTime(started);
        }
        foreach (var a in dropped)
        {
            Count(a, "dropped");
        }
        await RecordDeliveryAsync(name, delivered, failed, dropped, now).ConfigureAwait(false);
        return delivered;
    }

    private async Task RecordDeliveryAsync(string name, List<Alert> delivered, List<Alert> failed, List<Alert> dropped, long now)
    {
        try
        {
            var (_, trimmed) = await UpdateStateAsync(name, previous =>
            {
                var state = MutableState.Of(Evaluate.NormalizeState(previous, name));
                var done = new HashSet<string>(StringComparer.Ordinal);
                foreach (var a in delivered)
                {
                    done.Add(AlertKey(a));
                }
                foreach (var a in dropped)
                {
                    done.Add(AlertKey(a));
                }
                var retried = new Dictionary<string, Alert>(StringComparer.Ordinal);
                foreach (var a in failed)
                {
                    retried[AlertKey(a)] = a;
                }
                var kept = new List<Alert>();
                var known = new HashSet<string>(StringComparer.Ordinal);
                foreach (var a in state.Queued())
                {
                    string key = AlertKey(a);
                    if (done.Contains(key))
                    {
                        continue;
                    }
                    kept.Add(retried.TryGetValue(key, out var r) ? r : a);
                    known.Add(key);
                }
                foreach (var a in failed)
                {
                    if (!known.Contains(AlertKey(a)))
                    {
                        kept.Add(a);
                    }
                }
                int cut = Math.Max(0, kept.Count - MaxUndelivered);
                state.Undelivered = kept.GetRange(cut, kept.Count - cut);
                if (delivered.Count > 0)
                {
                    state.LastAlertAt = now;
                }
                return (state.ToState(), cut);
            }).ConfigureAwait(false);
            if (trimmed > 0)
            {
                Report(
                    trimmed + " undelivered alert" + (trimmed == 1 ? "" : "s") + " for " + name + " dropped: only the newest "
                    + MaxUndelivered + " are kept for retry",
                    "alert queue for " + name);
            }
        }
        catch (Exception e)
        {
            Report(e, "recording alert delivery for " + name);
        }
    }

    /// <summary>
    /// Sends the alert to every channel at once, each within its time; true when any accepted it
    /// (or there are none).
    /// </summary>
    internal async Task<bool> DeliverAsync(Alert alert)
    {
        if (_channels.Count == 0)
        {
            return true;
        }
        var sends = new Task<bool>[_channels.Count];
        for (int i = 0; i < _channels.Count; i++)
        {
            IChannel channel = _channels[i];
            sends[i] = Spawn(() => SendOneAsync(channel, alert));
        }
        bool ok = false;
        foreach (bool sent in await Task.WhenAll(sends).ConfigureAwait(false))
        {
            ok |= sent;
        }
        return ok;
    }

    private async Task<bool> SendOneAsync(IChannel channel, Alert alert)
    {
        string where = "alert channel " + channel.Name;
        var context = new ChannelContext(e => Report(e, where), _transport);
        using var cts = CancellationTokenSource.CreateLinkedTokenSource(_closing.Token);
        try
        {
            Task send = channel.SendAsync(alert, context, cts.Token);
            await send.WaitAsync(Timings.Channel, _time).ConfigureAwait(false);
            Count(alert, "sent", channel.Name);
            return true;
        }
        catch (TimeoutException)
        {
            await cts.CancelAsync().ConfigureAwait(false);
            Report("timed out after " + (long)Timings.Channel.TotalMilliseconds + "ms", where);
        }
        catch (Exception e)
        {
            Report(e, where);
        }
        Count(alert, "failed", channel.Name);
        return false;
    }

    private static void Count(Alert alert, string outcome, string? channel = null) =>
        CronwatchTelemetry.Add(
            CronwatchTelemetry.Alerts,
            new("cronwatch.channel", channel),
            new("cronwatch.type", alert.Type.Value),
            new("cronwatch.outcome", outcome));

    private async Task<Alert> AddTriageAsync(Alert alert, TimeSpan timeout)
    {
        string where = "triage for " + alert.Job;
        ITriage? triage = _triage;
        if (triage == null)
        {
            return alert.WithTriage(null);
        }
        IReadOnlyList<Run> recent;
        try
        {
            recent = await CallAsync(() => _store.ListRunsAsync(alert.Job, 5)).ConfigureAwait(false);
        }
        catch (Exception e)
        {
            Report(e, where);
            return alert.WithTriage(null);
        }
        using var cts = CancellationTokenSource.CreateLinkedTokenSource(_closing.Token);
        try
        {
            var context = new TriageContext(alert, recent) { Transport = _transport };
            Task<string?> task = Spawn(() => triage.TriageAsync(context, cts.Token));
            string? text = await task.WaitAsync(timeout, _time).ConfigureAwait(false);
            return alert.WithTriage(string.IsNullOrEmpty(text) ? null : text);
        }
        catch (TimeoutException)
        {
            await cts.CancelAsync().ConfigureAwait(false);
            Report("timed out after " + (long)timeout.TotalMilliseconds + "ms", where);
        }
        catch (Exception e)
        {
            Report(e, where);
        }
        return alert.WithTriage(null);
    }
}
