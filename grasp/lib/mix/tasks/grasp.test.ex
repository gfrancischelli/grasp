defmodule Mix.Tasks.Grasp.Test do
  @shortdoc "Runs the project's tests and records each result in .grasp/results.json"

  @moduledoc """
  Runs the project's own test suite, or part of it, and records each test's result in the
  results document the Grasp viewer and MCP server read (see `Grasp.TestResults`).

      mix grasp.test TEST_ID ...
      mix grasp.test --changed
      mix grasp.test --all

  A test id is the id of a test record in the index,
  `SampleApp.TallyTest."test init keeps the start count"/1`, and names the file and line
  `mix test` is given for it: the record's `file` and the first line of its `span`. An id
  the index holds no test for aborts the task, listing every such id. `--changed` runs the
  tests the index marks added or modified against its base ref, and does nothing when there
  are none; `--all` runs the whole suite.

  The suite runs in the project root with `MIX_ENV=test` over the environment this task
  runs in, its output streamed to the terminal:

      mix run --no-start priv/test_run.exs GRASP_EBIN RUN_FILE -- FILE:LINE ...

  The script, shipped in Grasp's `priv`, puts the `ebin` of this session's `grasp` on the
  path only once the project has compiled, so Grasp is never needed in the project's test
  environment, and runs `mix test` with `Grasp.Test.Formatter` beside
  `ExUnit.CLIFormatter`, in place of any formatter the project configures. The formatter
  writes the run's results to `RUN_FILE`, beside the results document, and this task merges
  them into the document with `Grasp.TestResults.merge/3`, stamping each with the run's id,
  its finish time and the hash of the test's indexed source. The results of tests the run
  does not name are left as they stood. The run file is removed afterwards.

  The task exits with the suite's status. A run that records nothing — a project that does
  not compile, a suite that cannot start — aborts with that status and leaves the document
  untouched. An umbrella's apps each run their own suite, so the task refuses to run at an
  umbrella root: run it inside the app.

  ## Options

    * `--out` - where to write the results document. Defaults to `results.json` beside the
      index.
    * `--index` - the index the test ids are resolved in. Defaults to `:grasp, :index_path`
      when it names one, and to `.grasp/index.json` otherwise.
  """

  use Mix.Task

  @switches [changed: :boolean, all: :boolean, out: :string, index: :string]
  @formatter_beam "Elixir.Grasp.Test.Formatter.beam"

  @typedoc "Stands in for `System.cmd/3`."
  @type runner :: (String.t(), [String.t()], keyword() -> {term(), non_neg_integer()})

  @impl Mix.Task
  def run(args), do: run(args, &System.cmd/3)

  @doc """
  Runs the task as `run/1` does, starting the suite's command with `runner` in place of
  `System.cmd/3`.
  """
  @spec run([String.t()], runner()) :: :ok
  def run(args, runner) when is_list(args) and is_function(runner, 3) do
    {opts, ids, invalid} = OptionParser.parse(args, strict: @switches)

    if invalid != [] do
      Mix.raise("grasp.test: unknown options #{inspect(Enum.map(invalid, &elem(&1, 0)))}")
    end

    if Mix.Project.umbrella?() do
      Mix.raise(
        "grasp.test: an umbrella's apps each run their own suite; " <>
          "run mix grasp.test inside the app"
      )
    end

    root = File.cwd!()
    index_path = index_path(opts[:index], root)
    out = Path.expand(opts[:out] || Path.join(Path.dirname(index_path), "results.json"), root)

    index =
      case Grasp.Index.load(index_path) do
        {:ok, index} ->
          index

        {:error, reason} ->
          Mix.raise(
            "grasp.test: cannot read the index at #{index_path} (#{inspect(reason)}); " <>
              "run mix grasp.index first"
          )
      end

    case selection(index, ids, opts) do
      nil -> Mix.shell().info("grasp: no added or modified tests to run")
      files -> run_suite(root, index, out, files, runner)
    end
  end

  defp index_path(nil, root) do
    case Application.get_env(:grasp, :index_path) do
      path when is_binary(path) and path != "" -> Path.expand(path, root)
      _unset -> Path.join(root, ".grasp/index.json")
    end
  end

  defp index_path(path, root), do: Path.expand(path, root)

  # The `mix test` arguments naming the tests to run: `[]` runs the whole suite, and `nil`
  # is a `--changed` with no test to run.
  defp selection(index, ids, opts) do
    case {ids, opts[:changed] == true, opts[:all] == true} do
      {[_ | _], false, false} ->
        {tests, unknown} = ids |> Enum.uniq() |> Enum.split_with(&test?(index, &1))

        if unknown != [] do
          Mix.raise(
            "grasp.test: the index holds no test for " <> Enum.map_join(unknown, ", ", &inspect/1)
          )
        end

        locations(Enum.map(tests, &Map.fetch!(index.functions, &1)))

      {[], true, false} ->
        index
        |> Grasp.Index.functions()
        |> Enum.filter(&(test?(index, &1["id"]) and &1["change"] in ~w(added modified)))
        |> locations()
        |> case do
          [] -> nil
          files -> files
        end

      {[], false, true} ->
        []

      _other ->
        Mix.raise("grasp.test: name the tests to run, or pass one of --changed and --all")
    end
  end

  defp test?(index, id) do
    case index.functions[id] do
      %{"kind" => "test"} = record -> record["removed"] != true
      _other -> false
    end
  end

  defp locations(records) do
    records
    |> Enum.map(fn %{"file" => file, "span" => %{"start_line" => line}} -> "#{file}:#{line}" end)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp run_suite(root, index, out, files, runner) do
    grasp_ebin = ebin!()
    run_id = Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
    run_file = Path.join(Path.dirname(out), "run-#{run_id}.bin")
    File.mkdir_p!(Path.dirname(out))

    args = ["run", "--no-start", script(), grasp_ebin, run_file, "--" | files]

    try do
      {_output, status} =
        runner.("mix", args, cd: root, env: [{"MIX_ENV", "test"}], into: IO.stream())

      record(run_file, out, index, run_id, status)
      if status != 0, do: exit({:shutdown, status})
      :ok
    after
      File.rm(run_file)
    end
  end

  defp record(run_file, out, index, run_id, status) do
    run =
      case File.read(run_file) do
        {:ok, binary} ->
          :erlang.binary_to_term(binary)

        {:error, _reason} ->
          Mix.shell().error(
            "grasp: the test run exited with status #{status} and recorded no results"
          )

          exit({:shutdown, if(status == 0, do: 1, else: status)})
      end

    document =
      case Grasp.TestResults.read(out) do
        {:ok, document} ->
          document

        {:error, reason} ->
          Mix.shell().info(
            "grasp: #{out} cannot be read (#{inspect(reason)}); it is replaced by this run's results"
          )

          Grasp.TestResults.new()
      end

    document =
      Grasp.TestResults.merge(document, run.tests, %{
        run_id: run_id,
        finished_at: run.finished_at,
        index: index
      })

    case Grasp.TestResults.write(document, out) do
      :ok ->
        Mix.shell().info("Grasp test results written to #{out} (#{summary(run.tests)})")

      {:error, reason} ->
        Mix.raise("grasp.test: cannot write #{out}: #{:file.format_error(reason)}")
    end
  end

  defp summary(tests) do
    counts = tests |> Map.values() |> Enum.frequencies_by(& &1["status"])

    ~w(passed failed skipped excluded invalid)
    |> Enum.filter(&Map.has_key?(counts, &1))
    |> Enum.map_join(", ", &"#{counts[&1]} #{&1}")
    |> case do
      "" -> "no tests"
      text -> text
    end
  end

  defp script, do: Application.app_dir(:grasp, "priv/test_run.exs")

  # The test session loads the formatter by path, so it has to be where this session found
  # it; a Grasp loaded some other way — an escript, a release — has no directory to lend.
  defp ebin! do
    with dir when is_list(dir) <- :code.lib_dir(:grasp),
         ebin = Path.join(to_string(dir), "ebin"),
         true <- File.regular?(Path.join(ebin, @formatter_beam)) do
      ebin
    else
      _missing ->
        Mix.raise(
          "grasp.test: no compiled grasp to load into the test environment (looked for " <>
            "#{@formatter_beam} in the ebin of #{inspect(:code.lib_dir(:grasp))})"
        )
    end
  end
end
