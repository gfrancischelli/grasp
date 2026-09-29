defmodule Grasp.Index.Changes do
  @moduledoc """
  Classifies function records against the same functions as they stood at a base commit.

  Every record gains three keys: `:change` — `"added"`, `"modified"`, `"unchanged"` or
  `"removed"` — `:base_source`, the definition's text at the base commit for a modified
  or removed function, and `:removed`.

  A function is identified by its id, `"Module.name/arity"`, never by its position in a
  file, and only a definition whose own text differs from the base reads `"modified"`.
  So "unchanged" is a statement about the function, not about its file: a function that
  moved to another file, or that an insertion above it pushed down the page, is unchanged
  because nothing a reader would review about it has changed.

  Only the files git reported as differing from the base are compared: those are the keys
  of the map passed in, whether or not the base had anything to say about them. A record
  in a file the diff never touched is unchanged by construction, even when no base
  definition carries its id — the base sources at hand simply do not describe that file. A
  base source that is empty (a file this branch added) or that cannot be parsed contributes
  no definitions, so the functions defined in it read as added.

  A definition answers to every arity it declares, not only to its canonical id: a head
  with default arguments is one function reachable under several ids. So a base `f/1` that
  gains a default argument and becomes `f/2` is matched through the arity the two sides
  share and reads "modified", with the base head as its `base_source` — not an added
  `f/2` beside a removed `f/1` that is still perfectly callable. The canonical id is tried
  first, so an exact match always wins over an alias.

  A template is one file rather than a definition inside one, so it is classified by its
  whole text: the base contents of its path, when the diff holds them, are what "modified"
  compares against and what `:base_source` carries. Known gap: a template the branch
  deleted is not reported as removed — the module that embedded it is only at hand when
  that module's own file changed too.

  Definitions the base holds that no current record answers to under any of their arities
  become removed records: the same shape as any other record, carrying the base file, span
  and source and no calls, so a reader can still see what a deleted function used to be.
  They are appended after the records that were passed in, ordered by id.

  Modules are classified beside the functions, by `classify_modules/3`, on the same compared
  files: a module is matched to the base by its name and compared by its moduledoc's source,
  which is the part of a module a card shows.
  """

  alias Grasp.Index.{Extract, Join}

  @type classified_record :: %{
          optional(:test) => Extract.test_info() | nil,
          id: String.t(),
          module: String.t(),
          name: atom(),
          arity: non_neg_integer(),
          arities: [non_neg_integer()],
          kind: Extract.kind(),
          file: String.t(),
          span: %{start_line: pos_integer(), end_line: pos_integer()},
          source: String.t(),
          calls: [Join.call()],
          hidden_calls: [Join.hidden_call()],
          clauses: [Extract.line_range()],
          arms: [Extract.line_range()],
          change: String.t(),
          base_source: String.t() | nil,
          removed: boolean()
        }

  @type classified_module :: %{
          name: String.t(),
          file: String.t(),
          line: pos_integer(),
          doc: Extract.moduledoc() | nil,
          span: %{start_line: pos_integer(), end_line: pos_integer()} | nil,
          source: String.t() | nil,
          change: String.t(),
          base_source: String.t() | nil,
          base_doc: Extract.moduledoc() | nil,
          removed: boolean()
        }

  @doc """
  Classifies `records` against `compared_sources`, mapping every project-relative path that
  differs from the base to the contents it had there — an empty string for a file the base
  did not have, which `Grasp.Index.BaseRef` leaves out of its own `base_sources` map.

  `paths` are the project's compile paths, and its test paths when its tests are indexed:
  a base source outside them is ignored, so a file the index never looked at cannot invent
  removed functions. A test is classified as any function is, by its id.
  """
  @spec classify([Join.function_record()], %{String.t() => String.t()}, [String.t()]) :: [
          classified_record()
        ]
  def classify(records, compared_sources, paths) do
    compared_sources = within(compared_sources, paths)
    base_definitions = Enum.flat_map(base_extracts(compared_sources), & &1.definitions)

    base_ids =
      Map.new(base_definitions, &{Join.function_id(&1.module, &1.name, &1.arity), &1})

    current_ids = MapSet.new(Enum.flat_map(records, &ids/1))

    removed =
      base_ids
      |> Enum.reject(fn {_id, definition} ->
        Enum.any?(ids(definition), &MapSet.member?(current_ids, &1))
      end)
      |> Enum.sort_by(fn {id, _definition} -> id end)
      |> Enum.map(fn {_id, definition} -> removed_record(definition) end)

    Enum.map(records, &classify_record(&1, base_ids, compared_sources)) ++ removed
  end

  @doc """
  Classifies `modules`, as `Grasp.Index.Extract` reads them, by their moduledocs against
  the modules the base sources in `compared_sources` define, matched by name; `paths` bound
  the compared files as they do for `classify/3`.

  Every module gains `:change`, `:base_source`, `:base_doc` and `:removed`. A module whose
  file is not among the compared files is `"unchanged"`. Otherwise it is `"added"` when it
  has a moduledoc and the base module of its name has none, or the base defines no module
  of its name; `"removed"` when the base module has one and it has none; `"modified"` when
  both have one and their sources differ; and `"unchanged"` otherwise, so a module that
  moved between files with the same moduledoc is unchanged. A `"modified"` or `"removed"`
  module carries the base side's moduledoc source as `:base_source` and its doc as
  `:base_doc`.

  A base module with a moduledoc that no module in `modules` is named after becomes a
  removed module: its base `file`, `line`, `doc`, `span` and `source`, no behaviours, and
  `removed: true`. Removed modules are appended after the others, ordered by name. A base
  module without a moduledoc that the head does not define leaves nothing a review could
  read, and no record.
  """
  @spec classify_modules([Extract.module_info()], %{String.t() => String.t()}, [String.t()]) ::
          [classified_module()]
  def classify_modules(modules, compared_sources, paths) do
    compared_sources = within(compared_sources, paths)

    base_modules =
      compared_sources
      |> base_extracts()
      |> Enum.flat_map(& &1.modules)
      |> Map.new(&{&1.name, &1})

    names = MapSet.new(modules, & &1.name)

    removed =
      base_modules
      |> Map.values()
      |> Enum.reject(&(MapSet.member?(names, &1.name) or is_nil(&1.doc)))
      |> Enum.sort_by(& &1.name)
      |> Enum.map(
        &Map.merge(&1, %{
          change: "removed",
          base_source: &1.source,
          base_doc: &1.doc,
          removed: true
        })
      )

    Enum.map(modules, fn module ->
      if Map.has_key?(compared_sources, module.file),
        do: classify_module(module, Map.get(base_modules, module.name)),
        else: module_change(module, "unchanged", nil)
    end) ++ removed
  end

  defp classify_module(%{doc: nil} = module, %{doc: doc} = base) when not is_nil(doc),
    do: module_change(module, "removed", base)

  defp classify_module(%{doc: doc} = module, base) when not is_nil(doc) do
    cond do
      is_nil(base) or is_nil(base.doc) -> module_change(module, "added", nil)
      base.source != module.source -> module_change(module, "modified", base)
      true -> module_change(module, "unchanged", nil)
    end
  end

  defp classify_module(module, _base), do: module_change(module, "unchanged", nil)

  defp module_change(module, change, nil),
    do: Map.merge(module, %{change: change, base_source: nil, base_doc: nil, removed: false})

  defp module_change(module, change, base),
    do:
      Map.merge(module, %{
        change: change,
        base_source: base.source,
        base_doc: base.doc,
        removed: false
      })

  defp within(compared_sources, paths) do
    prefixes = Enum.map(paths, &(String.trim_trailing(&1, "/") <> "/"))
    Map.filter(compared_sources, fn {file, _} -> String.starts_with?(file, prefixes) end)
  end

  # Only Elixir sources, test files among them, hold definitions and modules to match by
  # name; a template is compared as a whole file, and running it through the parser would
  # yield nothing anyway.
  defp base_extracts(compared_sources) do
    Enum.flat_map(compared_sources, fn {file, source} ->
      with extension when extension in [".ex", ".exs"] <- Path.extname(file),
           {:ok, extracted} <- Extract.extract(source, file) do
        [extracted]
      else
        _ -> []
      end
    end)
  end

  defp classify_record(%{kind: :template} = record, _base_ids, compared_sources) do
    case Map.fetch(compared_sources, record.file) do
      :error -> change(record, "unchanged", nil)
      {:ok, ""} -> change(record, "added", nil)
      {:ok, base} when base == record.source -> change(record, "unchanged", nil)
      {:ok, base} -> change(record, "modified", base)
    end
  end

  defp classify_record(record, base_ids, compared_sources) do
    case Enum.find_value(ids(record), &Map.get(base_ids, &1)) do
      nil ->
        if Map.has_key?(compared_sources, record.file),
          do: change(record, "added", nil),
          else: change(record, "unchanged", nil)

      definition ->
        if definition.source == record.source,
          do: change(record, "unchanged", nil),
          else: change(record, "modified", definition.source)
    end
  end

  # Every id the definition answers to, canonical arity first so an exact match outranks
  # one made through an arity a default argument contributes.
  defp ids(%{module: module, name: name, arity: arity, arities: arities}) do
    [arity | arities]
    |> Enum.uniq()
    |> Enum.map(&Join.function_id(module, name, &1))
  end

  defp change(record, change, base_source),
    do: Map.merge(record, %{change: change, base_source: base_source, removed: false})

  # A removed test keeps its describe, name and tags, which is what a reader titles it by.
  defp removed_record(definition) do
    Map.merge(Map.take(definition, [:test]), %{
      id: Join.function_id(definition.module, definition.name, definition.arity),
      module: definition.module,
      name: definition.name,
      arity: definition.arity,
      arities: definition.arities,
      kind: definition.kind,
      file: definition.file,
      span: %{start_line: definition.start_line, end_line: definition.end_line},
      source: definition.source,
      calls: [],
      hidden_calls: [],
      clauses: Map.get(definition, :clauses, []),
      arms: Map.get(definition, :arms, []),
      change: "removed",
      base_source: definition.source,
      removed: true
    })
  end
end
