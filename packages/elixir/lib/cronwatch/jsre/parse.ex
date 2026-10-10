defmodule Cronwatch.JSRE.Parse do
  @moduledoc false
  # The parser: a pattern's source, in JavaScript's non-unicode syntax, as a
  # tree of maps. Kinds: :alt (children: the alternatives), :seq (the terms
  # in order), :char (one code unit from `set`), :group (children[0] inside;
  # a capture above 0 captures), :look (lookahead or lookbehind around
  # children[0]), :word_b, :not_word_b, :start and :end. `min` and `max` are
  # the quantifier; a `max` of nil is unbounded.
  #
  # A character set is built as an integer bitmap of every UTF-16 code unit
  # (bit c for unit c) with flags for JavaScript's `\s`, "everything but
  # `\s`", and negation, and frozen into a 65,536 bit binary once the tree node
  # is made, so a test at match time is one bit lookup.

  import Bitwise

  # How deep groups may nest.
  @max_nesting 100

  @full (1 <<< 65_536) - 1

  # JavaScript's `\s`: WhiteSpace and LineTerminator.
  @space_bits Enum.reduce(
                [9, 10, 11, 12, 13, 32, 0xA0, 0x1680, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000, 0xFEFF] ++
                  Enum.to_list(0x2000..0x200A),
                0,
                fn c, acc -> acc ||| 1 <<< c end
              )

  defp tree(kind, fields \\ []) do
    Map.merge(
      %{kind: kind, children: [], set: nil, capture: 0, behind: false, negate: false, min: 1, max: 1},
      Map.new(fields)
    )
  end

  defp char_tree(set), do: tree(:char, set: freeze(set))

  @doc false
  def once?(%{min: 1, max: 1}), do: true
  def once?(_), do: false

  @doc false
  # Reads a pattern's source into a tree and its number of captures.
  def parse(source, fold) do
    # Read as UTF-16 code units, as JavaScript reads a pattern without the
    # `u` flag: a character outside the BMP is its two halves in turn, each
    # an atom of its own, so a quantifier after it takes the second alone,
    # an escape before it escapes the first, and in a class `[a-😀]` is the
    # range a to the first half, then the second.
    src = for <<u::16 <- Cronwatch.JS.units(source)>>, into: [], do: u
    src = List.to_tuple(src)
    p = %{src: src, len: tuple_size(src), i: 0, fold: fold, captures: 0, depth: 0, source: source}

    try do
      {t, p} = disjunction(p)
      if p.i < p.len, do: throw({:jsre, fail(p, "unmatched ')'")})
      {:ok, t, p.captures}
    catch
      {:jsre, message} -> {:error, message}
    end
  end

  defp fail(p, what), do: "jsre: #{what} at #{p.i} in /#{p.source}/"
  defp raise_at(p, what), do: throw({:jsre, fail(p, what)})

  defp more?(p), do: p.i < p.len
  defp peek(p), do: elem(p.src, p.i)
  defp at(p, j), do: if(j < p.len, do: elem(p.src, j))
  defp adv(p, n \\ 1), do: %{p | i: p.i + n}

  defp has?(p, prefix) do
    prefix
    |> String.to_charlist()
    |> Enum.with_index()
    |> Enum.all?(fn {c, k} -> at(p, p.i + k) == c end)
  end

  defp disjunction(p), do: disjunction(p, [])

  defp disjunction(p, acc) do
    {seq, p} = alternative(p, [])

    if more?(p) and peek(p) == ?| do
      disjunction(adv(p), [seq | acc])
    else
      case Enum.reverse([seq | acc]) do
        [one] -> {one, p}
        alts -> {tree(:alt, children: alts), p}
      end
    end
  end

  defp alternative(p, acc) do
    if more?(p) and peek(p) not in [?|, ?)] do
      {t, p} = term(p)
      alternative(p, [t | acc])
    else
      {tree(:seq, children: Enum.reverse(acc)), p}
    end
  end

  defp term(p) do
    c = peek(p)

    case c do
      ?^ ->
        {tree(:start), adv(p)}

      ?$ ->
        {tree(:end), adv(p)}

      ?( ->
        group(adv(p))

      ?[ ->
        {set, p} = class(adv(p))
        quantifier(char_tree(set), p)

      ?. ->
        set = new_set() |> add_range(0, 0xFFFF) |> remove(?\n) |> remove(?\r) |> remove(0x2028) |> remove(0x2029)
        quantifier(char_tree(set), adv(p))

      ?\\ ->
        p = adv(p)
        if not more?(p), do: raise_at(p, "\\ at end of pattern")

        case peek(p) do
          ?b ->
            {tree(:word_b), adv(p)}

          ?B ->
            {tree(:not_word_b), adv(p)}

          _ ->
            {set, p} = escape(p, new_set())
            quantifier(char_tree(folded(p, set)), p)
        end

      c when c in [?*, ?+, ??] ->
        raise_at(p, "nothing to repeat")

      ?) ->
        raise_at(p, "unmatched ')'")

      c ->
        quantifier(char_tree(folded(p, add(new_set(), c))), adv(p))
    end
  end

  defp group(p) do
    {g, p} =
      cond do
        has?(p, "?:") ->
          {tree(:group), adv(p, 2)}

        has?(p, "?=") or has?(p, "?!") ->
          {tree(:look, negate: at(p, p.i + 1) == ?!), adv(p, 2)}

        has?(p, "?<=") or has?(p, "?<!") ->
          {tree(:look, behind: true, negate: at(p, p.i + 2) == ?!), adv(p, 3)}

        has?(p, "?") ->
          raise_at(p, "unsupported group")

        true ->
          p = %{p | captures: p.captures + 1}
          {tree(:group, capture: p.captures), p}
      end

    # The parser and the compiler recurse into groups.
    p = %{p | depth: p.depth + 1}
    if p.depth > @max_nesting, do: raise_at(p, "groups nested too deeply")
    {inner, p} = disjunction(p)
    p = %{p | depth: p.depth - 1}
    if not more?(p) or peek(p) != ?), do: raise_at(p, "missing ')'")
    p = adv(p)
    g = %{g | children: [inner]}

    if g.kind == :look and g.behind do
      # A lookbehind cannot be quantified.
      {g, p}
    else
      quantifier(g, p)
    end
  end

  # Reads {n}, {n,} or {n,m} at the parser's position: the bounds and the
  # index after the `}`, or nil when the `{` is a literal (Annex B).
  defp brace(p) do
    with {n, j} <- num(p, p.i + 1) do
      {m, j} =
        if at(p, j) == ?, do
          if at(p, j + 1) == ?} do
            {nil, j + 1}
          else
            case num(p, j + 1) do
              {m, j} -> {m, j}
              nil -> {:bad, j}
            end
          end
        else
          {n, j}
        end

      if m != :bad and at(p, j) == ?}, do: {n, m, j + 1}
    end
  end

  defp num(p, j), do: num(p, j, j)

  defp num(p, start, j) do
    case at(p, j) do
      c when c in ?0..?9 ->
        num(p, start, j + 1)

      _ when j == start ->
        nil

      _ ->
        digits = for k <- start..(j - 1), into: "", do: <<elem(p.src, k)>>
        {String.to_integer(digits), j}
    end
  end

  defp quantifier(t, p) do
    if more?(p), do: quantifier_at(t, p), else: {t, p}
  end

  defp quantifier_at(t, p) do
    bounds =
      case peek(p) do
        ?* ->
          {0, nil, adv(p)}

        ?+ ->
          {1, nil, adv(p)}

        ?? ->
          {0, 1, adv(p)}

        ?{ ->
          case brace(p) do
            nil ->
              nil

            {n, m, after_brace} ->
              if m != nil and m < n, do: raise_at(p, "numbers out of order in {} quantifier")
              {n, m, %{p | i: after_brace}}
          end

        _ ->
          nil
      end

    case bounds do
      nil ->
        {t, p}

      {lo, hi, p} ->
        if more?(p) and peek(p) == ??, do: raise_at(p, "lazy quantifiers are not supported")
        if t.kind == :look and t.behind, do: raise_at(p, "a lookbehind cannot be quantified")
        # A quantified term is wrapped, so its own min and max stay 1.
        t = if once?(t), do: t, else: tree(:group, children: [t])
        {%{t | min: lo, max: hi}, p}
    end
  end

  # JavaScript's Canonicalize without the `u` flag: a code unit's upper case
  # when that is one code unit, unless it would take a character outside
  # ASCII into it (so `ſ` is not `s` and the Kelvin sign is not `K`). Code
  # units whose canonical forms agree match each other under /i. Built when
  # the module compiles, from Elixir's own Unicode tables, which may be a
  # version apart from V8's.
  canon = fn c ->
    cond do
      c in ?a..?z ->
        c - 32

      c < 128 or c in 0xD800..0xDFFF ->
        c

      true ->
        case String.to_charlist(String.upcase(<<c::utf8>>)) do
          [u] when u >= 128 and u < 0x10000 -> u
          _ -> c
        end
    end
  end

  groups =
    0..0xFFFF
    |> Enum.group_by(canon)
    |> Map.values()
    |> Enum.filter(&(length(&1) > 1))

  # Each code unit outside ASCII that shares its canonical form, with the
  # others that share it.
  @fold_of groups |> Enum.reject(&(hd(&1) < 128)) |> Enum.flat_map(fn g -> Enum.map(g, &{&1, g}) end) |> Map.new()
  @foldable @fold_of |> Map.keys() |> Enum.reduce(0, &(&2 ||| 1 <<< &1))

  # The set with every code unit that matches one of its members under /i in
  # it: the other case of each ASCII letter, and of each character outside
  # ASCII that has one.
  defp folded(%{fold: false}, s), do: s

  defp folded(_p, s) do
    s =
      Enum.reduce(?A..?Z, s, fn c, s ->
        if has_raw(s, c) or has_raw(s, c + 32), do: s |> add(c) |> add(c + 32), else: s
      end)

    case s.bits &&& @foldable do
      0 ->
        s

      @foldable ->
        s

      some ->
        %{
          s
          | bits:
              some |> members() |> Enum.flat_map(&Map.fetch!(@fold_of, &1)) |> Enum.reduce(s.bits, &(&2 ||| 1 <<< &1))
        }
    end
  end

  # The code units in a bitmap, reading it a byte at a time, up to its
  # highest.
  defp members(int) do
    for <<byte <- :binary.encode_unsigned(int, :little)>>, reduce: {0, []} do
      {at, acc} ->
        acc =
          if byte == 0,
            do: acc,
            else: Enum.reduce(0..7, acc, fn k, acc -> if (byte >>> k &&& 1) == 1, do: [at + k | acc], else: acc end)

        {at + 8, acc}
    end
    |> elem(1)
  end

  defp class(p) do
    {negate, p} = if more?(p) and peek(p) == ?^, do: {true, adv(p)}, else: {false, p}
    {set, p} = class_members(p, new_set())
    set = folded(p, set)
    {%{set | negate: negate}, p}
  end

  defp class_members(p, set) do
    if not more?(p), do: raise_at(p, "missing ']'")

    if peek(p) == ?] do
      {set, adv(p)}
    else
      {lo, set, p} = class_atom(p, set)

      # A range a-b, unless "-" ends the class or either end is a class
      # escape such as \s (then "-" is literal, as Annex B reads it).
      if p.i + 1 < p.len and peek(p) == ?- and at(p, p.i + 1) != ?] do
        save = p.i
        {hi, _probe, p2} = class_atom(adv(p), new_set())

        if lo != nil and hi != nil do
          if hi < lo, do: raise_at(p2, "range out of order in character class")
          class_members(p2, add_range(set, lo, hi))
        else
          # Not a range: the "-" and what follows are members on their own.
          set = if lo, do: add(set, lo), else: set
          class_members(%{p | i: save + 1}, add(set, ?-))
        end
      else
        class_members(p, if(lo, do: add(set, lo), else: set))
      end
    end
  end

  # Reads one member of a class: a character (returned), or a class escape
  # added to the set (nil).
  defp class_atom(p, set) do
    c = peek(p)

    if c != ?\\ do
      {c, set, adv(p)}
    else
      p = adv(p)
      if not more?(p), do: raise_at(p, "\\ at end of pattern")

      if peek(p) == ?b do
        {0x08, set, adv(p)}
      else
        {single, p} = escape(p, new_set())

        case single_member(single) do
          nil -> {nil, union(set, single), p}
          r -> {r, set, p}
        end
      end
    end
  end

  # Reads what follows a backslash into the set.
  defp escape(p, set) do
    c = peek(p)
    p = adv(p)

    case c do
      ?d ->
        {add_range(set, ?0, ?9), p}

      ?D ->
        {Enum.reduce(?0..?9, add_range(set, 0, 0xFFFF), &remove(&2, &1)), p}

      ?w ->
        {add_word(set), p}

      ?W ->
        w = add_word(new_set())
        all = add_range(set, 0, 0xFFFF)
        {Enum.reduce(0..127, all, fn r, s -> if has_raw(w, r), do: remove(s, r), else: s end), p}

      ?s ->
        {%{set | space: true}, p}

      ?S ->
        {%{add_range(set, 0, 0xFFFF) | not_space: true}, p}

      ?n ->
        {add(set, ?\n), p}

      ?t ->
        {add(set, ?\t), p}

      ?r ->
        {add(set, ?\r), p}

      ?f ->
        {add(set, 0x0C), p}

      ?v ->
        {add(set, 0x0B), p}

      ?0 ->
        {add(set, 0), p}

      c when c in ?1..?9 or c in [?c, ?k, ?p, ?P] ->
        # JavaScript reads these as a backreference, a control character, a
        # named backreference, or a property; read as the plain letter they
        # would match something else, so they are refused.
        throw({:jsre, "jsre: \\#{<<c::utf8>>} is not supported"})

      c when c in [?x, ?u] ->
        width = if c == ?u, do: 4, else: 2
        if c == ?u and at(p, p.i) == ?{, do: throw({:jsre, "jsre: \\u{...} is not supported"})

        digits = for k <- p.i..(p.i + width - 1)//1, k < p.len, do: elem(p.src, k)

        if length(digits) == width and Enum.all?(digits, &hex?/1) do
          {add(set, List.to_integer(digits, 16)), adv(p, width)}
        else
          {add(set, c), p}
        end

      c ->
        {add(set, c), p}
    end
  end

  defp hex?(d), do: d in ?0..?9 or d in ?a..?f or d in ?A..?F

  defp add_word(s), do: s |> add_range(?a, ?z) |> add_range(?A, ?Z) |> add_range(?0, ?9) |> add(?_)

  ## Sets

  defp new_set, do: %{bits: 0, space: false, not_space: false, negate: false}

  defp add(s, r), do: %{s | bits: s.bits ||| 1 <<< r}

  defp add_range(s, lo, hi) when lo > hi, do: s

  defp add_range(s, lo, hi) do
    hi = min(hi, 0xFFFF)
    %{s | bits: s.bits ||| ((1 <<< (hi - lo + 1)) - 1) <<< lo}
  end

  defp remove(s, r), do: %{s | bits: s.bits &&& bnot(1 <<< r)}
  defp has_raw(s, c), do: (s.bits >>> c &&& 1) == 1

  defp union(a, b) do
    %{a | bits: a.bits ||| b.bits, space: a.space or b.space, not_space: a.not_space or b.not_space}
  end

  # The one character in a set holding exactly one plain character.
  defp single_member(%{space: false, not_space: false, negate: false, bits: bits})
       when bits > 0 and (bits &&& bits - 1) == 0 do
    bit_index(bits, 0)
  end

  defp single_member(_), do: nil

  defp bit_index(1, n), do: n
  defp bit_index(bits, n), do: bit_index(bits >>> 1, n + 1)

  @doc false
  # The final membership, `\s`, "everything but `\s`", and negation folded
  # in, as an integer bitmap and as a binary whose bit at offset c is unit c.
  def freeze(%{bits: bits} = s) do
    f = if s.space, do: bits ||| @space_bits, else: bits
    f = if s.not_space, do: f &&& bnot(@space_bits), else: f
    f = if s.negate, do: bnot(f) &&& @full, else: f
    frozen(f)
  end

  @doc false
  # The set as the matcher tests it: a tuple of at most #{@max_ranges} ranges,
  # `{lo1, hi1, lo2, hi2, ...}` in ascending order, for the sets nearly every
  # pattern is made of (a character, a letter in both cases, `[a-z]`, `\d`,
  # `\w`, `.`, `[^x]`), else the bitmap of every code unit. A bitmap is 2048
  # words, so a pattern of 4096 characters held one per character came to
  # some 130 MB, copied again whenever a job's definition was read from the
  # instance's table.
  def frozen(int) do
    case ranges(int, 0, []) do
      {:ok, flat} -> {int, List.to_tuple(flat)}
      :many -> {int, bits_binary(int)}
    end
  end

  @max_ranges 4

  defp ranges(0, _n, acc), do: {:ok, Enum.reverse(acc)}
  defp ranges(_x, @max_ranges, _acc), do: :many

  defp ranges(x, n, acc) do
    lo = low_bit(x)
    # The first clear bit above lo ends the run.
    len = low_bit(bnot(x >>> lo))
    hi = lo + len - 1
    ranges(x &&& bnot((1 <<< (hi + 1)) - 1), n + 1, [hi, lo | acc])
  end

  # The index of the lowest set bit of a nonzero integer.
  defp low_bit(x) do
    p = x &&& -x
    bytes = :binary.encode_unsigned(p)
    <<top, _::binary>> = bytes
    (byte_size(bytes) - 1) * 8 + bit_index(top, 0)
  end

  # The bitmap as 2048 words of 32 bits, bit c of the integer at bit c &&& 31
  # of word c >>> 5: a lookup is one elem and a shift.
  defp bits_binary(int) do
    List.to_tuple(for <<(w::little-32 <- <<int::little-size(65_536)>>)>>, do: w)
  end
end
