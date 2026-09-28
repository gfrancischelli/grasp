defmodule Grasp.TestResults do
  @moduledoc """
  The results document `mix grasp.test` writes, and how a test reads it.

  The document holds, per test id, the latest result recorded for that test:

      %{
        "version" => 1,
        "tests" => %{
          "SampleApp.TallyTest.\\"test init keeps the start count\\"/1" => %{
            "status" => "failed",
            "time" => 1234,
            "run_id" => "5f2c…",
            "finished_at" => "2026-09-28T12:00:00Z",
            "source_hash" => "9a1e…" | nil,
            "errors" => [
              %{
                "kind" => "error",
                "message" => "Assertion with == failed",
                "expr" => "assert init_with(7) == {:ok, 8}",
                "left" => "{:ok, 7}",
                "right" => "{:ok, 8}",
                "stacktrace" => [
                  %{
                    "module" => "SampleApp.TallyTest",
                    "function" => "test init keeps the start count",
                    "arity" => 1,
                    "file" => "test/sample_app/tally_test.exs",
                    "line" => 18
                  }
                ]
              }
            ]
          }
        }
      }

  `"status"` is `"passed"`, `"failed"`, `"skipped"`, `"excluded"` or `"invalid"`; the
  errors are `Grasp.Test.Formatter`'s. A run merges its tests into the document and leaves
  every other test's result as it stood (see `merge/3`). `"source_hash"` is the sha256 of
  the test record's `source` as the index holds it when the run is merged, so a test whose
  current `source` hashes differently reads as stale, as coverage does.
  """

  @statuses ~w(passed failed skipped excluded invalid)

  @type document :: %{required(String.t()) => term()}
  @type result :: %{required(String.t()) => term()}
  @type reading :: :none | {:stale, result()} | {:fresh, result()}

  @doc "A document holding no result."
  @spec new() :: document()
  def new, do: %{"version" => 1, "tests" => %{}}

  @doc """
  Merges one run's results into `document`.

  `results` maps test ids to the results `Grasp.Test.Formatter` recorded. Each is stored
  with `meta.run_id`, `meta.finished_at` and the `"source_hash"` of the record `meta.index`
  holds for its id, `nil` when the index has none. A test the run does not name keeps the
  result it had. A test the run names replaces its result, except that an `"excluded"` one
  — a test the run loaded but did not run, as `mix test file:line` excludes the rest of its
  file — replaces only an absent or excluded result.
  """
  @spec merge(document() | nil, %{String.t() => result()}, %{
          run_id: String.t(),
          finished_at: String.t(),
          index: Grasp.Index.t() | nil
        }) :: document()
  def merge(document, results, meta) when is_map(results) do
    document = document || new()

    tests =
      Enum.reduce(results, document["tests"], fn {id, result}, tests ->
        previous = Map.get(tests, id)

        if result["status"] == "excluded" and previous != nil and
             previous["status"] != "excluded" do
          tests
        else
          Map.put(
            tests,
            id,
            Map.merge(result, %{
              "run_id" => meta.run_id,
              "finished_at" => meta.finished_at,
              "source_hash" => indexed_hash(meta.index, id)
            })
          )
        end
      end)

    %{document | "tests" => tests}
  end

  defp indexed_hash(%Grasp.Index{} = index, id) do
    case Grasp.Index.fetch_function(index, id) do
      {:ok, record} -> source_hash(record)
      :error -> nil
    end
  end

  defp indexed_hash(nil, _id), do: nil

  @doc "The document as pretty-printed JSON."
  @spec encode(document()) :: String.t()
  def encode(document) when is_map(document), do: Jason.encode!(document, pretty: true)

  @doc """
  Reads a document back from its JSON.

  Anything but a version-1 document carrying a map of tests is rejected with
  `{:error, {:unsupported_document, version}}`. Within one, a result without a known
  `"status"` is dropped, so its test reads `:none`.
  """
  @spec decode(binary()) :: {:ok, document()} | {:error, term()}
  def decode(json) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, %{"version" => 1, "tests" => tests} = document} when is_map(tests) ->
        {:ok, %{document | "tests" => Map.filter(tests, &valid_result?/1)}}

      {:ok, %{} = document} ->
        {:error, {:unsupported_document, document["version"]}}

      {:ok, _other} ->
        {:error, {:unsupported_document, nil}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Reads the document at `path`: a missing file is `{:ok, new()}`, as a project that has
  never run a test through Grasp holds no result.
  """
  @spec read(Path.t()) :: {:ok, document()} | {:error, term()}
  def read(path) do
    case File.read(path) do
      {:ok, json} -> decode(json)
      {:error, :enoent} -> {:ok, new()}
      {:error, reason} -> {:error, reason}
    end
  end

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
  How `record` reads in `document`.

  `:none` when the document holds no result for the record's id, `{:stale, result}` when
  the result was recorded against a `source` other than the record's, and
  `{:fresh, result}` otherwise.
  """
  @spec for_test(document(), Grasp.Index.function_record()) :: reading()
  def for_test(%{"tests" => tests}, %{"id" => id} = record) when is_map(tests) do
    result = Map.get(tests, id)

    cond do
      not valid_result?({id, result}) -> :none
      result["source_hash"] == source_hash(record) -> {:fresh, result}
      true -> {:stale, result}
    end
  end

  def for_test(%{}, %{}), do: :none

  defp valid_result?({_id, %{"status" => status}}) when status in @statuses, do: true
  defp valid_result?(_entry), do: false

  defp source_hash(record),
    do: Base.encode16(:crypto.hash(:sha256, record["source"] || ""), case: :lower)
end
