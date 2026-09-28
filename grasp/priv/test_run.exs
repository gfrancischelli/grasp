# Runs a project's tests and records each result. `mix grasp.test` runs this file in the
# project's test environment:
#
#     MIX_ENV=test mix run --no-start test_run.exs GRASP_EBIN RUN_FILE -- MIX_TEST_ARGS
#
# `mix run` compiles the dependencies and the project before this script starts, with Grasp
# absent from the code path, so a host guard such as `Code.ensure_loaded?(Grasp.Router)`
# reads false in the test build, as it does in `mix test`. Grasp's ebin goes on the path only
# after that compile: a path given on the command line is pruned by Mix before `mix test`
# would load a formatter from it. The script then runs `mix test` in this same session with
# MIX_TEST_ARGS and `--formatter Grasp.Test.Formatter --formatter ExUnit.CLIFormatter`.
#
# Those two formatters replace the ones the project configures for ExUnit, in its config or
# its `test_helper.exs`: `mix test` applies its command line's `--formatter` over both, so
# for this run the terminal shows ExUnit's own report and nothing a project formatter adds.
#
# `Grasp.Test.Formatter` writes this run's results to RUN_FILE when the suite finishes, in
# the external term format; `mix grasp.test` merges them into the results document.
# `mix test` ignores a formatter it cannot load, so a formatter missing from GRASP_EBIN stops
# the script before the suite runs, rather than letting a run go unrecorded.

[grasp_ebin, run_file | rest] = System.argv()

test_args =
  case rest do
    ["--" | args] -> args
    args -> args
  end

Code.prepend_path(grasp_ebin)

case Code.ensure_loaded(Grasp.Test.Formatter) do
  {:module, _module} ->
    :ok

  {:error, reason} ->
    IO.puts(
      :stderr,
      "grasp: cannot load Grasp.Test.Formatter from #{grasp_ebin} (#{inspect(reason)})"
    )

    exit({:shutdown, 1})
end

Application.put_env(:grasp, Grasp.Test.Formatter, run_file: run_file)

Mix.Task.run(
  "test",
  test_args ++ ["--formatter", "Grasp.Test.Formatter", "--formatter", "ExUnit.CLIFormatter"]
)
