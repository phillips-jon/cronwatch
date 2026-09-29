# The fixtures are made with TZ=UTC, and a schedule without a zone is read in
# the process's own, so the tests refuse to run in any other zone. The `test`
# alias in mix.exs sets it.
if System.get_env("TZ") != "UTC" do
  IO.puts(:stderr, "run the tests with TZ=UTC (mix test sets it through its alias)")
  System.halt(1)
end

# assert_receive waits up to two seconds, not ExUnit's 100 ms: a CI runner
# can take longer than that to start a run's task, and the wait only
# lengthens a test that is about to fail.
ExUnit.start(exclude: [:property_long], assert_receive_timeout: 2_000)
