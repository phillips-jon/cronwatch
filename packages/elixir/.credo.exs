# Credo's settings for the Elixir port, run as `mix credo --strict`.
#
# Much of the package is a line-for-line port of code other ports share (the
# croner port, the JavaScript regular expression engine, the JSON reader,
# the SDK's evaluate and client logic), kept close to the TypeScript so a
# change there can be followed here. Credo's complexity and nesting limits
# would push those functions apart from their originals, so the two checks
# are off. The Logger metadata keys are the app's to configure.
%{
  configs: [
    %{
      name: "default",
      files: %{included: ["lib/", "test/", "mix.exs"], excluded: [~r"/_build/", ~r"/deps/"]},
      strict: true,
      checks: %{
        disabled: [
          {Credo.Check.Refactor.CyclomaticComplexity, []},
          {Credo.Check.Refactor.Nesting, []},
          {Credo.Check.Warning.MissedMetadataKeyInLoggerConfig, []}
        ]
      }
    }
  ]
}
