defmodule Grasp.Coverage do
  @moduledoc """
  The coverage document `mix grasp.cover` writes, and how a function reads it.

  The document holds, per indexed application function, the `:cover` counts on the lines of
  its span and a hash of the record's `source` as the index held it when the coverage is
  written:

      %{
        "version" => 1,
        "generated_at" => "2026-09-28T12:00:00Z",
        "git_head" => "0f3c…" | nil,
        "index_generated_at" => "2026-09-28T11:58:00Z" | nil,
        "functions" => %{
          "SampleApp.Counter.init/1" => %{
            "source_hash" => "9a1e…",
            "lines" => %{"1" => 3}
          }
        }
      }

  A key of `"lines"` is an offset from the first line of the function's span, `"0"` being
  `span.start_line`, so a function that moves in its file with its source unchanged keeps
  its counts; `for_function/2` places them on the lines the record occupies. A line `:cover`
  does not count is absent, so an absent line is neither run nor never run. A function
  whose current `source` hashes differently from the entry's `source_hash` is stale: its
  counts describe a body other than the one the record holds.

  Counts are attributed per function, not per file: `build/3` takes them keyed by the
  compiled function they were counted in, and a record receives only the counts of its own
  module, name and arities, restricted to its span.
  """

  @type document :: %{required(String.t()) => term()}
  @type lines :: %{pos_integer() => non_neg_integer()}
  @type function_key :: {module :: String.t(), name :: String.t(), arity :: non_neg_integer()}
  @type reading :: :none | {:stale, map()} | {:fresh, %{lines: lines()}}
  @type range :: [pos_integer()]

  @doc """
  Builds the document from `index` and the counted lines of each compiled function.

  `counts` maps `{module, name, arity}` — the module as the index names it, `"Acme.Tally"` —
  to `%{line => count}`. A record takes the counts of every arity it defines that lie inside
  its span; a counted line outside the span, or counted in another function, is not
  attributed to it. Records that are removed, tests or setups, macros or guards (their
  bodies run when their callers compile, before `:cover` starts), or in a file under the
  project's `test_paths` get no entry, and neither does a record with no counted line.
  `meta` carries `:generated_at` and `:git_head`; the index's own `generated_at` is written
  beside them.
  """
  @spec build(Grasp.Index.t(), %{function_key() => lines()}, %{
          generated_at: String.t(),
          git_head: String.t() | nil
        }) :: document()
  def build(%Grasp.Index{} = index, counts, meta) when is_map(counts) do
    functions =
      for {id, record} <- index.functions,
          application?(index, record),
          %{"span" => %{"start_line" => first, "end_line" => last}} <- [record],
          lines = record_lines(record, counts, first, last),
          lines != %{},
          into: %{} do
        {id,
         %{
           "source_hash" => source_hash(record),
           "lines" =>
             Map.new(lines, fn {line, count} -> {Integer.to_string(line - first), count} end)
         }}
      end

    %{
      "version" => 1,
      "generated_at" => meta.generated_at,
      "git_head" => meta.git_head,
      "index_generated_at" => index.generated_at,
      "functions" => functions
    }
  end

  @doc """
  Keeps the entries of `document` whose record's `source` is the text of its file under
  `root`, and answers how many it drops.

  The counts are taken from the beams the suite compiled from the files under `root`, while
  an entry's offsets and `source_hash` come from the index record. An entry describes the code
  the suite ran only when the record's `source` equals the lines `span.start_line` to
  `span.end_line` of `root`'s copy of its `file`, joined as the index joins them; an entry
  whose file is missing or differs there is dropped. The index's own `project.root` plays no
  part, so an index built for another tree keeps the entries of the functions both trees
  hold alike.
  """
  @spec in_checkout(document(), Grasp.Index.t(), Path.t()) :: {document(), non_neg_integer()}
  def in_checkout(%{"functions" => functions} = document, %Grasp.Index{} = index, root)
      when is_binary(root) do
    {kept, _files} =
      Enum.reduce(functions, {%{}, %{}}, fn {id, entry}, {kept, files} ->
        record = Map.get(index.functions, id)
        {file_lines, files} = file_lines(record, root, files)

        if record != nil and span_text(record, file_lines) == record["source"] do
          {Map.put(kept, id, entry), files}
        else
          {kept, files}
        end
      end)

    {%{document | "functions" => kept}, map_size(functions) - map_size(kept)}
  end

  defp file_lines(%{"file" => file}, root, files) when is_binary(file) do
    case Map.fetch(files, file) do
      {:ok, lines} ->
        {lines, files}

      :error ->
        lines =
          case File.read(Path.join(root, file)) do
            {:ok, text} -> String.split(text, "\n")
            {:error, _reason} -> nil
          end

        {lines, Map.put(files, file, lines)}
    end
  end

  defp file_lines(_record, _root, files), do: {nil, files}

  defp span_text(
         %{"span" => %{"start_line" => first, "end_line" => last}},
         lines
       )
       when is_list(lines) and is_integer(first) and is_integer(last) and first >= 1 and
              last >= first and last <= length(lines) do
    lines |> Enum.slice(first - 1, last - first + 1) |> Enum.join("\n")
  end

  defp span_text(_record, _lines), do: nil

  @doc "The document as pretty-printed JSON."
  @spec encode(document()) :: String.t()
  def encode(document) when is_map(document), do: Jason.encode!(document, pretty: true)

  @doc """
  Writes the document to `path`, creating its directory.

  The JSON lands in a file beside `path` and is renamed over it, so a reader watching `path`
  never sees a document half written.
  """
  @spec write(document(), Path.t()) :: :ok | {:error, File.posix()}
  def write(document, path) when is_map(document) do
    temporary = path <> ".tmp"

    with :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- File.write(temporary, encode(document)),
         :ok <- File.rename(temporary, path) do
      :ok
    else
      {:error, reason} ->
        File.rm(temporary)
        {:error, reason}
    end
  end

  @doc """
  Reads a document back from its JSON.

  Anything but a version-1 document carrying a map of functions is rejected with
  `{:error, {:unsupported_document, version}}`. Within one, an entry that is not a string
  `"source_hash"` beside `"lines"` mapping integer offsets, written as strings, to
  non-negative counts is dropped, so its function reads `:none`.
  """
  @spec decode(binary()) :: {:ok, document()} | {:error, term()}
  def decode(json) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, %{"version" => 1, "functions" => functions} = document} when is_map(functions) ->
        {:ok, %{document | "functions" => Map.filter(functions, &valid_entry?/1)}}

      {:ok, %{} = document} ->
        {:error, {:unsupported_document, document["version"]}}

      {:ok, _other} ->
        {:error, {:unsupported_document, nil}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  How `record` reads in `coverage`.

  `:none` when the document holds no entry for the record's id (or one it cannot read),
  `{:stale, entry}` when the entry is written against a `source` other than the record's,
  and `{:fresh, %{lines: lines}}` otherwise, the counts keyed by the file lines the record
  occupies: each stored offset is added to the record's own `span.start_line`.
  """
  @spec for_function(document(), Grasp.Index.function_record()) :: reading()
  def for_function(
        %{"functions" => functions},
        %{"id" => id, "span" => %{"start_line" => first}} = record
      ) do
    case Map.get(functions, id) do
      %{"source_hash" => hash, "lines" => lines} = entry when is_map(lines) ->
        cond do
          not valid_entry?({id, entry}) ->
            :none

          hash == source_hash(record) ->
            {:fresh,
             %{
               lines:
                 Map.new(lines, fn {offset, count} ->
                   {first + String.to_integer(offset), count}
                 end)
             }}

          true ->
            {:stale, entry}
        end

      _no_entry ->
        :none
    end
  end

  def for_function(%{}, %{}), do: :none

  @doc """
  The clauses and arms of `record` that were never entered under `lines`.

  A clause or arm is never entered when it holds at least one counted line and every counted
  line in it ran zero times. One holding no counted line says nothing either way and is left
  out. Ranges are the record's own `"clauses"` and `"arms"`, `[start_line, end_line]`.
  """
  @spec gaps(Grasp.Index.function_record(), lines()) :: %{clauses: [range()], arms: [range()]}
  def gaps(record, lines) when is_map(record) and is_map(lines) do
    %{
      clauses: never_entered(Map.get(record, "clauses", []), lines),
      arms: never_entered(Map.get(record, "arms", []), lines)
    }
  end

  defp never_entered(ranges, lines) do
    Enum.filter(List.wrap(ranges), fn [first, last] ->
      counts = for {line, count} <- lines, line >= first and line <= last, do: count
      counts != [] and Enum.all?(counts, &(&1 == 0))
    end)
  end

  defp valid_entry?({_id, %{"source_hash" => hash, "lines" => lines}})
       when is_binary(hash) and is_map(lines) do
    Enum.all?(lines, fn {offset, count} ->
      is_binary(offset) and match?({_offset, ""}, Integer.parse(offset)) and is_integer(count) and
        count >= 0
    end)
  end

  defp valid_entry?(_entry), do: false

  @unattributed_kinds ~w(test setup defmacro defmacrop defguard defguardp)

  defp application?(index, record) do
    record["removed"] != true and record["kind"] not in @unattributed_kinds and
      is_binary(record["file"]) and not Grasp.Index.test_file?(index, record["file"])
  end

  defp record_lines(record, counts, first, last) when is_integer(first) and is_integer(last) do
    arities =
      case record["arities"] do
        arities when is_list(arities) -> arities
        _none -> List.wrap(record["arity"])
      end

    for arity <- arities,
        {line, count} <- Map.get(counts, {record["module"], record["name"], arity}, %{}),
        line >= first and line <= last,
        reduce: %{} do
      lines -> Map.update(lines, line, count, &(&1 + count))
    end
  end

  defp record_lines(_record, _counts, _first, _last), do: %{}

  defp source_hash(record),
    do: Base.encode16(:crypto.hash(:sha256, record["source"] || ""), case: :lower)
end
