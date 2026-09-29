# The fixtures are made with TZ=UTC, and a schedule without a zone is read in
# the process's own, so the tests refuse to run in any other zone. The `test`
# alias in mix.exs sets it.
if System.get_env("TZ") != "UTC" do
  IO.puts(:stderr, "run the tests with TZ=UTC (mix test sets it through its alias)")
  System.halt(1)
end

ExUnit.start(exclude: [:property_long])
