defmodule Mix.Tasks.Grasp.Cover do
  @shortdoc "Runs the test suite under cover and writes .grasp/coverage.json"

  @moduledoc """
  Runs the project's test suite under Mix's cover tool and writes the coverage document the
  Grasp viewer and MCP server read (see `Grasp.Coverage`).

      mix grasp.cover [--out PATH] [--index PATH]

  The suite runs exactly as the project runs it: the command is `:grasp, :test_command`,
  `["mix", "test"]` unless configured, started in the project root with `MIX_ENV=test` over
  the environment this task runs in and `--cover` added, its output streamed to the
  terminal. The export lands where the project's `:test_coverage` config puts it: in its
  `:output` directory (`cover` unless set), named by its `:export` when it sets one, and
  otherwise `grasp`, which the task asks for with `--export-coverage grasp`. A run whose
  tests fail still exports what ran, so a non-zero exit is reported and the coverage is
  written from the export; a run that leaves no export aborts the task with the command's
  status. An export an earlier run left behind is removed before the suite starts, so the
  document never describes a run other than this one. The export itself is left where Mix
  wrote it.

  ## What the coverage describes

  The counts are the suite's, run on the code in the project root, so a function keeps its
  entry only when its indexed `source` is the text its file holds in the project root at its
  span (see `Grasp.Coverage.in_checkout/3`). A function whose file is missing there or
  differs gets no entry, and the task prints how many it skips: an index that lags the files
  (run `mix grasp.index`), or one built for another tree, such as a pull request's worktree,
  keeps only the functions the two hold alike. The check reads the files after the run, so
  an edit saved while the suite runs, once it has compiled, is not caught: the counts
  describe the text compiled before it.

  An umbrella's apps each export their own coverage, so the task refuses to run at an
  umbrella root: run it inside the app.

  ## Attribution

  The export is imported into `:cover` in this task's own process: analysing imported data
  needs no cover-compiled module, so Grasp is never needed in the project's test
  environment. `:cover` counts by module and line, and a module can hold code whose lines
  are another file's — a template compiled into it, a macro's `quote location: :keep`. Each
  count is therefore attributed to the one compiled function whose code carries that line,
  read from the debug info of the beam the suite ran (the project's test build):

    * code the compiler marks as another file's (`@file`, `location: :keep`, templates
      embedded from their own files) is left out by `:cover` itself;
    * a line that more than one function's code carries — a template compiled from a
      string whose lines overlap the module's own — is attributed to none of them, so its
      count is dropped rather than credited to the wrong function;
    * a module whose test beam has no readable debug info contributes nothing.

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
  @export_name "grasp"

  @impl Mix.Task
  def run(args) do
    {opts, _positional, invalid} = OptionParser.parse(args, strict: @switches)

    if invalid != [] do
      Mix.raise("grasp.cover: unknown options #{inspect(Enum.map(invalid, &elem(&1, 0)))}")
    end

    if Mix.Project.umbrella?() do
      Mix.raise(
        "grasp.cover: an umbrella's apps each export their own coverage; " <>
          "run mix grasp.cover inside the app"
      )
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

    {export, export_args} = export(root)
    File.rm(export)
    run_suite(root, export, export_args)

    {document, skipped} =
      index
      |> Grasp.Coverage.build(import_counts(export, test_ebin()), %{
        generated_at: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
        git_head: git_head(root)
      })
      |> Grasp.Coverage.in_checkout(index, root)

    Mix.shell().info(
      "grasp: skipped #{skipped} #{if skipped == 1, do: "function", else: "functions"} " <>
        "whose indexed source differs from the checkout"
    )

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

  # `mix test` merges the project's `:test_coverage` over the command line's
  # `--export-coverage`, so an `:export` the project sets is the name the file gets.
  defp export(root) do
    config = Mix.Project.config()[:test_coverage] || []
    output = Path.expand(config[:output] || "cover", root)

    case config[:export] do
      nil ->
        {Path.join(output, @export_name <> ".coverdata"), ["--export-coverage", @export_name]}

      name ->
        {Path.join(output, "#{name}.coverdata"), []}
    end
  end

  defp run_suite(root, export, export_args) do
    [command | args] = Application.get_env(:grasp, :test_command, ["mix", "test"])

    {_output, status} =
      System.cmd(command, args ++ ["--cover" | export_args],
        cd: root,
        env: [{"MIX_ENV", "test"}],
        into: IO.stream()
      )

    cond do
      not File.regular?(export) ->
        Mix.raise(
          "grasp.cover: the test run exited with status #{status} and exported no coverage " <>
            "to #{Path.relative_to(export, root)}"
        )

      status != 0 ->
        Mix.shell().info(
          "grasp: the test run exited with status #{status}; coverage covers what ran"
        )

      true ->
        :ok
    end
  end

  # The directory the suite's beams are in: the project's compile path as the test
  # environment resolves it, which is how the suite resolved it.
  defp test_ebin do
    previous = Mix.env()
    Mix.env(:test)

    try do
      Mix.Project.compile_path()
    after
      Mix.env(previous)
    end
  end

  # `:cover` is one named server per VM, and importing into one that already holds data
  # would add this run's counts to it. The server announces on every analysis that the data
  # is imported, once per module, so its output goes to a sink rather than the terminal.
  defp import_counts(export, ebin) do
    Mix.ensure_application!(:tools)

    server =
      case :cover.start() do
        {:ok, pid} ->
          pid

        {:error, {:already_started, _pid}} ->
          Mix.raise("grasp.cover: :cover is already running in this VM")
      end

    {:ok, sink} = StringIO.open("")
    Process.group_leader(server, sink)

    try do
      case :cover.import(String.to_charlist(export)) do
        :ok -> :ok
        {:error, reason} -> Mix.raise("grasp.cover: cannot import #{export}: #{inspect(reason)}")
      end

      for module <- :cover.imported_modules(),
          owners <- [owners(module, ebin)],
          owners != %{},
          {:ok, counts} <- [:cover.analyse(module, :calls, :line)],
          {{^module, line}, count} <- counts,
          {name, arity} <- List.wrap(Map.get(owners, line)),
          reduce: %{} do
        acc ->
          key = {inspect(module), Atom.to_string(name), arity}
          Map.update(acc, key, %{line => count}, &Map.put(&1, line, count))
      end
    after
      :cover.stop()
      StringIO.close(sink)
    end
  end

  # Line → the one function whose code in the module's own file carries it. The forms
  # follow `-file` attributes: the first names the module's file, and a function after one
  # naming another file is that file's code, which `:cover` does not count. A line two
  # functions carry has no owner.
  defp owners(module, ebin) do
    beam = ebin |> Path.join(Atom.to_string(module) <> ".beam") |> String.to_charlist()

    with {:ok, {^module, [debug_info: {:debug_info_v1, backend, data}]}} <-
           :beam_lib.chunks(beam, [:debug_info]),
         {:ok, forms} <- backend.debug_info(:erlang_v1, module, data, []) do
      {_file, carriers} =
        Enum.reduce(forms, {nil, %{}}, fn
          {:attribute, _anno, :file, {file, _line}}, {nil, carriers} ->
            {{file, file}, carriers}

          {:attribute, _anno, :file, {file, _line}}, {{main, _current}, carriers} ->
            {{main, file}, carriers}

          {:function, _anno, name, arity, _clauses} = form, {{main, main}, carriers} ->
            lines = :erl_parse.fold_anno(&[:erl_anno.line(&1) | &2], [], form)

            carriers =
              for line <- Enum.uniq(lines), line > 0, reduce: carriers do
                carriers -> Map.update(carriers, line, [{name, arity}], &[{name, arity} | &1])
              end

            {{main, main}, carriers}

          _form, state ->
            state
        end)

      for {line, [owner]} <- carriers, into: %{}, do: {line, owner}
    else
      _no_debug_info -> %{}
    end
  end

  defp git_head(root) do
    case System.cmd("git", ["rev-parse", "--git-dir"], cd: root, stderr_to_stdout: true) do
      {_out, 0} ->
        case System.cmd("git", ["rev-parse", "HEAD"], cd: root, stderr_to_stdout: true) do
          {head, 0} -> String.trim(head)
          _no_head -> nil
        end

      _not_a_repository ->
        nil
    end
  end
end
