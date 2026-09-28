defmodule Grasp.Index.TestTrace do
  @moduledoc """
  Traces a project's tests in its test environment and hands back the calls they make.

  Test files compile only under `MIX_ENV=test`, against dependencies a host may declare for
  tests alone, and Grasp is a dev-only dependency, so the trace cannot run in the session
  that builds the index. `run/3` starts one subprocess instead:

      MIX_ENV=test MIX_BUILD_PATH=_build/grasp_test \\
        mix run --no-start priv/test_trace.exs EVENTS GRASP_EBIN DEV_PATHS CANDIDATES

  `mix run` compiles the project before the script starts, with Grasp absent from the test
  session's code path, so the test build is the one `mix test` would compile. The script
  then prepends the `ebin` directory of the running session's `grasp`, installs
  `Grasp.Index.Tracer` and requires the test-only support files and the test files
  `mix test` loads, found by `test_files/2`, without running a test. It writes the events
  those files produced, the files themselves and the test paths to `EVENTS` in the external
  term format; this module reads that file back and deletes it.

  The test files are chosen from the test environment's project config, whose load filters
  may be functions only that session can call. A path the branch deleted is judged there
  too: `CANDIDATES` holds the paths the caller asks about, and the script answers the ones
  `mix test` would load, by `would_load/3`.

  `_build/grasp_test` is the trace's own build directory, so a `mix test` in another
  terminal is never compiled under. The first time it is missing it is seeded by copying
  `_build/test`, when there is one, so that first trace compiles the project rather than
  every dependency it carries. The copy is staged under a name of its own and renamed into
  place, so an interrupted seed leaves nothing a later run mistakes for a finished one.
  """

  alias Grasp.Index.Tracer

  @build "_build/grasp_test"
  @source_build "_build/test"

  @type trace :: %{
          events: [Tracer.event()],
          files: [String.t()],
          test_paths: [String.t()],
          selected: [String.t()]
        }

  @type selection :: %{test_paths: [String.t()], files: [String.t()]}

  @type runner :: (String.t(), [String.t()], keyword() -> {Collectable.t(), non_neg_integer()})

  @doc """
  Traces the tests of the project at `root`, whose dev environment compiles `dev_paths`.

  Returns the events recorded in the test files and test-only support files, each naming
  its file relative to `root`, those files, the test paths of the test environment and
  the paths among `opts[:candidates]` that `mix test` would load were they on disk; or
  `{:error, output}` with the subprocess's output when a test file does not compile, and
  a message when the running session has no compiled `grasp` to lend the test
  environment.

  `opts[:candidates]` are project-relative paths, defaulting to none. `opts[:runner]`
  replaces `System.cmd/3`.
  """
  @spec run(String.t(), [String.t()], runner: runner(), candidates: [String.t()]) ::
          {:ok, trace()} | {:error, String.t()}
  def run(root, dev_paths, opts \\ []) do
    runner = Keyword.get(opts, :runner, &System.cmd/3)
    build = Path.join(root, @build)

    with {:ok, grasp_ebin} <- ebin(:grasp, "Elixir.Grasp.Index.Tracer.beam") do
      seed(root)
      File.mkdir_p!(build)
      unique = System.unique_integer([:positive])
      events_file = Path.join(build, "events-#{unique}.bin")
      candidates_file = Path.join(build, "candidates-#{unique}.bin")
      File.write!(candidates_file, :erlang.term_to_binary(Keyword.get(opts, :candidates, [])))

      args = [
        "run",
        "--no-start",
        script(),
        events_file,
        grasp_ebin,
        Enum.join(dev_paths, ","),
        candidates_file
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
        File.rm(candidates_file)
      end
    end
  end

  @doc """
  The test paths of the project `config` describes at `root`, and the test files under them
  `mix test` loads, relative to `root` and sorted.

  The selection is `mix test`'s own. `:test_paths` defaults to `["test"]` when `root` has a
  `test` directory and to none otherwise. Every file matching `:test_pattern`, by default
  `"*.{ex,exs}"`, anywhere under a test path is a candidate, and a test path naming a file
  rather than a directory is one itself. A candidate is loaded when it matches one of
  `:test_load_filters`, by default a path ending in `_test.exs`, each filter being a path the
  candidate equals, a regex it matches or a one-arity function answering true of it. The
  `:test_ignore_filters` never stop a file a load filter matches from loading: they decide
  which of the files left over `mix test` stays quiet about, so they take no part here.
  """
  @spec test_files(keyword(), String.t()) :: selection()
  def test_files(config, root) do
    test_paths = config[:test_paths] || default_test_paths(root)
    pattern = config[:test_pattern] || "*.{ex,exs}"
    filters = config[:test_load_filters] || [&String.ends_with?(&1, "_test.exs")]

    files =
      test_paths
      |> Enum.flat_map(fn path ->
        full = Path.expand(path, root)

        cond do
          File.dir?(full) -> Path.wildcard(Path.join([full, "**", pattern]))
          File.regular?(full) -> [full]
          true -> []
        end
      end)
      |> Enum.map(&Path.relative_to(&1, root))
      |> Enum.uniq()
      |> Enum.filter(fn file -> Enum.any?(filters, &matches?(file, &1)) end)
      |> Enum.sort()

    %{test_paths: test_paths, files: files}
  end

  @doc """
  The project-relative `paths` that `mix test` would load under `test_paths`, were they on
  disk, for the project `config` describes.

  Each path is laid out, empty, in a scratch directory and put through `test_files/2`
  there, so the pattern is matched exactly as `Path.wildcard/1` matches it on disk.
  """
  @spec would_load(keyword(), [String.t()], [String.t()]) :: [String.t()]
  def would_load(_config, _test_paths, []), do: []

  def would_load(config, test_paths, paths) do
    unique = "#{System.pid()}-#{System.unique_integer([:positive])}"
    scratch = Path.join(System.tmp_dir!(), "grasp-test-paths-#{unique}")

    try do
      for path <- paths, match?({:ok, _safe}, Path.safe_relative(path)) do
        file = Path.join(scratch, path)
        File.mkdir_p!(Path.dirname(file))
        File.touch!(file)
      end

      loaded = test_files(Keyword.put(config, :test_paths, test_paths), scratch).files
      Enum.filter(paths, &(&1 in loaded))
    after
      File.rm_rf!(scratch)
    end
  end

  defp default_test_paths(root) do
    if File.dir?(Path.join(root, "test")), do: ["test"], else: []
  end

  defp matches?(file, %Regex{} = regex), do: Regex.match?(regex, file)
  defp matches?(file, filter) when is_binary(filter), do: file == filter
  defp matches?(file, filter) when is_function(filter, 1), do: filter.(file)

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
