defmodule Mix.Tasks.Cronwatch.Check do
  @shortdoc "Runs one CronWatch check"

  @moduledoc """
  Runs one CronWatch check from source, as `Cronwatch.Release.check/2` does
  in a release: for a crontab line on a machine that runs the app with Mix.

      mix cronwatch.check                    # the instance named Cronwatch
      mix cronwatch.check MyApp.Cronwatch    # the options under config :my_app, MyApp.Cronwatch

  The configuration is the project's (`config/runtime.exs` included); the
  app itself is not started. `--otp-app` names the application whose
  environment holds the options, the project's by default. It exits
  non-zero when the check fails.
  """

  use Mix.Task

  @impl true
  def run(args) do
    {opts, rest, _} = OptionParser.parse(args, strict: [otp_app: :string])
    Mix.Task.run("app.config")

    name =
      case rest do
        [] -> Cronwatch
        [text | _] -> instance_name(text)
      end

    otp_app =
      case opts[:otp_app] do
        nil -> Mix.Project.config()[:app]
        app -> String.to_atom(app)
      end

    case Cronwatch.Release.check(name, otp_app: otp_app, halt: false) do
      {:ok, _} -> :ok
      {:error, _} -> exit({:shutdown, 1})
    end
  end

  # A module name (MyApp.Cronwatch) or an atom's (:my_cronwatch).
  defp instance_name(":" <> atom), do: String.to_atom(atom)
  defp instance_name(text), do: Module.concat([text])
end
