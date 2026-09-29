defmodule Cronwatch.Web.Timeline do
  @moduledoc false
  # The dashboard's timelines (routes/timeline.ts), markup for markup,
  # carried over from the Go port's routes_timeline.go through the Rust
  # port's web/timeline.rs: one lane per job (or per day, on a job's page),
  # drawn on the server as inline SVG so the page needs no script.
  #
  # Every time a job was due is a faint tick, worked out from its schedule
  # with the same functions the checks use, so the lane shows the cadence the
  # job is meant to keep. Every run it recorded is a solid mark on top, as
  # wide as it took and coloured by how it ended. A slot the check has
  # reported missed is a dashed box. The empty part of a lane carries a short
  # note about anything open, and a visually hidden list says the same things
  # in words. Every time is UTC: without script the page cannot know the
  # viewer's zone.

  alias Cronwatch.Duration
  alias Cronwatch.Evaluate
  alias Cronwatch.Format
  alias Cronwatch.JS
  alias Cronwatch.JS.Object
  alias Cronwatch.Schedule

  import Cronwatch.Web.Text, only: [escape_html: 1, escape_name: 1, encode_uri_component: 1, num: 1, to_fixed: 2]

  @hour_ms 3_600_000
  @day_ms 24 * @hour_ms
  # The board's span: the last day, plus a few hours ahead so what is due
  # soon shows.
  @board_behind_ms @day_ms
  @board_ahead_ms 3 * @hour_ms
  # How many jobs the board's timeline draws. The table below it lists every
  # job.
  @board_lanes 30
  # Runs read for a lane when the twenty the table reads start inside the
  # span, so a frequent job's lane is not cut short.
  @board_runs 200
  @week_days 7
  # Width of a lane in SVG units. Lanes stretch to fit, so strokes do not
  # scale.
  @lane_width 1000.0
  # A lane with more due times than this shows its cadence as a dotted line.
  @max_ticks 330
  # More missed slots than this are drawn as one dashed band.
  @max_boxes 8
  # The narrowest a missed box is drawn, in SVG units.
  @min_box 10.0

  @month_names List.to_tuple(~w(Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec))
  @weekday_names List.to_tuple(~w(Sun Mon Tue Wed Thu Fri Sat))

  def board_behind_ms, do: @board_behind_ms
  def board_ahead_ms, do: @board_ahead_ms
  def board_lanes, do: @board_lanes
  def board_runs, do: @board_runs

  @doc "\"22:42\", in UTC."
  def clock_utc(t), do: t |> JS.iso_string() |> binary_part(11, 5)

  # The UTC month (1 to 12), day and weekday (0 for Sunday) of t.
  defp civil(t) do
    days = JS.floor_div(t, @day_ms)
    {_, m, d} = JS.civil_from_days(days)
    {m, d, JS.modulo(days + 4, 7)}
  end

  # "Sat 26 Sep", in UTC.
  defp day_label(t) do
    {m, d, wd} = civil(t)
    "#{elem(@weekday_names, wd)} #{d} #{elem(@month_names, m - 1)}"
  end

  @doc """
  "22:42" on the same UTC day as `now`, otherwise "25 Sep 22:42". A time
  before the year 1 or after 9999 (a start read from a foreign or damaged
  row) is "before 1 Jan 0001 00:00" or "after 31 Dec 9999 23:59".
  """
  def when_utc(t, _now) when t > 253_402_300_799_999, do: "after 31 Dec 9999 23:59"
  def when_utc(t, _now) when t < -62_135_596_800_000, do: "before 1 Jan 0001 00:00"

  def when_utc(t, now) do
    if JS.floor_div(t, @day_ms) == JS.floor_div(now, @day_ms) do
      clock_utc(t)
    else
      {m, d, _} = civil(t)
      "#{d} #{elem(@month_names, m - 1)} #{clock_utc(t)}"
    end
  end

  @doc "The job's schedule, parsed, or nil when it has none or it no longer parses."
  def lane_schedule(job) do
    if Format.truthy?(Object.get(job.definition, "schedule")) do
      case Evaluate.parsed_schedule(job.definition) do
        {:ok, p} -> p
        _ -> nil
      end
    end
  end

  defp grace(job) do
    case Evaluate.grace_ms(job.definition) do
      {:ok, ms} -> ms
      _ -> 0
    end
  end

  # When the job was due within from to to, ascending, and whether they are
  # too many to draw one by one. A cron's fires come from its schedule. An
  # interval is due one period after each run started, and after the last
  # run once a period for as long as nothing runs; with no run yet, from its
  # next expected time.
  defp due_times(_job, nil, _runs, _from, _to), do: {[], false}

  defp due_times(job, %Schedule{kind: "interval", every_ms: every}, runs, from, to) do
    cond do
      every <= 0 ->
        {[], false}

      (to - from) / every > @max_ticks ->
        {[], true}

      true ->
        starts = runs |> Enum.map(& &1.started_at) |> Enum.sort()
        set = starts |> Enum.map(&(&1 + every)) |> Enum.filter(&(&1 >= from and &1 <= to)) |> MapSet.new()

        next =
          case List.last(starts) do
            nil -> job.next_expected_at
            s -> s + every
          end

        set =
          if next do
            t = if next < from, do: next + ceil_div(from - next, every) * every, else: next
            add_every(set, t, to, every)
          else
            set
          end

        {set |> MapSet.to_list() |> Enum.sort(), false}
    end
  end

  defp due_times(_job, parsed, _runs, from, to) do
    case Schedule.fires_between(parsed, from - 1, to, @max_ticks) do
      nil -> {[], true}
      fires -> {fires, false}
    end
  end

  defp ceil_div(a, b), do: -JS.floor_div(-a, b)

  defp add_every(set, t, to, _every) when t > to, do: set
  defp add_every(set, t, to, every), do: add_every(MapSet.put(set, t), t + every, to, every)

  @doc """
  The slot a missed job was due at, the one the check reported: the first
  fire its last run does not cover. A job that never ran has no run to count
  from, so the latest due time whose grace has passed stands in. nil when
  missed is not open.
  """
  def missed_at(_job, nil, _times, _now), do: nil

  def missed_at(job, parsed, times, now) do
    if "missed" in job.open do
      grace = grace(job)

      case job.last_run do
        %{started_at: last} ->
          case Schedule.expectation(parsed, last, last, grace) do
            %{due_at: due} -> due
            nil -> nil
          end

        nil ->
          times |> Enum.reverse() |> Enum.find(&(&1 + grace < now))
      end
    end
  end

  defp stuck?(job, run, now) do
    case Evaluate.stuck?(job.definition, run, now) do
      {:ok, b} -> b
      _ -> false
    end
  end

  defp tone_of(%{status: "running"} = run, job, now), do: if(stuck?(job, run, now), do: "stuck", else: "running")
  defp tone_of(%{status: "failed"}, _job, _now), do: "bad"
  defp tone_of(%{status: "timeout"}, _job, _now), do: "timeout"

  defp tone_of(run, job, _now) do
    latest = job.last_run != nil and job.last_run.id == run.id
    if latest and ("over_budget" in job.open or "slow" in job.open), do: "warn", else: "ok"
  end

  defp timeout_text(job) do
    case Evaluate.timeout_ms(job.definition) do
      {:ok, ms} -> Duration.format(ms)
      _ -> "configured"
    end
  end

  # One run, as its tooltip says it.
  defp describe_run(run, tone, job, now) do
    at = "#{when_utc(run.started_at, now)} UTC"

    case tone do
      "running" ->
        "running since #{at}, #{Duration.format(now - run.started_at)} so far"

      "stuck" ->
        "running since #{at}, past its #{timeout_text(job)} timeout"

      _ ->
        took = if run.duration_ms, do: ", took #{Duration.format(run.duration_ms)}", else: ""

        extra =
          cond do
            tone != "warn" -> ""
            "over_budget" in job.open -> ", over budget"
            true -> ", slow"
          end

        "#{run.status} at #{at}#{took}#{extra}"
    end
  end

  # The metrics of the job's last run that went over their ceilings.
  defp over_ceilings(job) do
    case Object.get(job.definition, "budget") do
      %Object{} = budget ->
        for {k, limit} <- Object.to_list(budget),
            greater?(metric(job, k), Evaluate.js_number(limit)),
            do: k

      _ ->
        []
    end
  end

  defp metric(%{last_run: nil}, _k), do: :neg_infinity
  defp metric(%{last_run: run}, k), do: Object.get(run.metrics, k, :neg_infinity)

  @doc "`a > b` for JavaScript numbers, NaN never greater."
  def greater?(a, b) do
    cond do
      a == :nan or b == :nan -> false
      a == :neg_infinity or b == :infinity -> false
      a == :infinity or b == :neg_infinity -> true
      true -> a > b
    end
  end

  @doc "What is worth saying about the job in a few words, or `\"\"` when all is well."
  def lane_note(job, missed, now) do
    last = job.last_run
    open? = &(&1 in job.open)

    cond do
      job.silenced_until != nil and job.silenced_until > now ->
        "silenced until #{when_utc(job.silenced_until, now)}"

      open?.("missed") ->
        if missed, do: "due #{when_utc(missed, now)}, nothing ran", else: "overdue, nothing ran"

      last != nil and last.status == "running" ->
        if stuck?(job, last, now),
          do: "running since #{when_utc(last.started_at, now)}, past its #{timeout_text(job)} timeout",
          else: "running since #{when_utc(last.started_at, now)}"

      last != nil and last.status == "failed" ->
        text = "failed at #{when_utc(last.started_at, now)}"
        if job.consecutive_failures > 1, do: text <> ", #{num(job.consecutive_failures)} in a row", else: text

      last != nil and last.status == "timeout" ->
        "timed out at #{when_utc(last.started_at, now)}"

      open?.("stuck") ->
        "stuck"

      open?.("over_budget") and last != nil ->
        over = over_ceilings(job)
        text = if over == [], do: "went over budget", else: "went over budget on #{Enum.join(over, " and ")}"
        "#{text} at #{when_utc(last.started_at, now)}"

      open?.("slow") and last != nil and last.duration_ms != nil ->
        "slow: took #{Duration.format(last.duration_ms)}"

      open?.("failed") ->
        "failing"

      last == nil and job.next_expected_at != nil ->
        "no runs yet, first due #{when_utc(job.next_expected_at, now)}"

      true ->
        ""
    end
  end

  # toFixed(1), the precision every coordinate is written with.
  defp fx(n), do: to_fixed(n, 1)

  # The animation delay for a mark at x, so marks arrive in time order, left
  # to right.
  defp delay(x, base, per_unit), do: "--d:#{num(JS.round(base + max(x, 0.0) * per_unit))}ms"

  defp finished_or(run, now), do: run.finished_at || now

  defp clamp(v), do: v |> max(0.0) |> min(@lane_width)

  # A lane's x for a time.
  defp x({from, to, _now}, t), do: clamp((t - from) / (to - from) * @lane_width)

  defp lane(job, runs, complete, {from, to, now} = sp, now_in_lane, name) do
    parsed = lane_schedule(job)
    {times, dense} = due_times(job, parsed, runs, from, to)
    missed = missed_at(job, parsed, times, now)
    grace = grace(job)
    ahead_now = now_in_lane and now > from and now < to

    head =
      if ahead_now,
        do: ~s(<rect class="ahead" x="#{fx(x(sp, now))}" y="0" width="#{fx(@lane_width - x(sp, now))}" height="24"/>),
        else: ""

    in_span =
      runs
      |> Enum.filter(&(&1.started_at <= to and finished_or(&1, now) >= from))
      |> Enum.sort_by(& &1.started_at)

    unloaded =
      if not complete and runs != [] do
        oldest = runs |> Enum.map(& &1.started_at) |> Enum.min()

        if oldest > from do
          title = escape_html("#{name}: runs before #{when_utc(oldest, now)} UTC are not loaded here")
          ~s(<rect class="unloaded" x="0" y="4" width="#{fx(x(sp, oldest))}" height="16"><title>#{title}</title></rect>)
        else
          ""
        end
      else
        ""
      end

    cadence =
      if dense do
        title = escape_html("#{name}: due #{schedule_text(job, "")}, too often to mark each time")
        ~s(<line class="cadence" x1="0" y1="12" x2="1000" y2="12"><title>#{title}</title></line>)
      else
        ""
      end

    ticks =
      Enum.map(times, fn t ->
        tx = x(sp, t)
        ahead = if t > now, do: " ahead", else: ""
        ~s(<line class="tick#{ahead}" x1="#{fx(tx)}" y1="6" x2="#{fx(tx)}" y2="18" style="#{delay(tx, 0.0, 0.45)}"/>)
      end)

    # Missed slots: the reported one and every later one whose grace has run out.
    {missed_marks, busy} =
      if missed != nil and missed <= to do
        slots = if dense, do: [], else: Enum.filter(times, &(&1 >= missed and &1 + grace < now))
        slots = if missed not in slots and missed >= from, do: [missed | slots], else: slots
        title = "#{name}: due #{when_utc(missed, now)} UTC, nothing started"
        title = if length(slots) > 1, do: title <> " (#{num(length(slots))} slots in this span)", else: title
        title = escape_html(title)

        if dense or length(slots) > @max_boxes do
          x1 = x(sp, max(missed, from))
          x2 = max(x(sp, now), x1 + @min_box)

          {[
             ~s(<rect class="missed" x="#{fx(x1)}" y="5" width="#{fx(x2 - x1)}" height="14" style="#{delay(x1, 80.0, 0.75)}"><title>#{title}</title></rect>)
           ], [{x1, x2}]}
        else
          slots
          |> Enum.filter(&(&1 >= from))
          |> Enum.map(fn t ->
            x1 = x(sp, t)
            width = max(x(sp, t + grace) - x1, @min_box)

            {~s(<rect class="missed" x="#{fx(x1)}" y="5" width="#{fx(width)}" height="14" style="#{delay(x1, 80.0, 0.75)}"><title>#{title}</title></rect>),
             {x1, x1 + width}}
          end)
          |> Enum.unzip()
        end
      else
        {[], []}
      end

    {run_marks, run_busy} =
      in_span
      |> Enum.map(fn run ->
        tone = tone_of(run, job, now)
        # A zero-width rect is not drawn at all; its stroke gives short runs their width.
        x1 = x(sp, run.started_at)
        x2 = max(x(sp, finished_or(run, now)), x1 + 0.5)
        title = escape_html("#{name}: #{describe_run(run, tone, job, now)}")

        {~s(<rect class="run #{tone}" x="#{fx(x1)}" y="5" width="#{fx(x2 - x1)}" height="14" style="#{delay(x1, 80.0, 0.75)}"><title>#{title}</title></rect>),
         {x1, x2}}
      end)
      |> Enum.unzip()

    busy = busy ++ run_busy

    now_line =
      if ahead_now,
        do: ~s(<line class="nowline" x1="#{fx(x(sp, now))}" y1="0" x2="#{fx(x(sp, now))}" y2="24"/>),
        else: ""

    svg =
      IO.iodata_to_binary([
        ~s(<svg class="marks" viewBox="0 0 1000 24" preserveAspectRatio="none" aria-hidden="true" focusable="false">),
        head,
        ~s(<line class="base" x1="0" y1="12" x2="1000" y2="12"/>),
        unloaded,
        cadence,
        ticks,
        missed_marks,
        run_marks,
        now_line,
        "</svg>"
      ])

    # The note goes wherever the lane is actually empty, so it never sits on
    # the marks it describes; it is cut short with an ellipsis when narrow.
    text = lane_note(job, missed, now)
    note = if text == "", do: "", else: place_note(text, busy, x(sp, now))
    words = lane_words(job, in_span, times, dense, missed, now, text)
    {svg, note, words}
  end

  defp place_note(text, busy, now_x) do
    {lo, hi} =
      case busy do
        [] -> {now_x, now_x}
        _ -> Enum.reduce(busy, {:infinity, :neg_infinity}, fn {a, b}, {lo, hi} -> {min_f(lo, a), max_f(hi, b)} end)
      end

    right = @lane_width - hi >= lo
    room = if right, do: @lane_width - hi, else: lo

    cond do
      room <= 90.0 ->
        ""

      right ->
        ~s(<span class="note" style="left:#{fx((hi + 14.0) / 10.0)}%;max-width:#{fx((room - 18.0) / 10.0)}%">#{escape_html(text)}</span>)

      true ->
        ~s(<span class="note before" style="right:#{fx(100.0 - (lo - 14.0) / 10.0)}%;max-width:#{fx((room - 18.0) / 10.0)}%">#{escape_html(text)}</span>)
    end
  end

  defp min_f(:infinity, b), do: b
  defp min_f(a, b), do: min(a, b)
  defp max_f(:neg_infinity, b), do: b
  defp max_f(a, b), do: max(a, b)

  # `${definition.schedule ?? fallback}`.
  defp schedule_text(job, fallback) do
    case Object.get(job.definition, "schedule") do
      nil -> fallback
      v -> Format.js_text(v)
    end
  end

  # The lane in words, for anyone who cannot see it.
  defp lane_words(job, runs, times, dense, missed, now, note) do
    sched = Object.fetch(job.definition, "schedule")

    due =
      cond do
        dense ->
          case sched do
            {:ok, v} -> ["due #{Format.js_text(v)}"]
            :error -> ["due undefined"]
          end

        match?({:ok, _}, sched) and Format.truthy?(elem(sched, 1)) ->
          case Enum.count(times, &(&1 <= now)) do
            0 -> ["due no times so far"]
            1 -> ["due once so far"]
            n -> ["due #{num(n)} times so far"]
          end

        true ->
          []
      end

    ok = Enum.count(runs, &(&1.status == "ok"))
    total = length(runs)
    recorded = if total == 1, do: "1 run recorded", else: "#{num(total)} runs recorded"

    recorded =
      cond do
        total == 0 -> recorded
        ok == total and ok == 1 -> recorded <> ", ok"
        ok == total -> recorded <> ", all ok"
        ok > 0 -> recorded <> ", #{num(ok)} ok"
        true -> recorded
      end

    bad =
      runs
      |> Enum.filter(&(&1.status in ["failed", "timeout"]))
      |> Enum.take(-5)
      |> Enum.map(fn r ->
        "#{r.status} at #{when_utc(r.started_at, now)} UTC after #{Duration.format(r.duration_ms || 0)}"
      end)

    missed_words = if missed, do: ["due at #{when_utc(missed, now)} UTC and nothing started"], else: []

    note_words =
      if note != "" and not String.starts_with?(note, ["due ", "failed at", "timed out"]), do: [note], else: []

    Enum.join(due ++ [recorded] ++ bad ++ missed_words ++ note_words, "; ")
  end

  # The grid lines and hour labels every step, on UTC boundaries.
  defp hour_grid({from, to, now}, step, now_label) do
    xg = fn t -> (t - from) / (to - from) * @lane_width end
    now_x = xg.(now)
    first = -JS.floor_div(-from, step) * step

    {lines, labels} =
      first
      |> Stream.iterate(&(&1 + step))
      |> Enum.take_while(&(&1 <= to))
      |> Enum.reduce({[], []}, fn t, {lines, labels} ->
        gx = xg.(t)
        lines = [~s(<i class="gl" style="left:#{fx(gx / 10.0)}%"></i>) | lines]
        near_now = now_label and abs(gx - now_x) < 70.0

        labels =
          if gx >= 25.0 and gx <= @lane_width - 25.0 and not near_now do
            minor = if rem(JS.round(t / @hour_ms), 6) != 0, do: ["minor"], else: []
            # On a phone the track is too narrow for a label this close to "now"; CSS hides it there.
            near = if now_label and abs(gx - now_x) < 170.0, do: ["near"], else: []
            cls = Enum.join(minor ++ near, " ")
            [~s(<span class="#{cls}" style="left:#{fx(gx / 10.0)}%">#{clock_utc(t)}</span>) | labels]
          else
            labels
          end

        {lines, labels}
      end)

    labels =
      if now_label and now >= from and now <= to,
        do: [~s(<span class="nowlabel" style="left:#{fx(now_x / 10.0)}%">now #{clock_utc(now)}</span>) | labels],
        else: labels

    {lines |> Enum.reverse() |> IO.iodata_to_binary(), labels |> Enum.reverse() |> IO.iodata_to_binary()}
  end

  # The key under a timeline: a small sample of each mark and what it means.
  defp timeline_legend do
    key = fn inner -> ~s(<svg class="key" viewBox="0 0 16 12" aria-hidden="true" focusable="false">#{inner}</svg>) end
    boxed = fn cls -> key.(~s(<rect class="#{cls}" x="2" y="1" width="12" height="10"/>)) end

    items = [
      {key.(~s(<line class="tick" x1="8" y1="1" x2="8" y2="11"/>)), "due"},
      {boxed.("run ok"), "ran"},
      {boxed.("run bad"), "failed"},
      {boxed.("run timeout"), "timed out"},
      {boxed.("run warn"), "over budget or slow"},
      {boxed.("run running"), "running"},
      {boxed.("missed"), "missed"}
    ]

    ~s(<p class="legend" aria-hidden="true">) <>
      Enum.map_join(items, fn {sample, label} -> "<span>#{sample}#{label}</span>" end) <> "</p>"
  end

  defp state_class(%{health: "healthy"}), do: "ok"
  defp state_class(%{health: "late"}), do: "warn"
  defp state_class(%{health: h}) when h in ["failing", "stuck"], do: "bad"
  defp state_class(_), do: "muted"

  @doc """
  The board's timeline: one lane per job across the span, with a shared now
  line and the first lanes only. `total` is how many jobs there are in all,
  for the note when some are left out.
  """
  def day_timeline(lanes, {from, to, now} = sp, base, total) do
    {lines, labels} = hour_grid(sp, 3 * @hour_ms, true)
    now_x = (now - from) / (to - from) * 100.0

    {rows, words} =
      lanes
      |> Enum.map(fn {job, runs, complete} ->
        {svg, note, said} = lane(job, runs, complete, sp, false, job.name)
        sched = schedule_text(job, "no schedule")

        row =
          [
            ~s(<li class="lane"><div class="who"><i class="sq ),
            state_class(job),
            ~s(" aria-hidden="true"></i><a class="name" href="),
            escape_html(base),
            "/jobs/",
            encode_uri_component(job.name),
            ~s(">),
            escape_name(job.name),
            ~s(</a><span class="sched">),
            escape_html(sched),
            ~s(</span></div><div class="track">),
            svg,
            note,
            "</div></li>"
          ]

        {row, "<li>#{escape_html("#{job.name} (#{sched}): #{said}.")}</li>"}
      end)
      |> Enum.unzip()

    more =
      if total > length(lanes),
        do:
          ~s(<p class="more">Showing the first #{num(length(lanes))} of #{num(total)} jobs here; the table below lists them all.</p>),
        else: ""

    IO.iodata_to_binary([
      "<figure class=\"timeline day\">\n<div class=\"axis\" aria-hidden=\"true\"><span></span><div class=\"hours\">",
      labels,
      "</div></div>\n<div class=\"field\">\n<div class=\"under\" aria-hidden=\"true\"><span></span><div>",
      lines,
      "<i class=\"future\" style=\"left:",
      fx(now_x),
      "%\"></i></div></div>\n<ol class=\"lanes\">",
      rows,
      "</ol>\n<div class=\"over\" aria-hidden=\"true\"><span></span><div><i class=\"now\" style=\"left:",
      fx(now_x),
      "%\"></i></div></div>\n</div>\n",
      timeline_legend(),
      more,
      "\n<ul class=\"vh\">",
      words,
      "</ul>\n</figure>"
    ])
  end

  @doc """
  A job's page: its last seven UTC days, today first, one lane each.
  `complete` is false when the runs read do not reach back over the week.
  """
  def week_timeline(job, runs, complete, now) do
    today = JS.floor_div(now, @day_ms) * @day_ms
    oldest = if runs == [], do: nil, else: runs |> Enum.map(& &1.started_at) |> Enum.min()
    {lines, labels} = hour_grid({today, today + @day_ms, now}, 3 * @hour_ms, false)

    {rows, words} =
      0..(@week_days - 1)
      |> Enum.map(fn i ->
        from = today - i * @day_ms
        sp = {from, from + @day_ms, now}
        n = Enum.count(runs, &(&1.started_at < from + @day_ms and finished_or(&1, now) >= from))
        known = complete or (oldest != nil and oldest <= from)
        label = if i == 0, do: "today", else: day_label(from)
        {svg, note, said} = lane(job, runs, known, sp, i == 0, "#{job.name}, #{label}")
        count_text = if n == 1, do: "1 run", else: "#{num(n)} runs"

        {cls, name, note, said_label} =
          if i == 0 do
            dl = day_label(from)
            {" today", "Today, " <> binary_part(dl, 4, byte_size(dl) - 4), note, "Today"}
          else
            {"", day_label(from), "", day_label(from)}
          end

        {~s(<li class="lane#{cls}"><div class="who"><span class="name">#{escape_html(name)}</span><span class="sched">#{escape_html(count_text)}</span></div><div class="track">#{svg}#{note}</div></li>),
         "<li>#{escape_html("#{said_label}: #{said}.")}</li>"}
      end)
      |> Enum.unzip()

    IO.iodata_to_binary([
      "<figure class=\"timeline week\">\n<div class=\"axis\" aria-hidden=\"true\"><span></span><div class=\"hours\">",
      labels,
      "</div></div>\n<div class=\"field\">\n<div class=\"under\" aria-hidden=\"true\"><span></span><div>",
      lines,
      "</div></div>\n<ol class=\"lanes\">",
      rows,
      "</ol>\n</div>\n",
      timeline_legend(),
      "\n<ul class=\"vh\">",
      words,
      "</ul>\n</figure>"
    ])
  end

  @doc """
  How many runs a job's page reads so its week is drawn in full: roughly how
  often the schedule was due over the week, with room to spare, from 50
  (what the run list shows) to 500 (the most `runs` returns).
  """
  def week_runs_limit(job, now) do
    case lane_schedule(job) do
      nil ->
        50

      parsed ->
        from = JS.floor_div(now, @day_ms) * @day_ms - (@week_days - 1) * @day_ms
        width = now + @day_ms - from

        expected =
          if parsed.kind == "interval" do
            width / parsed.every_ms
          else
            # A cron's fires over one day, times the week: close enough, and cheap.
            case due_times(job, parsed, [], now - @day_ms, now) do
              {_, true} -> :infinity
              {times, false} -> length(times) * width / @day_ms
            end
          end

        case expected do
          :infinity -> 500
          e -> (Float.ceil(e * 1.2) + 10) |> max(50.0) |> min(500.0) |> trunc()
        end
    end
  end
end
