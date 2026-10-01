defmodule Cronwatch.PublicAPIReportTest do
  # The public API, written out in api.txt so that a change to it is a line
  # of the diff: every module HexDocs shows, with each function, macro,
  # callback and type it documents (by name and arity), and which are
  # deprecated. Cronwatch.Bridge is left out: it is for integration authors,
  # outside the 1.x promise.
  #
  # When this fails, the public API changed. Rewrite the file with
  #
  #   CRONWATCH_WRITE_API=1 mix test test/public_api_report_test.exs
  #
  # read the diff, and record the change in CHANGELOG.md (under Unreleased)
  # in the same commit. Removing a line is a breaking change, which waits for
  # a major release (site/docs/stability.md).
  use ExUnit.Case, async: true

  @api Path.expand("../api.txt", __DIR__)
  @kinds [:function, :macro, :callback, :macrocallback, :type]

  defp report do
    :cronwatch
    |> Application.spec(:modules)
    |> Enum.sort()
    |> Enum.reject(&String.starts_with?(inspect(&1), "Cronwatch.Bridge"))
    |> Enum.flat_map(&module_lines/1)
    |> Enum.join("\n")
    |> Kernel.<>("\n")
  end

  defp module_lines(module) do
    case Code.fetch_docs(module) do
      {:docs_v1, _, _, _, moduledoc, _, entries} when moduledoc != :hidden ->
        lines =
          for {{kind, name, arity}, _, _, doc, meta} <- entries,
              kind in @kinds,
              doc != :hidden,
              do: "  #{kind} #{name}/#{arity}#{deprecated(meta)}"

        ["# #{inspect(module)}" | Enum.sort(lines)]

      _ ->
        []
    end
  end

  defp deprecated(%{deprecated: _}), do: " (deprecated)"
  defp deprecated(_), do: ""

  test "the public API is recorded in api.txt" do
    text = report()
    if System.get_env("CRONWATCH_WRITE_API"), do: File.write!(@api, text)

    assert File.read!(@api) == text,
           "The public API changed. Run CRONWATCH_WRITE_API=1 mix test " <>
             "test/public_api_report_test.exs, review the diff of api.txt and " <>
             "record the change in CHANGELOG.md."
  end
end
