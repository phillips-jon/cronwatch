defmodule Cronwatch.Serialize do
  @moduledoc false
  # Internal: not the package's API, and it can change in any release.
  #
  # Expect rules and how a definition is stored (the SDK's `serialize.ts`).
  #
  # A job's `expect` is a rule its successful run's output must satisfy:
  #
  #   * `{:contains, text}`: the output must contain the text, stored as
  #     `contains "text"`;
  #   * `{:matches, %Cronwatch.JSRE{}}`: a JavaScript pattern must match
  #     somewhere, stored as `matches /source/flags` and run by
  #     `Cronwatch.JSRE` within its step budget;
  #   * `{:fun, fun}`: a one-argument function must return true, stored as
  #     `custom function`.

  alias Cronwatch.JS
  alias Cronwatch.JS.Object
  alias Cronwatch.JSRE

  @type rule :: {:contains, String.t()} | {:matches, JSRE.t()} | {:fun, (String.t() -> term())}

  @doc """
  The rule an app's `expect` option gives: a binary (contains),
  `{:matches, source, flags}` (a JavaScript pattern), or a one-argument
  function. A `%Regex{}` is refused: Elixir's regular expressions are PCRE,
  which reads a pattern differently from JavaScript, and the stored rule is
  read by processes in every language.
  """
  @spec rule(term()) :: {:ok, rule()} | {:error, String.t()}
  def rule(text) when is_binary(text), do: {:ok, {:contains, text}}

  def rule({:matches, source, flags}) when is_binary(source) and is_binary(flags) do
    case JSRE.compile(source, flags) do
      {:ok, re} ->
        {:ok, {:matches, re}}

      {:error, message} ->
        {:error, "expect {:matches, #{inspect(source)}, #{inspect(flags)}} is not supported: #{message}"}
    end
  end

  def rule({:matches, source}) when is_binary(source), do: rule({:matches, source, ""})
  def rule(fun) when is_function(fun, 1), do: {:ok, {:fun, fun}}
  def rule({:contains, text} = r) when is_binary(text), do: {:ok, r}
  def rule({:matches, %JSRE{}} = r), do: {:ok, r}
  def rule({:fun, fun} = r) when is_function(fun, 1), do: {:ok, r}

  def rule(%Regex{source: source}) do
    {:error,
     "expect does not take a Regex, which is PCRE and reads a pattern differently from JavaScript; " <>
       "write {:matches, #{inspect(source)}, \"flags\"} for a JavaScript pattern"}
  end

  def rule(other) do
    {:error,
     "expect must be a string, {:matches, \"source\", \"flags\"}, or a one-argument function, not #{inspect(other)}"}
  end

  @doc """
  nil when the output passes the rule, or why it does not. A function that
  raises, throws, or exits fails the run with `Output check threw: ...`; a
  stored pattern that gives up (past its step budget or 512 frames) fails
  with the ordinary `Output did not match /source/flags`.
  """
  @spec check(rule(), String.t()) :: String.t() | nil
  def check({:contains, text}, output) do
    if String.contains?(output, text), do: nil, else: "Output did not contain #{JS.quote(text)}"
  end

  def check({:matches, re}, output) do
    case JSRE.try_match?(re, output) do
      {:ok, true} -> nil
      _ -> "Output did not match #{JSRE.source(re)}"
    end
  end

  def check({:fun, fun}, output) do
    if fun.(output) in [nil, false], do: "Output did not pass the expect() check"
  catch
    kind, reason -> "Output check threw: #{thrown(kind, reason, __STACKTRACE__)}"
  end

  defp thrown(:error, reason, stacktrace), do: Exception.message(Exception.normalize(:error, reason, stacktrace))
  defp thrown(:throw, value, _), do: if(is_binary(value), do: value, else: inspect(value))
  defp thrown(:exit, reason, _), do: if(is_binary(reason), do: reason, else: inspect(reason))

  @doc "The stored definition's `expect`: `contains \"...\"`, `matches /.../`, or `custom function`."
  @spec describe(rule()) :: String.t()
  def describe({:contains, text}), do: "contains " <> JS.quote(text)
  def describe({:matches, re}), do: "matches " <> JSRE.source(re)
  def describe({:fun, _}), do: "custom function"

  @doc """
  A definition as a store can hold it (`toStored`): the fields as given, less
  `expect`, which goes last as a description.
  """
  @spec to_stored(Object.t(), rule() | nil) :: Object.t()
  def to_stored(%Object{} = fields, rule) do
    stored = Object.delete(fields, "expect")
    if rule, do: Object.put(stored, "expect", describe(rule)), else: stored
  end

  @doc """
  `checkExpectation`: nil when there is no rule or the output satisfies it,
  otherwise why not. No output is checked as `""`.
  """
  @spec check_expectation(rule() | nil, String.t() | nil) :: String.t() | nil
  def check_expectation(nil, _output), do: nil
  def check_expectation(rule, output), do: check(rule, output || "")

  @doc """
  A stored job as the client reads it (the SDK's readStoredJob), so a
  foreign, hand-edited, or damaged row affects only its own job: answers
  `{job, readable}`. A definition that is not a JSON object (a SQL store
  reads text that does not parse as nil) becomes `{name}` and `readable` is
  false: the client reports the job and shows it as failing, without
  evaluating it. `tags` is kept only when it is a list of strings. Every
  other field is kept as stored.
  """
  @spec read_stored_job(Cronwatch.StoredJob.t()) :: {Cronwatch.StoredJob.t(), boolean()}
  def read_stored_job(%Cronwatch.StoredJob{definition: %Object{} = definition} = stored) do
    definition =
      case Object.fetch(definition, "tags") do
        {:ok, tags} when is_list(tags) ->
          if Enum.all?(tags, &is_binary/1), do: definition, else: Object.delete(definition, "tags")

        {:ok, _} ->
          Object.delete(definition, "tags")

        :error ->
          definition
      end

    {%{stored | definition: definition}, true}
  end

  def read_stored_job(%Cronwatch.StoredJob{} = stored),
    do: {%{stored | definition: Object.new([{"name", stored.name}])}, false}
end
