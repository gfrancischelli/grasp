defmodule Grasp.Index.TestTrace do
  @moduledoc """
  Traces a project's tests in its test environment and hands back the calls they make.

  Test files compile only under `MIX_ENV=test`, against dependencies a host may declare for
  tests alone, and Grasp is a dev-only dependency, so the trace cannot run in the session
  that builds the index. `run/3` starts one subprocess instead:

      MIX_ENV=test MIX_BUILD_PATH=_build/grasp_test \\
        mix run --no-start priv/test_trace.exs EVENTS GRASP_EBIN DEV_PATHS

  `mix run` compiles the project before the script starts, with Grasp absent from the test
  session's code path, so the test build is the one `mix test` would compile. The script
  then prepends the `ebin` directory of the running session's `grasp`, installs
  `Grasp.Index.Tracer` and requires the test-only support files and every
  `test/**/*_test.exs` without running a test. It writes the events those files produced,
  and the files themselves, to `EVENTS` in the external term format; this module reads that
  file back and deletes it.

  `_build/grasp_test` is the trace's own build directory, so a `mix test` in another
  terminal is never compiled under. The first time it is missing it is seeded by copying
  `_build/test`, when there is one, so that first trace compiles the project rather than
  every dependency it carries. The copy is staged under a name of its own and renamed into
  place, so an interrupted seed leaves nothing a later run mistakes for a finished one.
  """

  alias Grasp.Index.Tracer

  @build "_build/grasp_test"
  @source_build "_build/test"

  @type trace :: %{events: [Tracer.event()], files: [String.t()]}

  @type runner :: (String.t(), [String.t()], keyword() -> {Collectable.t(), non_neg_integer()})

  @doc """
  Traces the tests of the project at `root`, whose dev environment compiles `dev_paths`.

  Returns the events recorded in the test files and test-only support files, each naming
  its file relative to `root`, and those files; or `{:error, output}` with the
  subprocess's output when a test file does not compile, and a message when the running
  session has no compiled `grasp` to lend the test environment.

  `opts[:runner]` replaces `System.cmd/3`.
  """
  @spec run(String.t(), [String.t()], runner: runner()) :: {:ok, trace()} | {:error, String.t()}
  def run(root, dev_paths, opts \\ []) do
    runner = Keyword.get(opts, :runner, &System.cmd/3)
    build = Path.join(root, @build)

    with {:ok, grasp_ebin} <- ebin(:grasp, "Elixir.Grasp.Index.Tracer.beam") do
      seed(root)
      File.mkdir_p!(build)
      events_file = Path.join(build, "events-#{System.unique_integer([:positive])}.bin")

      args = [
        "run",
        "--no-start",
        script(),
        events_file,
        grasp_ebin,
        Enum.join(dev_paths, ",")
      ]

      try do
        {output, status} =
          runner.("mix", args,
            cd: root,
            env: [{"MIX_ENV", "test"}, {"MIX_BUILD_PATH", build}],
            stderr_to_stdout: true
          )

        read_events(events_file, status, output)
      after
        File.rm(events_file)
      end
    end
  end

  @doc "The script `run/3` runs in the test environment, as shipped in Grasp's `priv`."
  @spec script() :: String.t()
  def script, do: Application.app_dir(:grasp, "priv/test_trace.exs")

  defp read_events(events_file, 0, output) do
    case File.read(events_file) do
      {:ok, binary} -> {:ok, :erlang.binary_to_term(binary)}
      {:error, _reason} -> {:error, to_string(output)}
    end
  end

  defp read_events(_events_file, _status, output), do: {:error, to_string(output)}

  # The test session loads these beams by path, so they have to be where this session found
  # them; a Grasp loaded some other way — an escript, a release — has no directory to lend.
  defp ebin(app, beam) do
    with dir when is_list(dir) <- :code.lib_dir(app),
         ebin = Path.join(to_string(dir), "ebin"),
         true <- File.regular?(Path.join(ebin, beam)) do
      {:ok, ebin}
    else
      _missing ->
        {:error,
         "no compiled #{app} to load into the test environment (looked for #{beam} " <>
           "in the ebin of #{inspect(:code.lib_dir(app))})"}
    end
  end

  defp seed(root) do
    source = Path.join(root, @source_build)
    build = Path.join(root, @build)
    staging = build <> ".seeding"

    if not File.dir?(build) and File.dir?(source) do
      Mix.shell().info("grasp: seeding #{@build} from #{@source_build}")
      File.rm_rf!(staging)
      File.cp_r!(source, staging)
      File.rename!(staging, build)
    end
  end
end
