defmodule Cronwatch.JSRE.Match do
  @moduledoc """
  One match of a `Cronwatch.JSRE` pattern, as a replacement function is given
  it: the code units of the whole match and each group.

  The rest of this module is the matcher: it runs a compiled pattern as a
  chain of nodes over UTF-16 code units, backtracking by returning up the
  call stack. The captures, the loops' counts and where the match ended are
  a state each step hands on only when it matches, so a failed branch leaves
  nothing behind; the steps left are handed back either way, since the
  budget counts the work of every branch.
  """

  import Bitwise

  alias Cronwatch.JS

  defstruct [:input, :caps, :groups]

  @type t :: %__MODULE__{input: binary(), caps: tuple(), groups: non_neg_integer()}

  # How deep one match may recurse. A loop whose passes are not one code unit
  # wide (`(?:ab)*`) recurses a few frames a pass; past this (some 170 such
  # passes) the match gives up. The BEAM would not crash where Rust's stack
  # did, but the cap is kept so every bounded port gives the same answers.
  @max_depth 512

  # How much work a budgeted match does before it gives up: each attempt at a
  # node is a step, and so is each code unit a repeat scans. See
  # DESIGN.md's Decisions for the measurement behind the number.
  @max_steps 50_000_000

  # An unbudgeted match's steps: more than any match could take.
  @unbounded 1 <<< 58

  @doc false
  def max_steps, do: @max_steps

  @doc "Group `i`'s code units (0 is the whole match), or nil when it did not take part."
  @spec group(t(), non_neg_integer()) :: binary() | nil
  def group(%__MODULE__{input: input, caps: caps}, i) do
    if 2 * i + 1 >= tuple_size(caps) do
      nil
    else
      {s, e} = {elem(caps, 2 * i), elem(caps, 2 * i + 1)}
      if s < 0 or e < 0, do: nil, else: binary_part(input, s * 2, (e - s) * 2)
    end
  end

  @doc "Group `i` as text, `\"\"` when it did not take part."
  @spec text(t(), non_neg_integer()) :: String.t()
  def text(m, i), do: JS.from_units(group(m, i) || "")

  ## The matcher

  @doc false
  # The first match starting at or after `from`: `{:match, caps, steps}`,
  # `{:none, steps}`, or `:gave_up` past the depth or the steps.
  def find(re, input, from, budget) do
    steps = if budget == :unbounded, do: @unbounded, else: budget
    e = env(re, input)
    exec(e, from, steps)
  catch
    :jsre_gave_up -> :gave_up
  end

  @doc false
  # The replacement, and whether a match gave up part way (what follows it is
  # then left as it was).
  def replace(re, input, budget, fun) do
    steps = if budget == :unbounded, do: @unbounded, else: budget
    e = env(re, input)
    replace_loop(e, fun, 0, 0, steps, [], false)
  end

  defp replace_loop(e, fun, last, pos, steps, acc, replaced) do
    found =
      if pos <= e.len do
        try do
          exec(e, pos, steps)
        catch
          :jsre_gave_up -> :gave_up
        end
      else
        {:none, steps}
      end

    case found do
      {:match, caps, steps} ->
        {s, en} = {elem(caps, 0), elem(caps, 1)}
        piece = fun.(%__MODULE__{input: e.input, caps: caps, groups: e.re.captures})
        acc = [piece, slice(e.input, last, s) | acc]
        next = if en == s, do: en + 1, else: en

        if e.re.global do
          replace_loop(e, fun, en, next, steps, acc, true)
        else
          {finish(e, en, acc), false}
        end

      {:none, _steps} ->
        if replaced, do: {finish(e, last, acc), false}, else: {e.input, false}

      :gave_up ->
        if replaced, do: {finish(e, last, acc), true}, else: {e.input, true}
    end
  end

  defp finish(e, last, acc), do: IO.iodata_to_binary(Enum.reverse([slice(e.input, last, e.len) | acc]))

  defp slice(input, from, to), do: binary_part(input, from * 2, (to - from) * 2)

  defp env(re, input) do
    %{re: re, nodes: re.nodes, input: input, len: div(byte_size(input), 2), ncaps: 2 * (re.captures + 1)}
  end

  defp exec(e, s, steps) when s > e.len, do: {:none, steps}

  defp exec(e, s, steps) do
    first = e.re.first

    cond do
      first != nil and s == e.len ->
        {:none, steps}

      first != nil and not has?(first, unit(e.input, s)) ->
        exec(e, s + 1, steps)

      true ->
        st = {Tuple.duplicate(-1, e.ncaps), Tuple.duplicate({0, 0}, e.re.loops), -1, 0}

        case run(e, e.re.start, s, st, 0, steps) do
          {:ok, {caps, _loops, en, _target}, steps} ->
            {:match, caps |> put_elem(0, s) |> put_elem(1, en), steps}

          {:fail, steps} ->
            exec(e, s + 1, steps)
        end
    end
  end

  defp unit(input, i) do
    <<u::16>> = binary_part(input, i * 2, 2)
    u
  end

  defp has?(set, c) do
    (elem(set, c >>> 5) >>> (c &&& 31) &&& 1) == 1
  end

  defp word?(c), do: c in ?a..?z or c in ?A..?Z or c in ?0..?9 or c == ?_

  defp word_at?(e, i), do: i >= 0 and i < e.len and word?(unit(e.input, i))

  defp guarded?(e, %{guard: g}, at), do: g == nil or (at < e.len and has?(g, unit(e.input, at)))

  # Whether the chain from `n` matches at `pos`: `{:ok, state, steps}` with
  # the captures and the end set, or `{:fail, steps}`. Past the depth or out
  # of steps the match gives up, by a throw the caller catches.
  defp run(_e, _n, _pos, _st, depth, steps) when depth >= @max_depth or steps <= 0, do: throw(:jsre_gave_up)
  defp run(e, n, pos, st, depth, steps), do: chain(e, n, pos, st, depth + 1, steps - 1)

  defp chain(e, n, pos, st, d, steps) do
    node = elem(e.nodes, n)

    case node.op do
      :rep ->
        limit = limit(e, node, pos)
        rest = binary_part(e.input, pos * 2, limit * 2)
        k = scan(rest, node.set, 0)
        steps = max(steps - k, 0)

        cond do
          k < node.min -> {:fail, steps}
          k == node.min -> chain(e, node.next, pos + k, st, d, steps)
          true -> walk_back(e, node, pos, k, st, d, steps)
        end

      :pred_rep ->
        limit = limit(e, node, pos)
        {k, steps} = pred_count(e, node, pos, 0, limit, st, d, steps)

        if k < node.min, do: {:fail, steps}, else: walk_back(e, node, pos, k, st, d, steps)

      :alt ->
        try_alts(e, node.alts, pos, st, d, steps)

      :cap_open ->
        {caps, loops, en, target} = st
        run(e, node.next, pos, {put_elem(caps, 2 * node.index, pos), loops, en, target}, d, steps)

      :cap_close ->
        {caps, loops, en, target} = st
        run(e, node.next, pos, {put_elem(caps, 2 * node.index + 1, pos), loops, en, target}, d, steps)

      :loop ->
        iterate(e, n, 0, pos, st, d, steps)

      :loop_back ->
        lp = elem(e.nodes, node.lp)
        {_caps, loops, _en, _target} = st
        {count, start} = elem(loops, lp.index)

        # A pass that took nothing ends the loop without matching, as
        # JavaScript's RepeatMatcher refuses an empty iteration.
        if pos == start, do: {:fail, steps}, else: iterate(e, node.lp, count, pos, st, d, steps)

      :look ->
        {ok, body_st, steps} =
          case run(e, node.body, pos, st, d, steps) do
            {:ok, body_st, steps} -> {true, body_st, steps}
            {:fail, steps} -> {false, nil, steps}
          end

        if ok == node.negate do
          {:fail, steps}
        else
          chain(e, node.next, pos, keep_caps(st, body_st, ok and not node.negate), d, steps)
        end

      :behind ->
        {ok, body_st, steps} =
          if pos >= node.width do
            {caps, loops, en, _target} = st

            case run(e, node.body, pos - node.width, {caps, loops, en, pos}, d, steps) do
              {:ok, body_st, steps} -> {true, body_st, steps}
              {:fail, steps} -> {false, nil, steps}
            end
          else
            {false, nil, steps}
          end

        if ok == node.negate do
          {:fail, steps}
        else
          chain(e, node.next, pos, keep_caps(st, body_st, ok and not node.negate), d, steps)
        end

      op when op in [:word_b, :not_word_b] ->
        at = word_at?(e, pos - 1) != word_at?(e, pos)
        if at != (op == :word_b), do: {:fail, steps}, else: chain(e, node.next, pos, st, d, steps)

      :start ->
        if pos != 0, do: {:fail, steps}, else: chain(e, node.next, pos, st, d, steps)

      :end ->
        if pos != e.len, do: {:fail, steps}, else: chain(e, node.next, pos, st, d, steps)

      :accept ->
        {caps, loops, _en, target} = st
        {:ok, {caps, loops, pos, target}, steps}

      :accept_at ->
        {_caps, _loops, _en, target} = st
        if pos == target, do: {:ok, st, steps}, else: {:fail, steps}
    end
  end

  # A lookaround that matched keeps what its body captured; the end and the
  # lookbehind's target stay the caller's.
  defp keep_caps(st, _body_st, false), do: st
  defp keep_caps({_caps, loops, en, target}, {caps, _, _, _}, true), do: {caps, loops, en, target}

  defp limit(e, node, pos) do
    limit = e.len - pos
    if node.max == nil, do: limit, else: min(limit, node.max)
  end

  defp scan(<<u::16, rest::binary>>, set, k) do
    if has?(set, u), do: scan(rest, set, k + 1), else: k
  end

  defp scan(<<>>, _set, k), do: k

  defp pred_count(e, node, pos, k, limit, st, d, steps) when k < limit do
    case run(e, node.body, pos + k, st, d, steps) do
      {:ok, {_, _, en, _}, steps} when en == pos + k + 1 -> pred_count(e, node, pos, k + 1, limit, st, d, steps)
      {:ok, _, steps} -> {k, steps}
      {:fail, steps} -> {k, steps}
    end
  end

  defp pred_count(_e, _node, _pos, k, _limit, _st, _d, steps), do: {k, steps}

  # Walks a greedy run back from `i` units to its minimum, trying the rest of
  # the pattern after each.
  defp walk_back(e, node, pos, i, st, d, steps) do
    result =
      if guarded?(e, node, pos + i), do: run(e, node.next, pos + i, st, d, steps), else: {:fail, steps}

    case result do
      {:ok, _, _} = ok -> ok
      {:fail, steps} when i == node.min -> {:fail, steps}
      {:fail, steps} -> walk_back(e, node, pos, i - 1, st, d, steps)
    end
  end

  defp try_alts(e, [last], pos, st, d, steps), do: chain(e, last, pos, st, d, steps)

  defp try_alts(e, [a | rest], pos, st, d, steps) do
    case run(e, a, pos, st, d, steps) do
      {:ok, _, _} = ok -> ok
      {:fail, steps} -> try_alts(e, rest, pos, st, d, steps)
    end
  end

  # Tries one more pass of a loop that has made `count` passes, then (greedy)
  # leaving it.
  defp iterate(e, lp, count, pos, st, d, steps) do
    node = elem(e.nodes, lp)

    result =
      if node.max == nil or count < node.max do
        {caps, loops, en, target} = st
        run(e, node.body, pos, {caps, put_elem(loops, node.index, {count + 1, pos}), en, target}, d, steps)
      else
        {:fail, steps}
      end

    case result do
      {:ok, _, _} = ok -> ok
      {:fail, steps} when count >= node.min -> run(e, node.next, pos, st, d, steps)
      {:fail, steps} -> {:fail, steps}
    end
  end
end
