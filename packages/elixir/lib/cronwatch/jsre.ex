defmodule Cronwatch.JSRE do
  @moduledoc false
  # Internal: not the package's API, and it can change in any release.
  #
  # A small backtracking regular expression engine with JavaScript's semantics,
  # for the SDK's secret redaction patterns and a job's stored
  # `matches /source/flags` expect rule.
  #
  # Elixir's `Regex` cannot run them the same way: it is PCRE, which counts in
  # bytes or code points, reads `$` as matching before a final newline, has its
  # own `\\s` and `\\b`, and moved from PCRE to PCRE2 with OTP 28. This engine
  # matches over UTF-16 code units, as V8 does without the `u` flag, so an emoji
  # counts as two characters to a bounded quantifier and to a negated class,
  # and the SDK's patterns are written here verbatim. It is the Go port's
  # `internal/jsre`, as carried over and hardened by the Rust port.
  #
  # It reads the subset of JavaScript's syntax those patterns use, in
  # non-unicode mode: literals and escapes (`\\d \\s \\w \\b` and their
  # negations, `\\n \\t \\r \\f \\v \\0 \\xHH \\uHHHH`, and any escaped
  # punctuation), character classes with ranges and negation, capturing and
  # non-capturing groups, lookahead, fixed-length lookbehind, alternation,
  # greedy quantifiers (`? * + {n} {n,} {n,m}`), and the flags `g` and `i` (which
  # folds ASCII letters only, as JavaScript's `/i` without `u` does for
  # patterns whose letters are ASCII). What it does not implement it refuses
  # rather than read as something else: lazy quantifiers, named groups,
  # backreferences, `\\c`, `\\p{...}` and `\\u{...}`.
  #
  # The bounds are the Rust port's: a pattern longer than 4096 characters, or
  # with groups nested more than 100 deep, is not read; and a match gives up
  # past 512 frames of recursion. A budgeted match (`try_match?/2`) gives up
  # past #{10_000_000} steps (each attempt at a node, and each code unit
  # a repeat scans), a fifth of the Rust port's budget, since a step costs the
  # BEAM far more.

  import Bitwise

  alias Cronwatch.JS
  alias Cronwatch.JSRE.Match
  alias Cronwatch.JSRE.Parse

  defstruct [:source, :flags, :global, :nodes, :sets, :start, :captures, :loops, :first]

  @type t :: %__MODULE__{
          source: String.t(),
          flags: String.t(),
          global: boolean(),
          nodes: tuple(),
          sets: tuple(),
          start: non_neg_integer(),
          captures: non_neg_integer(),
          loops: non_neg_integer(),
          first: tuple() | nil
        }

  # The longest pattern read, in characters.
  @max_source 4096

  @doc false
  def max_source, do: @max_source

  @doc """
  Reads a JavaScript pattern's source (what goes between the slashes) and its
  flags (`g` and `i`).
  """
  @spec compile(String.t(), String.t()) :: {:ok, t()} | {:error, String.t()}
  def compile(source, flags \\ "") when is_binary(source) and is_binary(flags) do
    with :ok <- check_length(source),
         {:ok, fold, global} <- read_flags(flags),
         {:ok, tree, captures} <- Parse.parse(JS.scrub(source), fold) do
      c = %{nodes: %{}, count: 0, loops: 0, err: nil, source: source}
      {accept, c} = push(c, mk_node(:accept))
      {start, c} = compile_tree(tree, accept, c)
      {c, _seen} = guard(c, start, MapSet.new())

      case c.err do
        nil ->
          {nodes, sets} = intern(for i <- 0..(c.count - 1), do: Map.fetch!(c.nodes, i))

          first =
            case first(tree, 0) do
              {true, _} -> nil
              {false, set} -> set |> Parse.frozen() |> elem(1)
            end

          {:ok,
           %__MODULE__{
             source: source,
             flags: flags,
             global: global,
             nodes: nodes,
             sets: sets,
             start: start,
             captures: captures,
             loops: c.loops,
             first: first
           }}

        err ->
          {:error, err}
      end
    end
  end

  @doc "`compile/2` for patterns known to be good; raises `ArgumentError` otherwise."
  @spec compile!(String.t(), String.t()) :: t()
  def compile!(source, flags \\ "") do
    case compile(source, flags) do
      {:ok, re} -> re
      {:error, message} -> raise ArgumentError, message
    end
  end

  # Each character of a pattern is a set until it is frozen, so a pattern's
  # length bounds what compiling it takes.
  defp check_length(source) do
    if JS.scrub(source) |> String.to_charlist() |> length() > @max_source do
      {:error, "jsre: a pattern of more than #{@max_source} characters is not supported"}
    else
      :ok
    end
  end

  defp read_flags(flags) do
    flags
    |> String.to_charlist()
    |> Enum.reduce_while({:ok, false, false}, fn
      ?i, {:ok, _fold, global} -> {:cont, {:ok, true, global}}
      ?g, {:ok, fold, _global} -> {:cont, {:ok, fold, true}}
      f, _ -> {:halt, {:error, "jsre: flag #{inspect(<<f::utf8>>)} is not supported"}}
    end)
  end

  @doc "The pattern as JavaScript writes a RegExp: `/source/flags`."
  @spec source(t()) :: String.t()
  def source(%__MODULE__{source: source, flags: flags}), do: "/#{source}/#{flags}"

  @doc """
  Whether the pattern matches anywhere in the text, with no step budget: for
  the SDK's own bounded patterns. A match that goes past 512 frames does not
  match.
  """
  @spec match?(t(), String.t()) :: boolean()
  def match?(%__MODULE__{} = re, text) do
    case Match.find(re, JS.units(text), 0, :unbounded) do
      {:match, _caps, _steps} -> true
      _ -> false
    end
  end

  @doc """
  Whether the pattern matches anywhere in the text within the step budget, or
  `:gave_up` when the match ran out of steps or frames: for a stored expect
  pattern, which an app wrote and a long output can make backtrack.
  """
  @spec try_match?(t(), String.t()) :: {:ok, boolean()} | :gave_up
  def try_match?(%__MODULE__{} = re, text) do
    case Match.find(re, JS.units(text), 0, Match.max_steps()) do
      {:match, _caps, _steps} -> {:ok, true}
      {:none, _steps} -> {:ok, false}
      :gave_up -> :gave_up
    end
  end

  @doc """
  `String.prototype.replace` with a function over UTF-16 code units (a
  big-endian binary, as `Cronwatch.JS.units/1` gives): each match (every one
  with the `g` flag, else the first) is replaced by the code units the
  function returns for it, and the search goes on after it (one unit further
  after an empty match). A match that gives up leaves the rest as it was.
  The function is given a `Cronwatch.JSRE.Match`.
  """
  @spec replace_units(t(), binary(), (Match.t() -> binary())) :: binary()
  def replace_units(%__MODULE__{} = re, input, fun) do
    {out, _gave_up} = Match.replace(re, input, :unbounded, fun)
    out
  end

  @doc """
  `replace_units/3` within the step budget: `{:ok, units}`, or `:gave_up`
  when a match ran out of its budget part way.
  """
  @spec try_replace_units(t(), binary(), (Match.t() -> binary())) :: {:ok, binary()} | :gave_up
  def try_replace_units(%__MODULE__{} = re, input, fun) do
    case Match.replace(re, input, Match.max_steps(), fun) do
      {out, false} -> {:ok, out}
      {_out, true} -> :gave_up
    end
  end

  @doc """
  `replace` with a replacement string, on text: `$1` to `$99` are the groups
  (`""` for one that did not take part), `$&` the match, `$$` a `$`.
  """
  @spec replace(t(), String.t(), String.t()) :: String.t()
  def replace(%__MODULE__{} = re, text, template) do
    re
    |> replace_units(JS.units(text), fn m -> JS.units(expand(template, m)) end)
    |> JS.from_units()
  end

  defp expand(template, m), do: template |> expand(m, []) |> IO.iodata_to_binary()

  defp expand(<<?$, ?$, rest::binary>>, m, acc), do: expand(rest, m, ["$" | acc])
  defp expand(<<?$, ?&, rest::binary>>, m, acc), do: expand(rest, m, [Match.text(m, 0) | acc])

  defp expand(<<?$, d, rest::binary>> = all, m, acc) when d in ?0..?9 do
    groups = m.groups
    one = d - ?0

    {group, rest} =
      case rest do
        <<d2, rest2::binary>> when d2 in ?0..?9 and one * 10 + d2 - ?0 >= 1 and one * 10 + d2 - ?0 <= groups ->
          {one * 10 + d2 - ?0, rest2}

        _ ->
          {one, rest}
      end

    if group < 1 or group > groups do
      <<c, rest::binary>> = all
      expand(rest, m, [<<c>> | acc])
    else
      expand(rest, m, [Match.text(m, group) | acc])
    end
  end

  defp expand(<<c, rest::binary>>, m, acc), do: expand(rest, m, [<<c>> | acc])
  defp expand(<<>>, _m, acc), do: Enum.reverse(acc)

  ## The compiler

  # One step of the compiled pattern. Each node knows the step after it
  # (`next`), so the matcher runs a pattern as a chain and backtracks by
  # returning up the call stack. Nodes refer to each other by index.
  defp mk_node(op, fields \\ []) do
    Map.merge(
      %{
        op: op,
        set: nil,
        set_int: 0,
        min: 1,
        max: 1,
        next: nil,
        alts: [],
        body: nil,
        index: 0,
        negate: false,
        width: 0,
        lp: nil,
        guard: nil,
        keep: false
      },
      Map.new(fields)
    )
  end

  defp push(c, n), do: {c.count, %{c | nodes: Map.put(c.nodes, c.count, n), count: c.count + 1}}

  defp char_fields(%{set: {int, bin}}), do: [set: bin, set_int: int]

  # Builds the chain for `t`, which continues with `cont`.
  defp compile_tree(t, cont, c) do
    cond do
      Parse.once?(t) ->
        once(t, cont, c)

      t.kind == :char ->
        push(c, mk_node(:rep, char_fields(t) ++ [min: t.min, max: t.max, next: cont]))

      width(hd(t.children)) == {1, 1} and not capture?(t) and t.kind == :group and t.capture == 0 ->
        # Every pass takes exactly one code unit, so the passes are counted
        # greedily and walked back, rather than taking one call per pass: a
        # {0,16384} run stays shallow.
        {accept, c} = push(c, mk_node(:accept))
        {body, c} = compile_tree(hd(t.children), accept, c)
        push(c, mk_node(:pred_rep, body: body, min: t.min, max: t.max, next: cont))

      true ->
        {lp, c} = push(c, mk_node(:loop, min: t.min, max: t.max, next: cont, index: c.loops))
        c = %{c | loops: c.loops + 1}
        {back, c} = push(c, mk_node(:loop_back, lp: lp))
        {body, c} = once(%{t | min: 1, max: 1}, back, c)
        {lp, %{c | nodes: Map.update!(c.nodes, lp, &%{&1 | body: body})}}
    end
  end

  # Builds the chain for one pass of `t`.
  defp once(%{kind: :seq, children: children}, cont, c) do
    children |> Enum.reverse() |> Enum.reduce({cont, c}, fn child, {cont, c} -> compile_tree(child, cont, c) end)
  end

  defp once(%{kind: :alt, children: children}, cont, c) do
    {alts, c} =
      Enum.reduce(children, {[], c}, fn child, {acc, c} ->
        {n, c} = compile_tree(child, cont, c)
        {[n | acc], c}
      end)

    push(c, mk_node(:alt, alts: Enum.reverse(alts)))
  end

  defp once(%{kind: :char} = t, cont, c), do: push(c, mk_node(:rep, char_fields(t) ++ [next: cont]))

  defp once(%{kind: :group, capture: 0, children: [inner]}, cont, c), do: compile_tree(inner, cont, c)

  defp once(%{kind: :group, capture: capture, children: [inner]}, cont, c) do
    {close, c} = push(c, mk_node(:cap_close, index: capture, next: cont))
    {next, c} = compile_tree(inner, close, c)
    push(c, mk_node(:cap_open, index: capture, next: next))
  end

  defp once(%{kind: :look, behind: true, children: [inner]} = t, cont, c) do
    keep = capture?(t)

    c =
      case width(inner) do
        {lo, lo} -> c
        _ -> %{c | err: "jsre: a lookbehind must have one width, in /#{c.source}/"}
      end

    {lo, _} = width(inner)
    {at, c} = push(c, mk_node(:accept_at))
    {body, c} = compile_tree(inner, at, c)
    push(c, mk_node(:behind, keep: keep, negate: t.negate, width: lo, body: body, next: cont))
  end

  defp once(%{kind: :look, children: [inner]} = t, cont, c) do
    keep = capture?(t)
    {accept, c} = push(c, mk_node(:accept))
    {body, c} = compile_tree(inner, accept, c)
    push(c, mk_node(:look, keep: keep, negate: t.negate, body: body, next: cont))
  end

  defp once(%{kind: kind}, cont, c) when kind in [:word_b, :not_word_b, :start, :end] do
    push(c, mk_node(kind, next: cont))
  end

  # The nodes with each set (a repeat's own and its guard) as an index into
  # one tuple of the distinct sets, so a pattern that names one set many
  # times holds it once, however often the pattern is copied between
  # processes or into a table (a copy does not keep terms shared). A set's
  # integer is for compiling only, 65,536 bits a node, and is dropped.
  defp intern(nodes) do
    {nodes, {_index, sets}} =
      Enum.map_reduce(nodes, {%{}, []}, fn node, acc ->
        {set, acc} = index_of(node.set, acc)
        {guard, acc} = index_of(node.guard, acc)
        {%{node | set: set, guard: guard, set_int: 0}, acc}
      end)

    {List.to_tuple(nodes), sets |> Enum.reverse() |> List.to_tuple()}
  end

  defp index_of(nil, acc), do: {nil, acc}

  defp index_of(set, {index, sets} = acc) do
    case index do
      %{^set => i} -> {i, acc}
      _ -> {map_size(index), {Map.put(index, set, map_size(index)), [set | sets]}}
    end
  end

  # Sets each repeat's guard, visiting every node once.
  defp guard(c, nil, seen), do: {c, seen}

  defp guard(c, n, seen) do
    if MapSet.member?(seen, n) do
      {c, seen}
    else
      seen = MapSet.put(seen, n)
      nd = Map.fetch!(c.nodes, n)

      c =
        if nd.op in [:rep, :pred_rep] do
          guard_set =
            case start_set(c, nd.next, 0) do
              nil -> nil
              int -> int |> Parse.frozen() |> elem(1)
            end

          %{c | nodes: Map.put(c.nodes, n, %{nd | guard: guard_set})}
        else
          c
        end

      {c, seen} = guard(c, nd.next, seen)
      {c, seen} = guard(c, nd.body, seen)
      Enum.reduce(nd.alts, {c, seen}, fn a, {c, seen} -> guard(c, a, seen) end)
    end
  end

  # The code units a match from `n` must start with, as an integer bitmap, or
  # nil when it may start with anything or take nothing.
  defp start_set(_c, nil, _depth), do: nil
  defp start_set(_c, _n, depth) when depth > 16, do: nil

  defp start_set(c, n, depth) do
    nd = Map.fetch!(c.nodes, n)

    case nd.op do
      :rep when nd.min >= 1 ->
        nd.set_int

      :alt ->
        Enum.reduce_while(nd.alts, 0, fn a, acc ->
          case start_set(c, a, depth + 1) do
            nil -> {:halt, nil}
            s -> {:cont, acc ||| s}
          end
        end)

      op when op in [:cap_open, :cap_close, :look, :behind, :word_b, :not_word_b] ->
        start_set(c, nd.next, depth + 1)

      _ ->
        nil
    end
  end

  # The least and most code units `t` can take (nil: no limit).
  defp width(t) do
    {lo, hi} =
      case t.kind do
        :char ->
          {1, 1}

        :seq ->
          Enum.reduce(t.children, {0, 0}, fn child, {lo, hi} ->
            {l, h} = width(child)
            {lo + l, if(hi == nil or h == nil, do: nil, else: hi + h)}
          end)

        :alt ->
          {lo, hi} =
            Enum.reduce(t.children, {nil, 0}, fn child, {lo, hi} ->
              {l, h} = width(child)
              {if(lo == nil or l < lo, do: l, else: lo), if(hi == nil or h == nil, do: nil, else: max(hi, h))}
            end)

          {lo || 0, hi}

        :group ->
          width(hd(t.children))

        # Assertions and lookarounds take nothing.
        _ ->
          :none
      end
      |> case do
        :none -> {0, 0}
        w -> w
      end

    if t.kind in [:char, :seq, :alt, :group] do
      lo = lo * t.min

      hi =
        case {t.max, hi} do
          {nil, 0} -> 0
          {nil, _} -> nil
          {m, h} when is_integer(h) -> h * m
          {_, nil} -> nil
        end

      {lo, hi}
    else
      {0, 0}
    end
  end

  defp capture?(t), do: (t.kind == :group and t.capture > 0) or Enum.any?(t.children, &capture?/1)

  # Adds to the set what `t` can start with, and says whether `t` can match
  # without taking anything (so what follows it can start the match too).
  defp first(%{kind: :char, set: {int, _}} = t, set), do: {t.min == 0, set ||| int}

  defp first(%{kind: :seq, children: children} = t, set) do
    {nullable, set} =
      Enum.reduce_while(children, {true, set}, fn child, {_, set} ->
        case first(child, set) do
          {true, set} -> {:cont, {true, set}}
          {false, set} -> {:halt, {false, set}}
        end
      end)

    {nullable or t.min == 0, set}
  end

  defp first(%{kind: :alt, children: children} = t, set) do
    {nullable, set} =
      Enum.reduce(children, {false, set}, fn child, {nullable, set} ->
        {n, set} = first(child, set)
        {nullable or n, set}
      end)

    {nullable or t.min == 0, set}
  end

  defp first(%{kind: :group, children: [inner]} = t, set) do
    {nullable, set} = first(inner, set)
    {nullable or t.min == 0, set}
  end

  defp first(_t, set), do: {true, set}
end
