defmodule Grasp.Index do
  @moduledoc """
  In-memory view of an index document written by `mix grasp.index`.

  Records keep the document's string keys so the viewer and the MCP server render the
  same shape they would read from disk. Functions are keyed by id (`"Mod.fun/arity"`);
  a definition with default arguments is also reachable through each extra arity it
  defines. Callers are derived at load time by inverting every function's calls and
  hidden calls but its `double` calls, which stand in for code rather than run it, and
  entry points are indexed by the function they reach. Search ranks an exact id first,
  then ids containing the query, then ids whose characters contain the query as a
  subsequence, so `"walcre"` still finds `MyApp.Wallets.credit/3`.

  Module records are keyed by name at load, beside the document's own list of them, and
  each module's moduledoc summary is read once there, so a card or a sidebar row asking for
  one never parses the text again. `fetch_record/2` answers a function id or a module name,
  which is what a card's id is.

  Every index built carries a `generation` no other index built in the VM carries, so a
  holder of answers taken against one can tell whether it still has that index without
  comparing their contents.

  The struct can be large — about 10 MB of JSON for a 500-file project — so hold it once,
  for instance in `:persistent_term`, rather than copying it into per-process state.
  """

  alias Grasp.Index.Join

  # One bound for both walks: a Tests row counted by `tests_for/3` opens `path_back/4`, which
  # has to reach as far.
  @max_hops 4

  # The longest summary `moduledoc_summary/2` answers, its ellipsis included.
  @summary_length 300

  defstruct version: 1,
            generation: 0,
            generated_at: nil,
            project: %{},
            git: nil,
            modules: [],
            modules_by_name: %{},
            moduledoc_summaries: %{},
            entry_points: [],
            functions: %{},
            aliases: %{},
            callers: %{},
            entry_points_by_target: %{},
            tests: [],
            tests_by_module: %{},
            untested: [],
            changed_tests: %{},
            test_review: []

  @type function_record :: %{required(String.t()) => term()}
  @type module_record :: %{required(String.t()) => term()}
  @type t :: %__MODULE__{
          version: pos_integer(),
          generation: non_neg_integer(),
          generated_at: String.t() | nil,
          project: map(),
          git: map() | nil,
          modules: [map()],
          modules_by_name: %{String.t() => module_record()},
          moduledoc_summaries: %{String.t() => String.t()},
          entry_points: [map()],
          functions: %{String.t() => function_record()},
          aliases: %{String.t() => String.t()},
          callers: %{String.t() => [String.t()]},
          entry_points_by_target: %{String.t() => [map()]},
          tests: [test_module()],
          tests_by_module: %{String.t() => [String.t()]},
          untested: [String.t()],
          changed_tests: %{String.t() => [String.t()]},
          test_review: [test_mark()]
        }

  @typedoc """
  A test the branch added or modified that the review marks: `:weakened` with the reasons
  `Grasp.TestReview.review/1` gives, or `:asserts_nothing` with none.
  """
  @type test_mark :: %{
          id: String.t(),
          mark: :weakened | :asserts_nothing,
          reasons: [String.t()]
        }

  @doc "Reads and decodes an index document from `path`."
  @spec load(Path.t()) :: {:ok, t()} | {:error, term()}
  def load(path) do
    with {:ok, binary} <- File.read(path),
         {:ok, document} <- Jason.decode(binary) do
      from_document(document)
    end
  end

  @doc """
  Builds the index from a decoded document (string keys).

  Anything but a version-1 document carrying a list of functions is rejected with
  `{:error, {:unsupported_document, version}}`, and a functions list holding something
  that is not a record with `{:error, {:invalid_record, index}}`, so `load/1` reports a
  document it cannot read as data instead of raising on its shape.
  """
  @spec from_document(term()) ::
          {:ok, t()} | {:error, {:unsupported_document, term()} | {:invalid_record, term()}}
  def from_document(%{"version" => 1, "functions" => records} = document) when is_list(records) do
    case Enum.find_index(records, &(not is_map(&1))) do
      nil -> {:ok, build(document, records)}
      index -> {:error, {:invalid_record, index}}
    end
  end

  def from_document(%{} = document),
    do: {:error, {:unsupported_document, document["version"]}}

  def from_document(_other), do: {:error, {:unsupported_document, nil}}

  defp build(document, records) do
    functions = Map.new(records, &{&1["id"], &1})

    # A removed record carries the arities the base declared, which can collide with a live
    # definition's: the live one is written last so it wins the key, and a call site opens
    # the function that still exists rather than the card for its deleted namesake.
    {removed, live} = Enum.split_with(records, &(&1["removed"] == true))

    aliases =
      for record <- removed ++ live, arity <- arities(record), into: %{} do
        {Join.function_id(record["module"], record["name"], arity), record["id"]}
      end

    callers =
      records
      |> Enum.flat_map(fn record ->
        for call <- targets(record), is_map(call), call["kind"] != "double" do
          {Map.get(aliases, call["target"], call["target"]), record["id"]}
        end
      end)
      |> Enum.uniq()
      |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
      |> Map.new(fn {target, callers} -> {target, Enum.sort(callers)} end)

    entry_points =
      document["entry_points"]
      |> List.wrap()
      |> Enum.filter(&(is_map(&1) and is_binary(&1["target"])))

    entry_points_by_target =
      Enum.group_by(entry_points, &Map.get(aliases, &1["target"], &1["target"]))

    modules = Enum.filter(List.wrap(document["modules"]), &is_map/1)

    # A removed module record can share its name with a module the head defines, as a
    # removed function can share an id: the defined one is written last and wins the key.
    modules_by_name =
      modules
      |> Enum.sort_by(&(&1["removed"] == true), :desc)
      |> Map.new(&{&1["name"], &1})

    index = %__MODULE__{
      version: 1,
      generation: :erlang.unique_integer([:positive, :monotonic]),
      generated_at: document["generated_at"],
      project: document["project"] || %{},
      git: document["git"],
      modules: Enum.reject(modules, &(&1["removed"] == true)),
      modules_by_name: modules_by_name,
      moduledoc_summaries: summaries(modules_by_name),
      entry_points: entry_points,
      functions: functions,
      aliases: aliases,
      callers: callers,
      entry_points_by_target: entry_points_by_target
    }

    tests_by_module =
      records
      |> Enum.filter(&(&1["kind"] == "test" and &1["removed"] != true))
      |> Enum.group_by(& &1["module"], & &1["id"])

    index = %{index | tests: test_modules(index), tests_by_module: tests_by_module}

    # The branch's changes are known once the records are, and they are few beside the
    # codebase: walking back from each once here answers every render of the review.
    reach = Map.new(changed_application_functions(index), &{&1["id"], tests_for(index, &1["id"])})

    changed_tests =
      for {id, tests} <- reach,
          changed = for(%{test: test} <- tests, changed_test?(index, test), do: test),
          changed != [],
          into: %{},
          do: {id, changed}

    untested = for {id, []} <- reach, do: id

    # Only a test the branch added or modified can be marked, so only those are parsed.
    test_review =
      for record <- changed_test_records(index),
          verdict = Grasp.TestReview.review(record),
          verdict != :ok do
        case verdict do
          {:weakened, reasons} -> %{id: record["id"], mark: :weakened, reasons: reasons}
          :asserts_nothing -> %{id: record["id"], mark: :asserts_nothing, reasons: []}
        end
      end

    %{
      index
      | untested: Enum.sort(untested),
        changed_tests: changed_tests,
        test_review: Enum.sort_by(test_review, & &1.id)
    }
  end

  defp arities(record) do
    case record["arities"] do
      arities when is_list(arities) -> arities
      _ -> List.wrap(record["arity"])
    end
  end

  defp targets(record) do
    Enum.filter(record["calls"] || [], &is_map/1) ++
      Enum.filter(record["hidden_calls"] || [], &is_map/1)
  end

  @doc "Fetches a function by id, following default-argument arities to the definition."
  @spec fetch_function(t(), String.t()) :: {:ok, function_record()} | :error
  def fetch_function(%__MODULE__{} = index, id),
    do: Map.fetch(index.functions, resolve(index, id))

  @doc """
  Ids of the functions that call `id`, sorted.

  A test doubling `id` through a Mox mock does not call it — the mock answers in its
  place — so a call of kind `double` makes no caller here, nor anywhere the callers are
  walked: `tests_for/3`, `path_back/4`, `untested_changes/1` and `changed_tests/2`.
  `callees/3` keeps the double unless told not to, since the test's card draws it.
  """
  @spec callers(t(), String.t()) :: [String.t()]
  def callers(%__MODULE__{} = index, id), do: Map.get(index.callers, resolve(index, id), [])

  @doc """
  Ids the function calls (visible and hidden), resolved and sorted.

  A returned id may be outside the index — anything in the standard library or a
  dependency is a call target but never a definition — so `fetch_function/2` returns
  `:error` for it. The targets of `double` calls are included unless `doubles: false` is
  given, and then an id stays only when the function also calls it outright; `doubles/2`
  answers those apart.
  """
  @spec callees(t(), String.t(), keyword()) :: [String.t()]
  def callees(%__MODULE__{} = index, id, opts \\ []) do
    doubles? = Keyword.get(opts, :doubles, true)

    case fetch_function(index, id) do
      {:ok, record} ->
        record
        |> targets()
        |> Enum.filter(&(doubles? or &1["kind"] != "double"))
        |> Enum.map(&resolve(index, &1["target"]))
        |> Enum.uniq()
        |> Enum.sort()

      :error ->
        []
    end
  end

  @typedoc "A function a test's Mox mock stands in for, with the mock and its behaviour."
  @type double :: %{String.t() => String.t()}

  @doc """
  The functions `id`'s Mox doubles stand in for, each as `%{"target", "behaviour", "mock"}`,
  sorted by target and deduplicated. A double does not run the code it names, so these are
  not calls; `callees/3` with `doubles: false` leaves them out.
  """
  @spec doubles(t(), String.t()) :: [double()]
  def doubles(%__MODULE__{} = index, id) do
    case fetch_function(index, id) do
      {:ok, record} ->
        for %{"kind" => "double", "double" => %{"mock" => mock, "behaviour" => behaviour}} =
              call <- targets(record),
            uniq: true do
          %{"target" => resolve(index, call["target"]), "behaviour" => behaviour, "mock" => mock}
        end
        |> Enum.sort_by(&{&1["target"], &1["behaviour"], &1["mock"]})

      :error ->
        []
    end
  end

  @doc "All function records, sorted by id."
  @spec functions(t()) :: [function_record()]
  def functions(%__MODULE__{} = index),
    do: index.functions |> Map.values() |> Enum.sort_by(& &1["id"])

  @doc "Functions defined in `module`, in source order."
  @spec functions_in_module(t(), String.t()) :: [function_record()]
  def functions_in_module(%__MODULE__{} = index, module) do
    index.functions
    |> Map.values()
    |> Enum.filter(&(&1["module"] == module))
    |> Enum.sort_by(&{&1["span"]["start_line"], &1["id"]})
  end

  @doc """
  The module records of the modules the project defines, in document order and as stored.

  A removed module record describes a module only the base holds, so it is left out here and
  reached by name through `fetch_module/2`, `fetch_record/2` and `changed_modules/1`.
  """
  @spec modules(t()) :: [map()]
  def modules(%__MODULE__{} = index), do: index.modules

  @doc "Fetches a module record by the module's name."
  @spec fetch_module(t(), String.t()) :: {:ok, module_record()} | :error
  def fetch_module(%__MODULE__{} = index, name), do: Map.fetch(index.modules_by_name, name)

  @doc """
  Fetches the record a card's id names: a function by its id, as `fetch_function/2` does, or
  a module by its name. A function id always ends in `/arity` and a module name never does,
  so the two never answer to the same id.
  """
  @spec fetch_record(t(), String.t()) :: {:ok, function_record() | module_record()} | :error
  def fetch_record(%__MODULE__{} = index, id) do
    case fetch_function(index, id) do
      {:ok, record} -> {:ok, record}
      :error -> fetch_module(index, id)
    end
  end

  @doc "The module records whose moduledoc is `added`, `modified` or `removed`, sorted by name."
  @spec changed_modules(t()) :: [module_record()]
  def changed_modules(%__MODULE__{} = index) do
    index.modules_by_name
    |> Map.values()
    |> Enum.filter(&(&1["change"] in ["added", "modified", "removed"]))
    |> Enum.sort_by(& &1["name"])
  end

  @doc """
  The first paragraph of a module's moduledoc as plain text, or `nil` for a module without
  moduledoc text.

  The paragraph runs up to the first blank line. Markdown's heading, emphasis and code
  markers are dropped, a link or an image reads as its text, and every run of whitespace,
  line breaks included, reads as one space; a summary longer than #{@summary_length}
  characters is cut to that length, its last one an ellipsis.
  """
  @spec moduledoc_summary(t(), String.t()) :: String.t() | nil
  def moduledoc_summary(%__MODULE__{} = index, name), do: Map.get(index.moduledoc_summaries, name)

  defp summaries(modules_by_name) do
    for {name, %{"doc" => %{"text" => text}}} <- modules_by_name,
        is_binary(text),
        summary = summary(text),
        summary != "",
        into: %{},
        do: {name, summary}
  end

  # A code span keeps its text as written, `__MODULE__` included; outside one, `*` and an
  # underscore that opens or closes a word are emphasis.
  defp plain("`" <> _ = code), do: String.trim(code, "`")

  defp plain(text),
    do:
      text
      |> String.replace("*", "")
      |> String.replace(~r/(?<![[:alnum:]])_+|_+(?![[:alnum:]])/u, "")

  defp summary(text) do
    summary =
      text
      |> String.split(~r/\n[ \t]*\n/, parts: 2)
      |> hd()
      |> String.replace(~r/^[ \t]*\#{1,6}[ \t]+/m, "")
      |> String.replace(~r/!?\[([^\]]*)\]\([^)]*\)/, "\\1")
      |> then(&Regex.split(~r/`+[^`]*`+/, &1, include_captures: true))
      |> Enum.map_join(&plain/1)
      |> String.replace(~r/\s+/u, " ")
      |> String.trim()

    if String.length(summary) > @summary_length,
      do: String.trim_trailing(String.slice(summary, 0, @summary_length - 1)) <> "…",
      else: summary
  end

  @doc """
  Entry-point records as stored in the document.

  A record that is not a map naming a target is dropped when the document is read, so the
  list is the same one `entry_points_for/2` was indexed from and a caller rendering it
  never has to guard the shape.
  """
  @spec entry_points(t()) :: [map()]
  def entry_points(%__MODULE__{} = index), do: index.entry_points

  @doc """
  Entry points reaching `function_id`, in document order.

  An entry point names its target the way the source does, so a route pointing at a
  default-argument arity is grouped under the definition it resolves to and found by
  either id. A function no entry point names returns `[]`.
  """
  @spec entry_points_for(t(), String.t()) :: [map()]
  def entry_points_for(%__MODULE__{} = index, function_id),
    do: Map.get(index.entry_points_by_target, resolve(index, function_id), [])

  @doc """
  Functions whose `change` names one of the three the reader reviews — `"added"`,
  `"modified"` or `"removed"` — sorted by id.

  A record with no `change` key at all is not changed: every document this tool writes
  carries the key, and requiring it keeps a hand-made or trimmed document from reporting
  its whole codebase as a pull request.
  """
  @spec changed_functions(t()) :: [function_record()]
  def changed_functions(%__MODULE__{} = index) do
    index |> functions() |> Enum.filter(&(&1["change"] in ~w(added modified removed)))
  end

  @doc """
  The application functions the branch added or modified that no test reaches within
  `tests_for/3`'s default bound, sorted by id.

  A function counts when `changed_functions/1` lists it as added or modified, it is not a
  test or a setup, and its file lies outside the project's `test_paths`. A removed function
  has no body left for a test to reach, so it never counts. An index built without a base
  ref marks no function added or modified and answers `[]`. The list is computed once, when
  the index is built from its document.
  """
  @spec untested_changes(t()) :: [function_record()]
  def untested_changes(%__MODULE__{} = index),
    do: Enum.map(index.untested, &Map.fetch!(index.functions, &1))

  @doc """
  The tests the branch added or modified that reach the changed application
  function `id` within `tests_for/3`'s default bound, nearest first and then by id.

  The functions answered for are `untested_changes/1`'s: added or modified, not a test or a
  setup, outside the project's `test_paths`. Any other id, and a changed function no changed
  test reaches, answers `[]`. Like `untested_changes/1`, the answer is computed once, when
  the index is built from its document.
  """
  @spec changed_tests(t(), String.t()) :: [function_record()]
  def changed_tests(%__MODULE__{} = index, id) do
    index.changed_tests |> Map.get(id, []) |> Enum.map(&Map.fetch!(index.functions, &1))
  end

  @doc """
  The ids of the tests the branch added or modified, sorted: every record of kind `"test"`
  that `changed_functions/1` lists as added or modified and that is not removed — the tests
  `mix grasp.test --changed` runs.
  """
  @spec changed_test_ids(t()) :: [String.t()]
  def changed_test_ids(%__MODULE__{} = index),
    do: Enum.map(changed_test_records(index), & &1["id"])

  @doc """
  The modified tests whose assertions the branch weakened and the added tests that assert
  nothing, sorted by id, as `Grasp.TestReview.review/1` marks them: `:weakened` with its
  reasons, `:asserts_nothing` with none. Only the tests `changed_test_ids/1` lists are
  reviewed, so an index built without a base ref answers `[]`. The list is computed once,
  when the index is built from its document.
  """
  @spec test_review(t()) :: [test_mark()]
  def test_review(%__MODULE__{} = index), do: index.test_review

  defp changed_test_records(index) do
    for %{"kind" => "test", "change" => change} = record <- changed_functions(index),
        change in ~w(added modified) and record["removed"] != true,
        do: record
  end

  defp changed_application_functions(index) do
    index
    |> changed_functions()
    |> Enum.filter(fn record ->
      record["change"] in ~w(added modified) and record["removed"] != true and
        not test_side?(index, record)
    end)
  end

  defp changed_test?(index, id),
    do:
      match?(
        %{"kind" => "test", "change" => change} when change in ~w(added modified),
        index.functions[id]
      )

  @typedoc """
  One test module as the sidebar lists it: its name, the file it is written in, its setup
  callbacks in source order, its tests grouped under their `describe` — `nil` for the tests
  written outside any — each group placed where its first test is, its tests in source
  order, and its helpers: every other function it defines, in source order.
  """
  @type test_module :: %{
          module: String.t(),
          file: String.t(),
          setups: [function_record()],
          describes: [{String.t() | nil, [function_record()]}],
          helpers: [function_record()]
        }

  @doc """
  Every module of the test suite, sorted by file and then by name.

  A module belongs to the suite when it holds a test or a setup record — a record of kind
  `"test"` or `"setup"` — or when the file it is written in lies under the project's
  `test_paths`, which is where a case template or a factory module lives. Whatever else such
  a module defines is one of its helpers. An index built without tests returns `[]`. The
  list is computed once, when the index is built from its document.
  """
  @spec tests(t()) :: [test_module()]
  def tests(%__MODULE__{} = index), do: index.tests

  defp test_modules(index) do
    records =
      index.functions
      |> Map.values()
      |> Enum.sort_by(&{&1["span"]["start_line"], &1["id"]})
      |> Enum.group_by(& &1["module"])

    files =
      for module <- index.modules, test_file?(index, module["file"]), into: %{} do
        {module["name"], module["file"]}
      end

    suite =
      for {module, module_records} <- records,
          Enum.any?(module_records, &(&1["kind"] in ["test", "setup"])),
          into: files,
          do: {module, files[module] || hd(module_records)["file"]}

    suite
    |> Enum.map(fn {module, file} ->
      module_records = Map.get(records, module, [])
      {setups, rest} = Enum.split_with(module_records, &(&1["kind"] == "setup"))
      {tests, helpers} = Enum.split_with(rest, &(&1["kind"] == "test"))

      %{
        module: module,
        file: file,
        setups: setups,
        describes: group_in_order(tests, &get_in(&1, ["test", "describe"])),
        helpers: helpers
      }
    end)
    |> Enum.sort_by(&{&1.file, &1.module})
  end

  # Enum.group_by loses the order the groups first appear in, which is the order the file
  # reads in; this keeps it, and each group's records in the order they arrived.
  defp group_in_order(records, key_fun) do
    records
    |> Enum.reduce({[], %{}}, fn record, {keys, groups} ->
      key = key_fun.(record)
      keys = if Map.has_key?(groups, key), do: keys, else: [key | keys]
      {keys, Map.update(groups, key, [record], &[record | &1])}
    end)
    |> then(fn {keys, groups} ->
      keys |> Enum.reverse() |> Enum.map(&{&1, Enum.reverse(Map.fetch!(groups, &1))})
    end)
  end

  @typedoc "A test reaching a function, and the number of call edges between them."
  @type reach :: %{test: String.t(), hops: pos_integer()}

  @doc """
  The tests that reach `id` within `max_hops` call edges, nearest first and then by id.

  The walk goes backwards from the function over its callers, breadth first, through any
  record — application functions, helpers, tests and setups alike, `route` and `enqueue`
  edges included, `double` edges not — visiting each record once. A test calling `id`
  directly is one hop away. A test record met on the way is collected at the hop it is
  first met; a setup met on the way counts for every test of its module at the setup's
  hop, unless that test is nearer by another path. A removed test or setup runs nothing, so
  it is never collected and credits no test. An id the index does not define, or a function
  no test reaches, answers `[]`.
  """
  @spec tests_for(t(), String.t(), non_neg_integer()) :: [reach()]
  def tests_for(%__MODULE__{} = index, id, max_hops \\ @max_hops) do
    start = resolve(index, id)

    if Map.has_key?(index.functions, start) do
      index
      |> walk_back([start], MapSet.new([start]), 1, max_hops, %{})
      |> Enum.map(fn {test, hops} -> %{test: test, hops: hops} end)
      |> Enum.sort_by(&{&1.hops, &1.test})
    else
      []
    end
  end

  defp walk_back(_index, [], _visited, _hop, _max_hops, found), do: found
  defp walk_back(_index, _frontier, _visited, hop, max_hops, found) when hop > max_hops, do: found

  defp walk_back(index, frontier, visited, hop, max_hops, found) do
    {next, visited, found} =
      Enum.reduce(frontier, {[], visited, found}, fn id, acc ->
        index.callers
        |> Map.get(id, [])
        |> Enum.reduce(acc, fn caller, {next, visited, found} ->
          if MapSet.member?(visited, caller) do
            {next, visited, found}
          else
            {[caller | next], MapSet.put(visited, caller), meet(index, caller, hop, found)}
          end
        end)
      end)

    walk_back(index, next, visited, hop + 1, max_hops, found)
  end

  defp meet(index, id, hop, found) do
    case index.functions[id] do
      # A removed test runs nothing, whatever calls the base gave it.
      %{"removed" => true} ->
        found

      %{"kind" => "test"} ->
        Map.put_new(found, id, hop)

      %{"kind" => "setup", "module" => module} ->
        index.tests_by_module
        |> Map.get(module, [])
        |> Enum.reduce(found, &Map.put_new(&2, &1, hop))

      _other ->
        found
    end
  end

  @doc """
  The ids from `id` back to `test_id` along a shortest backward path of calls, `id` first,
  or `[]` when `test_id` does not reach `id` within `max_hops`.

  The walk is `tests_for/3`'s: breadth first over the callers, through any record, visiting
  each record once. Each id on the path calls the one before it. When the nearest way the
  test reaches `id` is through a setup of its module, the path ends at that setup rather
  than at the test: ExUnit runs the setup before the test, and the test itself makes no
  call on the way, so the setup is the record whose call the path's last step is. A test
  met at the same hop as such a setup is preferred to it. A removed setup runs nothing, so
  the path never ends at one.
  """
  @spec path_back(t(), String.t(), String.t(), non_neg_integer()) :: [String.t()]
  def path_back(%__MODULE__{} = index, test_id, id, max_hops \\ @max_hops) do
    start = resolve(index, id)

    case index.functions[test_id] do
      %{"kind" => "test", "module" => module} when is_map_key(index.functions, start) ->
        setup? = fn id ->
          match?(%{"kind" => "setup", "module" => ^module}, index.functions[id]) and
            index.functions[id]["removed"] != true
        end

        search_back(index, [start], %{start => nil}, {test_id, setup?}, 1, max_hops)

      _other ->
        []
    end
  end

  defp search_back(_index, [], _parents, _goal, _hop, _max_hops), do: []
  defp search_back(_index, _frontier, _parents, _goal, hop, max_hops) when hop > max_hops, do: []

  defp search_back(index, frontier, parents, {test_id, setup?} = goal, hop, max_hops) do
    {next, parents} =
      for id <- frontier, caller <- Map.get(index.callers, id, []), reduce: {[], parents} do
        {next, parents} ->
          if Map.has_key?(parents, caller),
            do: {next, parents},
            else: {[caller | next], Map.put(parents, caller, id)}
      end

    next = Enum.reverse(next)

    case Enum.find(next, &(&1 == test_id)) || Enum.find(next, setup?) do
      nil -> search_back(index, next, parents, goal, hop + 1, max_hops)
      found -> trace(parents, found, [])
    end
  end

  defp trace(parents, id, path) do
    case Map.fetch!(parents, id) do
      nil -> [id | path]
      parent -> trace(parents, parent, [id | path])
    end
  end

  @doc """
  Whether a record belongs to the test suite rather than the application: a test, a setup
  callback, or any function defined in a test file, which is how a test module's helpers
  are told apart.
  """
  @spec test_side?(t(), function_record()) :: boolean()
  def test_side?(%__MODULE__{} = index, record),
    do: record["kind"] in ["test", "setup"] or test_file?(index, record["file"])

  @doc """
  Whether `file`, relative to the project root, lies under one of the project's
  `test_paths`.

  An index built without tests names no test paths, so nothing in it is a test file.
  """
  @spec test_file?(t(), String.t() | nil) :: boolean()
  def test_file?(%__MODULE__{} = index, file) when is_binary(file) do
    index.project
    |> Map.get("test_paths")
    |> List.wrap()
    |> Enum.any?(fn path ->
      path = String.trim_trailing(path, "/")
      file == path or String.starts_with?(file, path <> "/")
    end)
  end

  def test_file?(%__MODULE__{}, _file), do: false

  @doc """
  Ranks functions against `query`: exact id, then ids containing it, then ids containing
  it as a subsequence. Case-insensitive; shorter ids win ties.

  A test or setup record is also matched by its module followed by its test's `describe` and
  name as written, so a test is found by the words of its name even where its id escapes
  them, and the better of the two scores ranks it.

  With `modules: true` the module records are ranked in the same list by their names, scored
  and ordered as a function's id is, each name once with the record `fetch_module/2` answers;
  a result is a module when its `kind` is `"module"`.
  """
  @spec search(t(), String.t(), pos_integer(), keyword()) :: [
          function_record() | module_record()
        ]
  def search(%__MODULE__{} = index, query, limit \\ 20, opts \\ []) do
    query = query |> String.trim() |> String.downcase()

    candidates =
      for record <- Map.values(index.functions),
          do: {search_texts(record), record["id"], record}

    candidates =
      if Keyword.get(opts, :modules, false),
        do:
          candidates ++
            for(
              {name, record} <- index.modules_by_name,
              do: {[String.downcase(name)], name, record}
            ),
        else: candidates

    if query == "" do
      []
    else
      candidates
      |> Enum.flat_map(fn {texts, key, record} ->
        case texts |> Enum.map(&score(&1, query)) |> Enum.max() do
          nil -> []
          score -> [{{-score, String.length(key), key}, record}]
        end
      end)
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.take(limit)
      |> Enum.map(&elem(&1, 1))
    end
  end

  defp resolve(%__MODULE__{} = index, id), do: Map.get(index.aliases, id, id)

  defp search_texts(%{"test" => %{} = test} = record) do
    words = [record["module"], test["describe"], test["name"]] |> Enum.reject(&is_nil/1)
    [String.downcase(record["id"]), words |> Enum.join(" ") |> String.downcase()]
  end

  defp search_texts(record), do: [String.downcase(record["id"])]

  defp score(id, query) do
    cond do
      id == query -> 3
      String.contains?(id, query) -> 2
      subsequence?(String.graphemes(id), String.graphemes(query)) -> 1
      true -> nil
    end
  end

  defp subsequence?(_haystack, []), do: true
  defp subsequence?([], _needle), do: false
  defp subsequence?([char | rest], [char | needle]), do: subsequence?(rest, needle)
  defp subsequence?([_ | rest], needle), do: subsequence?(rest, needle)
end
