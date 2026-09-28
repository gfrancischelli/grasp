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
          change: String.t(),
          base_source: String.t() | nil,
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
    prefixes = Enum.map(paths, &(String.trim_trailing(&1, "/") <> "/"))

    compared_sources =
      Map.filter(compared_sources, fn {file, _} -> String.starts_with?(file, prefixes) end)

    base_definitions =
      Enum.flat_map(compared_sources, fn {file, source} ->
        # Only Elixir sources, test files among them, hold definitions to match by name; a
        # template is compared as a whole file, and running it through the parser would
        # yield nothing anyway.
        with extension when extension in [".ex", ".exs"] <- Path.extname(file),
             {:ok, %{definitions: definitions}} <- Extract.extract(source, file) do
          definitions
        else
          _ -> []
        end
      end)

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
      change: "removed",
      base_source: definition.source,
      removed: true
    })
  end
end
