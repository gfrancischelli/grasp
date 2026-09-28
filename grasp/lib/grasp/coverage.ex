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
            "lines" => %{"8" => 3}
          }
        }
      }

  A line `:cover` does not count is absent from `"lines"`, so an absent line is neither run
  nor never run. A function whose current `source` hashes differently from the entry's
  `source_hash` is stale: its counts describe a body other than the one the record holds.
  """

  @type document :: %{required(String.t()) => term()}
  @type lines :: %{pos_integer() => non_neg_integer()}
  @type reading :: :none | {:stale, map()} | {:fresh, %{lines: lines()}}
  @type range :: [pos_integer()]

  @doc """
  Builds the document from `index` and the counted lines of each file.

  `lines_by_file` maps a project-relative file to `%{line => count}`. Every record that is
  not removed, not a test or a setup, and not in a file under the project's `test_paths`
  gets an entry when its span holds at least one counted line; a counted line outside a
  record's span is not attributed to it. `meta` carries `:generated_at` and `:git_head`; the
  index's own `generated_at` is written beside them.
  """
  @spec build(Grasp.Index.t(), %{String.t() => lines()}, %{
          generated_at: String.t(),
          git_head: String.t() | nil
        }) :: document()
  def build(%Grasp.Index{} = index, lines_by_file, meta) when is_map(lines_by_file) do
    functions =
      for {id, record} <- index.functions,
          application?(index, record),
          lines = span_lines(record, Map.get(lines_by_file, record["file"], %{})),
          lines != %{},
          into: %{} do
        {id,
         %{
           "source_hash" => source_hash(record),
           "lines" => Map.new(lines, fn {line, count} -> {Integer.to_string(line), count} end)
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
  `{:error, {:unsupported_document, version}}`.
  """
  @spec decode(binary()) :: {:ok, document()} | {:error, term()}
  def decode(json) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, %{"version" => 1, "functions" => functions} = document} when is_map(functions) ->
        {:ok, document}

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

  `:none` when the document holds no entry for the record's id, `{:stale, entry}` when the
  entry is written against a `source` other than the record's, and `{:fresh, %{lines:
  lines}}` with the counts keyed by integer line otherwise.
  """
  @spec for_function(document(), Grasp.Index.function_record()) :: reading()
  def for_function(%{"functions" => functions}, %{"id" => id} = record) do
    case Map.get(functions, id) do
      nil ->
        :none

      %{"source_hash" => hash, "lines" => lines} = entry ->
        if hash == source_hash(record) do
          {:fresh,
           %{lines: Map.new(lines, fn {line, count} -> {String.to_integer(line), count} end)}}
        else
          {:stale, entry}
        end
    end
  end

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

  defp application?(index, record) do
    record["removed"] != true and record["kind"] not in ["test", "setup"] and
      is_binary(record["file"]) and not Grasp.Index.test_file?(index, record["file"])
  end

  defp span_lines(%{"span" => %{"start_line" => first, "end_line" => last}}, lines)
       when is_integer(first) and is_integer(last) do
    for {line, count} <- lines, line >= first and line <= last, into: %{}, do: {line, count}
  end

  defp span_lines(_record, _lines), do: %{}

  defp source_hash(record),
    do: Base.encode16(:crypto.hash(:sha256, record["source"] || ""), case: :lower)
end
