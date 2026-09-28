defmodule Mix.Tasks.Grasp.Cover do
  @shortdoc "Runs the test suite under cover and writes .grasp/coverage.json"

  @moduledoc """
  Runs the project's test suite under Mix's cover tool and writes the coverage document the
  Grasp viewer and MCP server read (see `Grasp.Coverage`).

      mix grasp.cover [--out PATH] [--index PATH]

  The suite runs exactly as the project runs it: the command is `:grasp, :test_command`,
  `["mix", "test"]` unless configured, started in the project root with `MIX_ENV=test` over
  the environment this task runs in and `--cover --export-coverage grasp` added,
  its output streamed to the terminal. A run whose tests fail still exports what ran, so a
  non-zero exit is reported and the coverage is written from the export; a run that leaves
  no export aborts the task with the command's status. An export an earlier run left behind
  is removed before the suite starts, so the document never describes a run other than this
  one.

  The export, `cover/grasp.coverdata`, is imported into `:cover` in this task's own process:
  analysing imported data needs no cover-compiled module, so Grasp is never needed in the
  project's test environment. Each module's line counts are attributed to the file it is
  compiled from — the `source` in its compile info when the module can be loaded here, and
  otherwise the file the index names for it — relative to the project root. The export is
  left where Mix wrote it.

  ## Options

    * `--out` - where to write the coverage document. Defaults to `coverage.json` beside the
      index.
    * `--index` - the index whose functions the coverage is written for. Defaults to
      `:grasp, :index_path` when it names one, and to `.grasp/index.json` otherwise.
  """

  use Mix.Task

  # `:tools` is loaded at run time with `Mix.ensure_application!/1`, as Mix's own cover
  # tool loads it, rather than made a dependency of every project Grasp is installed in.
  @compile {:no_warn_undefined, :cover}

  @switches [out: :string, index: :string]
  @export "cover/grasp.coverdata"

  @impl Mix.Task
  def run(args) do
    {opts, _positional, invalid} = OptionParser.parse(args, strict: @switches)

    if invalid != [] do
      Mix.raise("grasp.cover: unknown options #{inspect(Enum.map(invalid, &elem(&1, 0)))}")
    end

    root = File.cwd!()
    index_path = index_path(opts[:index], root)
    out = Path.expand(opts[:out] || Path.join(Path.dirname(index_path), "coverage.json"), root)

    index =
      case Grasp.Index.load(index_path) do
        {:ok, index} ->
          index

        {:error, reason} ->
          Mix.raise(
            "grasp.cover: cannot read the index at #{index_path} (#{inspect(reason)}); " <>
              "run mix grasp.index first"
          )
      end

    export = Path.join(root, @export)
    File.rm(export)
    run_suite(root, export)

    lines_by_file = import_lines(export, index, root)

    document =
      Grasp.Coverage.build(index, lines_by_file, %{
        generated_at: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
        git_head: git_head(root)
      })

    case Grasp.Coverage.write(document, out) do
      :ok ->
        Mix.shell().info(
          "Grasp coverage written to #{out} (#{map_size(document["functions"])} functions)"
        )

      {:error, reason} ->
        Mix.raise("grasp.cover: cannot write #{out}: #{:file.format_error(reason)}")
    end
  end

  defp index_path(nil, root) do
    case Application.get_env(:grasp, :index_path) do
      path when is_binary(path) and path != "" -> Path.expand(path, root)
      _unset -> Path.join(root, ".grasp/index.json")
    end
  end

  defp index_path(path, root), do: Path.expand(path, root)

  defp run_suite(root, export) do
    [command | args] = Application.get_env(:grasp, :test_command, ["mix", "test"])

    {_output, status} =
      System.cmd(command, args ++ ["--cover", "--export-coverage", "grasp"],
        cd: root,
        env: [{"MIX_ENV", "test"}],
        into: IO.stream()
      )

    cond do
      not File.regular?(export) ->
        Mix.raise(
          "grasp.cover: the test run exited with status #{status} and exported no coverage"
        )

      status != 0 ->
        Mix.shell().info(
          "grasp: the test run exited with status #{status}; coverage covers what ran"
        )

      true ->
        :ok
    end
  end

  # `:cover` is one named server per VM; it is stopped afterwards so the imported data
  # does not linger in a session that goes on to do anything else. The server announces on
  # every analysis that the data is imported, once per module, so its output goes to a sink
  # rather than the terminal.
  defp import_lines(export, index, root) do
    Mix.ensure_application!(:tools)

    server =
      case :cover.start() do
        {:ok, pid} -> pid
        {:error, {:already_started, pid}} -> pid
      end

    {:ok, sink} = StringIO.open("")
    Process.group_leader(server, sink)

    try do
      case :cover.import(String.to_charlist(export)) do
        :ok -> :ok
        {:error, reason} -> Mix.raise("grasp.cover: cannot import #{export}: #{inspect(reason)}")
      end

      files = Map.new(index.modules, &{&1["name"], &1["file"]})

      :cover.imported_modules()
      |> Enum.flat_map(fn module ->
        case file_of(module, files, root) do
          nil -> []
          file -> [{file, module_lines(module)}]
        end
      end)
      |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
      |> Map.new(fn {file, maps} ->
        {file, Enum.reduce(maps, %{}, &Map.merge(&2, &1, fn _line, a, b -> a + b end))}
      end)
    after
      :cover.stop()
      StringIO.close(sink)
    end
  end

  defp module_lines(module) do
    case :cover.analyse(module, :calls, :line) do
      {:ok, counts} ->
        for {{^module, line}, count} <- counts, line > 0, into: %{}, do: {line, count}

      {:error, _reason} ->
        %{}
    end
  end

  # A module in a path only the test environment compiles has no beam here, and the
  # imported data carries no source; the index names the file every indexed module is in.
  defp file_of(module, files, root) do
    source =
      with {:module, ^module} <- Code.ensure_loaded(module),
           source when is_list(source) <- module.module_info(:compile)[:source] do
        List.to_string(source)
      else
        _unloadable -> nil
      end

    cond do
      is_binary(source) -> Path.relative_to(Path.expand(source), root)
      name = Map.get(files, inspect(module)) -> name
      true -> nil
    end
  end

  defp git_head(root) do
    case System.cmd("git", ["rev-parse", "--git-dir"], cd: root, stderr_to_stdout: true) do
      {_out, 0} ->
        case System.cmd("git", ["rev-parse", "HEAD"], cd: root) do
          {head, 0} -> String.trim(head)
          _no_head -> nil
        end

      _not_a_repository ->
        nil
    end
  end
end
