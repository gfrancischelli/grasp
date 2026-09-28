defmodule Grasp.Index do
  @moduledoc """
  In-memory view of an index document written by `mix grasp.index`.

  Records keep the document's string keys so the viewer and the MCP server render the
  same shape they would read from disk. Functions are keyed by id (`"Mod.fun/arity"`);
  a definition with default arguments is also reachable through each extra arity it
  defines. Callers are derived at load time by inverting every function's calls and
  hidden calls, and entry points are indexed by the function they reach. Search ranks an exact id first, then ids containing the query, then ids
  whose characters contain the query as a subsequence, so `"walcre"` still finds
  `MyApp.Wallets.credit/3`.

  The struct can be large — about 10 MB of JSON for a 500-file project — so hold it once,
  for instance in `:persistent_term`, rather than copying it into per-process state.
  """

  alias Grasp.Index.Join

  defstruct version: 1,
            generated_at: nil,
            project: %{},
            git: nil,
            modules: [],
            entry_points: [],
            functions: %{},
            aliases: %{},
            callers: %{},
            entry_points_by_target: %{}

  @type function_record :: %{required(String.t()) => term()}
  @type t :: %__MODULE__{
          version: pos_integer(),
          generated_at: String.t() | nil,
          project: map(),
          git: map() | nil,
          modules: [map()],
          entry_points: [map()],
          functions: %{String.t() => function_record()},
          aliases: %{String.t() => String.t()},
          callers: %{String.t() => [String.t()]},
          entry_points_by_target: %{String.t() => [map()]}
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
        for call <- targets(record), is_map(call) do
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

    %__MODULE__{
      version: 1,
      generated_at: document["generated_at"],
      project: document["project"] || %{},
      git: document["git"],
      modules: document["modules"] || [],
      entry_points: entry_points,
      functions: functions,
      aliases: aliases,
      callers: callers,
      entry_points_by_target: entry_points_by_target
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

  @doc "Ids of the functions that call `id`, sorted."
  @spec callers(t(), String.t()) :: [String.t()]
  def callers(%__MODULE__{} = index, id), do: Map.get(index.callers, resolve(index, id), [])

  @doc """
  Ids the function calls (visible and hidden), resolved and sorted.

  A returned id may be outside the index — anything in the standard library or a
  dependency is a call target but never a definition — so `fetch_function/2` returns
  `:error` for it.
  """
  @spec callees(t(), String.t()) :: [String.t()]
  def callees(%__MODULE__{} = index, id) do
    case fetch_function(index, id) do
      {:ok, record} ->
        record
        |> targets()
        |> Enum.map(&resolve(index, &1["target"]))
        |> Enum.uniq()
        |> Enum.sort()

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

  @doc "Module records as stored in the document."
  @spec modules(t()) :: [map()]
  def modules(%__MODULE__{} = index), do: index.modules

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

  @typedoc """
  One test module as the sidebar lists it: its name, the file it is written in, its setup
  callbacks in source order and its tests grouped under their `describe` — `nil` for the
  tests written outside any — each group placed where its first test is, its tests in
  source order.
  """
  @type test_module :: %{
          module: String.t(),
          file: String.t(),
          setups: [function_record()],
          describes: [{String.t() | nil, [function_record()]}]
        }

  @doc """
  Every module holding test or setup records, sorted by file and then by name.

  A record is a test when its `kind` is `"test"` and a setup when it is `"setup"`; a module
  holding only setups — a case template's callback — is listed too, since its setup runs in
  every test that uses it. An index built without tests returns `[]`.
  """
  @spec tests(t()) :: [test_module()]
  def tests(%__MODULE__{} = index) do
    index.functions
    |> Map.values()
    |> Enum.filter(&(&1["kind"] in ["test", "setup"]))
    |> Enum.sort_by(&{&1["span"]["start_line"], &1["id"]})
    |> Enum.group_by(& &1["module"])
    |> Enum.map(fn {module, [first | _] = records} ->
      {setups, tests} = Enum.split_with(records, &(&1["kind"] == "setup"))

      %{
        module: module,
        file: first["file"],
        setups: setups,
        describes: group_in_order(tests, &get_in(&1, ["test", "describe"]))
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
  """
  @spec search(t(), String.t(), pos_integer()) :: [function_record()]
  def search(%__MODULE__{} = index, query, limit \\ 20) do
    query = query |> String.trim() |> String.downcase()

    if query == "" do
      []
    else
      index.functions
      |> Map.values()
      |> Enum.flat_map(fn record ->
        case record |> search_texts() |> Enum.map(&score(&1, query)) |> Enum.max() do
          nil -> []
          score -> [{score, record}]
        end
      end)
      |> Enum.sort_by(fn {score, record} ->
        {-score, String.length(record["id"]), record["id"]}
      end)
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
