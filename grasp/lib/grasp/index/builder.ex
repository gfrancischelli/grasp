defmodule Grasp.Index.Builder do
  @moduledoc """
  Builds the index for the Mix project in the current directory and writes it as JSON.

  Runs inside the target project's Mix session (`mix grasp.index`), where the compiler,
  the project configuration and the compiled code are all at hand. It registers
  `Grasp.Index.Tracer`, forces a full recompile so every call in the project is traced
  (dependencies are compiled only if stale and filtered out by path), extracts
  definitions from every `.ex` file under `:elixirc_paths`, joins the two and writes the
  document `Grasp.Index.load/1` reads. A file an `embed_templates` pattern matches is a
  definition too, built by `Grasp.Index.Templates`, so a template is a record with calls
  of its own rather than a file the graph stops at. Git metadata is best-effort: `nil`
  when the project is not in a repository or `git` is not installed, and a file that
  cannot be read or parsed is reported and skipped rather than aborting the run. Entry
  points and module behaviours come from `Grasp.Index.EntryPoints`, which introspects the
  modules the compile just produced.

  With a `:base` git ref, `Grasp.Index.BaseRef` resolves the commit to compare against and
  `Grasp.Index.Changes` marks every record added, modified, unchanged or removed. The ref
  is resolved before the compile, so a ref no commit answers to fails in a second rather
  than after a full rebuild. Removed functions are written as records like any other, so a
  reader can see what a deleted function was, but they are not definitions this project
  holds: entry-point detection and the set of ids a call can resolve to see only the
  functions the compile produced.

  Entry-point detection runs before the records are finished, because the routes it finds
  are what `Grasp.Index.Routes` resolves a template's links and `~p` sigils against.

  `run/1` is the full build, and every stage it walks — `source_files/2`, `extract/2`,
  `Grasp.Index.Join.join/3`, `entry_points/2`, `classify/4`,
  `Grasp.Index.Resolve.resolve/2`, `document/5` — is a function of its own, because
  `Grasp.Index.Incremental` runs the same stages over the handful of files a save touched
  and has to produce records of exactly the same shape.
  """

  alias Grasp.Index.{
    BaseRef,
    Changes,
    EntryPoints,
    Extract,
    Join,
    Resolve,
    Templates,
    TestTrace,
    Tracer
  }

  @type summary :: %{
          path: String.t(),
          functions: non_neg_integer(),
          calls: non_neg_integer(),
          hidden_calls: non_neg_integer(),
          changed: non_neg_integer(),
          tests: non_neg_integer()
        }

  @type extracted :: %{
          definitions: [Extract.definition()],
          modules: [Extract.module_info()],
          embeds: [Extract.embed()],
          failures: [failure()]
        }

  @type failure :: %{file: String.t(), reason: term()}

  @type detected :: %{
          entry_points: [EntryPoints.entry()],
          behaviours: %{String.t() => [String.t()]},
          skipped: [String.t()]
        }

  @type rendered :: %{
          entry_points: [map()],
          behaviours: %{String.t() => [String.t()]},
          skipped: [String.t()]
        }

  @doc """
  Traces, extracts, joins and writes the index. `:out` defaults to `.grasp/index.json`.

  `:base` compares the project against a git ref: every record is classified by
  `Grasp.Index.Changes` and the functions the ref holds that the project no longer
  defines are written as removed records. An unresolvable ref aborts the run.

  When the project has test paths — its `:test_paths`, or `test/` when it has that
  directory, as `mix test` reads them — its tests are traced too, by
  `Grasp.Index.TestTrace`, unless `:tests` is `false`. The test files and test-only support
  files are extracted and joined as the application's files are, and their records go
  through classification and route resolution with the application's: with `:base`, a
  test file the branch changed is read at the base too, so its tests are added, modified,
  unchanged or removed as functions are, and a request a test makes reaches the route it
  names. The project block then names `"test_paths"`, the test environment's, so a reader
  knows which records are tests. A trace that fails is reported with the last lines of its
  output and leaves the index the application's alone, its classification included: a
  changed test file is classified only once its tests were indexed.
  """
  @spec run(out: String.t(), base: String.t(), tests: boolean()) :: {:ok, summary()}
  def run(opts) do
    out = Keyword.get(opts, :out, ".grasp/index.json")
    config = Mix.Project.config()
    root = File.cwd!()
    paths = Keyword.get(config, :elixirc_paths, ["lib"])

    # The test paths the base is read under, before the trace names the test environment's.
    test_paths =
      config[:test_paths] || if(File.dir?(Path.join(root, "test")), do: ["test"], else: [])

    tests? =
      Keyword.get(opts, :tests, true) and
        Enum.any?(test_paths, &File.exists?(Path.expand(&1, root)))

    base = resolve_base(root, paths, if(tests?, do: test_paths, else: []), opts[:base])
    events = trace_compile(root, paths)
    extracted = extract(root, source_files(root, paths))
    report_failures(extracted.failures)

    definitions =
      extracted.definitions ++
        Templates.definitions(root, extracted.embeds, extracted.definitions)

    functions = Join.join(definitions, events)
    detected = entry_points(config[:app], functions)
    report_skipped(detected.skipped)
    entries = Enum.map(detected.entry_points, &entry_point_json/1)

    tests = trace_tests(root, paths, functions, base_only(root, base, test_paths), tests?)
    traced = %{paths: Map.get(tests.project, "test_paths", []), files: tests.compared}

    records =
      (functions ++ tests.records)
      |> classify(base, paths, traced)
      |> Resolve.resolve(entries)

    project =
      Map.merge(
        %{"app" => to_string(config[:app]), "root" => root, "elixirc_paths" => paths},
        tests.project
      )

    document =
      document(
        records,
        extracted.modules ++ tests.modules,
        %{detected | entry_points: entries},
        project,
        git_info(root, base)
      )

    write!(out, Jason.encode!(document, pretty: true))

    {:ok,
     %{
       path: out,
       functions: length(records),
       calls: records |> Enum.map(&length(&1.calls)) |> Enum.sum(),
       hidden_calls: records |> Enum.map(&length(&1.hidden_calls)) |> Enum.sum(),
       changed: Enum.count(records, &(Map.get(&1, :change, "unchanged") != "unchanged")),
       tests: Enum.count(records, &(&1.kind == :test))
     }}
  end

  @doc """
  The project-relative `.ex` files under `paths`, sorted.

  Sorted because the order files are read in is the order records land in the document,
  and a build that shuffles its output for no reason is a build whose diffs say nothing.
  """
  @spec source_files(String.t(), [String.t()]) :: [String.t()]
  def source_files(root, paths) do
    paths
    |> Enum.flat_map(&Path.wildcard(Path.join([root, &1, "**", "*.ex"])))
    |> Enum.map(&Path.relative_to(&1, root))
    |> Enum.sort()
  end

  @doc """
  Reads and parses each project-relative file under `root` into definitions, modules and
  the template patterns those modules embed.

  A file that cannot be read or parsed contributes nothing and comes back under
  `:failures`, with the reason. Reporting it is the caller's business: a full build has a
  terminal to say so on, and an update that runs after every save has a log and a reason of
  its own to care — a file it could not read is a file whose records it must leave alone.
  """
  @spec extract(String.t(), [String.t()]) :: extracted()
  def extract(root, files) do
    files
    |> Enum.reduce({[], [], [], []}, fn relative, {definitions, modules, embeds, failures} ->
      case extract_file(Path.join(root, relative), relative) do
        {:ok, extracted} ->
          {[extracted.definitions | definitions], [extracted.modules | modules],
           [extracted.embeds | embeds], failures}

        {:error, reason} ->
          {definitions, modules, embeds, [%{file: relative, reason: reason} | failures]}
      end
    end)
    |> then(fn {definitions, modules, embeds, failures} ->
      %{
        definitions: definitions |> Enum.reverse() |> List.flatten(),
        modules: modules |> Enum.reverse() |> List.flatten(),
        embeds: embeds |> Enum.reverse() |> List.flatten(),
        failures: Enum.reverse(failures)
      }
    end)
  end

  @doc """
  Entry points and per-module behaviours for `app`, reachable from `records`.

  Only the functions the project still defines can be reached: a removed record describes
  a function the base commit had, and an entry point pointing at one would lead nowhere.
  """
  @spec entry_points(atom() | nil, [Join.function_record()]) :: detected()
  def entry_points(app, records), do: EntryPoints.detect(app, indexed_ids(records))

  defp indexed_ids(records) do
    for record <- records,
        not Map.get(record, :removed, false),
        arity <- record.arities,
        into: MapSet.new(),
        do: Join.function_id(record.module, record.name, arity)
  end

  @doc """
  Classifies `records` against `base`, the result of `Grasp.Index.BaseRef.resolve/3`.

  Without a base every record is left as it came: the caller writes a document that says
  nothing about a branch, which is what an index built with no `--base` is. `paths` are
  the project's compile paths, so a base source outside them cannot invent removed
  functions.

  `tests` names the test paths whose tests were indexed and the files under them to compare:
  the files the test trace read, and the files the base holds alone that `mix test` would
  load, as `Grasp.Index.TestTrace` judged them in the test environment. Only those are
  compared under the test paths: any other source there — a fixture project's `.ex`, a
  test file a load filter leaves out — has no record to answer to, and its base functions
  would all read as removed. A test file the branch deleted is one `mix test` would load,
  so its tests read as removed.
  """
  @spec classify(
          [Join.function_record()],
          BaseRef.resolved() | nil,
          [String.t()],
          %{paths: [String.t()], files: [String.t()]}
        ) :: [Changes.classified_record()]
  def classify(records, base, paths, tests \\ %{paths: [], files: []})

  def classify(records, nil, _paths, _tests), do: records

  def classify(records, base, paths, tests) do
    prefixes = Enum.map(tests.paths, &(String.trim_trailing(&1, "/") <> "/"))
    traced = MapSet.new(tests.files)

    compared =
      base
      |> compared_sources()
      |> Map.filter(fn {file, _source} ->
        not String.starts_with?(file, prefixes) or MapSet.member?(traced, file)
      end)

    Changes.classify(records, compared, paths ++ tests.paths)
  end

  @doc """
  Assembles the JSON document, with the string keys `Grasp.Index.load/1` reads.

  The entry points in `detected` are the JSON `entry_point_json/1` writes rather than the
  detected entries themselves, because the route sites are resolved against that same list
  before a record reaches this function. `project` and `git` are passed whole so a caller
  rewriting part of an index — the incremental update after a save — keeps the blocks the
  full build wrote rather than recomputing facts that did not change.
  """
  @spec document(
          [Changes.classified_record()],
          [Extract.module_info()],
          rendered(),
          map(),
          map() | nil
        ) ::
          map()
  def document(records, modules, detected, project, git) do
    %{
      "version" => 1,
      "generated_at" => DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
      "project" => project,
      "git" => git,
      "modules" => Enum.map(modules, &module_json(&1, detected.behaviours)),
      "functions" => Enum.map(records, &function_json/1),
      "entry_points" => detected.entry_points
    }
  end

  @doc "The JSON shape of one module, carrying the behaviours detection found for it."
  @spec module_json(Extract.module_info(), %{String.t() => [String.t()]}) :: map()
  def module_json(module, behaviours) do
    %{
      "name" => module.name,
      "file" => module.file,
      "line" => module.line,
      "behaviours" => Map.get(behaviours, module.name, [])
    }
  end

  @doc """
  The JSON shape of one function record, classified or not.

  A test's record also writes `"test"`, its describe, name and tags; no other record has one.
  """
  @spec function_json(Join.function_record() | Changes.classified_record()) :: map()
  def function_json(record) do
    %{
      "id" => record.id,
      "module" => record.module,
      "name" => Atom.to_string(record.name),
      "arity" => record.arity,
      "arities" => record.arities,
      "kind" => Atom.to_string(record.kind),
      "file" => record.file,
      "span" => %{"start_line" => record.span.start_line, "end_line" => record.span.end_line},
      "source" => record.source,
      "calls" => Enum.map(record.calls, &Resolve.call_json/1),
      "hidden_calls" =>
        Enum.map(
          record.hidden_calls,
          &%{"target" => &1.target, "kind" => Atom.to_string(&1.kind), "line" => &1.line}
        ),
      "route_sites" =>
        record |> Map.get(:route_sites, []) |> Enum.map(&Resolve.route_site_json/1),
      "change" => Map.get(record, :change, "unchanged"),
      "base_source" => Map.get(record, :base_source),
      "removed" => Map.get(record, :removed, false)
    }
    |> put_test(Map.get(record, :test))
  end

  defp put_test(json, nil), do: json

  defp put_test(json, test),
    do:
      Map.put(json, "test", %{
        "describe" => test.describe,
        "name" => test.name,
        "tags" => test.tags
      })

  @doc "The JSON shape of one entry point."
  @spec entry_point_json(EntryPoints.entry()) :: map()
  def entry_point_json(entry),
    do: %{
      "kind" => entry.kind,
      "label" => entry.label,
      "target" => entry.target,
      "meta" => entry.meta
    }

  defp report_failures(failures) do
    for %{file: file, reason: reason} <- failures do
      Mix.shell().error("grasp: skipping #{file}: #{inspect(reason)}")
    end

    :ok
  end

  defp report_skipped([]), do: :ok

  defp report_skipped(views) do
    Mix.shell().info(
      "grasp: #{length(views)} live routes skipped (view has no indexed functions): " <>
        Enum.join(views, ", ")
    )
  end

  # Git metadata for `root`, or `nil` outside a repository. `base` may be `nil`.
  defp git_info(root, base) do
    with {head, 0} <- git(["rev-parse", "HEAD"], root),
         {branch, 0} <- git(["rev-parse", "--abbrev-ref", "HEAD"], root) do
      %{
        "head" => String.trim(head),
        "branch" => String.trim(branch),
        "base_ref" => base && base.base_ref,
        "base_sha" => base && base.base_sha
      }
    else
      _ -> nil
    end
  end

  # Every file the diff touched, under the contents the base had for it. A file the base
  # did not have maps to an empty string rather than being left out: without an entry the
  # classifier cannot tell a file this branch added from one it never touched, and the new
  # file's functions would read as untouched instead of added.
  defp compared_sources(base),
    do: Map.new(base.files, &{&1, Map.get(base.base_sources, &1, "")})

  defp resolve_base(_root, _paths, _test_paths, nil), do: nil

  defp resolve_base(root, paths, test_paths, ref) do
    case BaseRef.resolve(root, ref, paths: paths, test_paths: test_paths) do
      {:ok, base} -> base
      {:error, message} -> Mix.raise("grasp.index: #{message}")
    end
  end

  # The event table is drained rather than replaced, and the tracer installed only if it is
  # not already there: a full build run from an IEx session that has a `Grasp.Reindexer`
  # in it shares both with that process, and deleting the table would stop live reindexing
  # with nothing to say why. The compiler options are still put back, so a build that
  # installed the tracer itself leaves the VM as it found it.
  defp trace_compile(root, paths) do
    previous_tracers = Code.get_compiler_option(:tracers)
    previous_parser = Code.get_compiler_option(:parser_options)
    Tracer.start()
    Tracer.take_events()
    Tracer.install()

    try do
      Mix.Task.rerun("compile", ["--force"])
      roots = Enum.map(paths, &(Path.expand(&1, root) <> "/"))

      Tracer.take_events()
      |> Enum.map(&%{&1 | file: Path.expand(&1.file, root)})
      |> Enum.filter(fn event -> Enum.any?(roots, &String.starts_with?(event.file, &1)) end)
      |> Enum.map(&%{&1 | file: Path.relative_to(&1.file, root)})
    after
      Code.put_compiler_option(:tracers, previous_tracers)
      Code.put_compiler_option(:parser_options, previous_parser)
    end
  end

  @no_tests %{records: [], modules: [], compared: [], project: %{}}

  # How many lines of a failed trace's output are printed: enough for the compiler's error,
  # which comes last, without the compile log of every dependency a cold build prints first.
  @failure_lines 40

  # The files under the test paths the base holds and the tree does not: whether `mix test`
  # would load one is for the test environment to judge.
  defp base_only(_root, nil, _test_paths), do: []

  defp base_only(root, base, test_paths) do
    prefixes = Enum.map(test_paths, &(String.trim_trailing(&1, "/") <> "/"))

    Enum.filter(base.files, fn file ->
      String.starts_with?(file, prefixes) and not File.exists?(Path.join(root, file))
    end)
  end

  # The application's ids are handed to the join, because a test's calls reach out of the
  # files being joined: a hidden call into an application function is kept only when the
  # join knows the index holds that function.
  defp trace_tests(root, paths, functions, candidates, true) do
    Mix.shell().info("grasp: tracing tests (MIX_ENV=test)")

    case TestTrace.run(root, paths, candidates: candidates) do
      {:ok, trace} ->
        extracted = extract(root, trace.files)
        report_failures(extracted.failures)

        %{
          records:
            Join.join(extracted.definitions, trace.events, known_ids: indexed_ids(functions)),
          modules: extracted.modules,
          compared: trace.files ++ trace.selected,
          project: %{"test_paths" => trace.test_paths}
        }

      {:error, output} ->
        tail =
          output |> String.trim_trailing() |> String.split("\n") |> Enum.take(-@failure_lines)

        Mix.shell().error("grasp: tests not indexed: #{Enum.join(tail, "\n")}")
        @no_tests
    end
  end

  defp trace_tests(_root, _paths, _functions, _candidates, false), do: @no_tests

  defp extract_file(file, relative) do
    case File.read(file) do
      {:ok, source} -> Extract.extract(source, relative)
      {:error, reason} -> {:error, reason}
    end
  end

  defp write!(out, json) do
    with :ok <- File.mkdir_p(Path.dirname(out)),
         :ok <- File.write(out, json) do
      :ok
    else
      {:error, reason} ->
        Mix.raise("grasp.index: cannot write #{out}: #{:file.format_error(reason)}")
    end
  end

  # Captured on its own: git writes warnings to stderr and still exits 0, and a warning
  # folded into stdout would be read as the commit the project is sitting on. Outside a
  # repository git's complaint is discarded rather than shown: the block is best-effort.
  defp git(args, root) do
    case System.cmd("git", ["rev-parse", "--git-dir"], cd: root, stderr_to_stdout: true) do
      {_out, 0} -> System.cmd("git", args, cd: root)
      _not_a_repository -> {"", 1}
    end
  rescue
    ErlangError -> {"", 1}
  end
end
