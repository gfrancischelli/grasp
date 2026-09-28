defmodule GraspWeb.CardCoverage do
  @moduledoc """
  How each function on the canvas reads in the loaded coverage, held between renders.

  Reading a record's coverage hashes its source and walks its clauses and arms, so the
  answers are kept together with the generation of the coverage document, the generation of
  the index and the function ids they were taken for. Another document or another index takes
  every answer again; a card opened on a function not yet read takes that one alone; a
  move, a focus, a comment or a render leaves the held answers as they are. The LiveView
  hands each card its own reading from `for_function/2`, so a card's coverage attribute
  differs between renders only when its reading does.

  A fresh reading is what a card body is drawn with: each counted line as `"run"` or
  `"missed"` and the first line of each clause or arm never entered as `"clause"` or
  `"arm"`, a clause winning over an arm that starts on the same line.
  """

  alias Grasp.Coverage
  alias Grasp.Index
  alias Grasp.Session.Forest

  defstruct coverage: nil, index: nil, readings: %{}

  @typedoc "What a card draws for its function's coverage."
  @type reading ::
          :none
          | :stale
          | %{
              lines: %{pos_integer() => String.t()},
              gaps: %{pos_integer() => String.t()}
            }

  @typedoc """
  The readings, keyed by function id, taken against the coverage document of generation
  `coverage` (`nil` when none is loaded) and the index of generation `index`.
  """
  @type t :: %__MODULE__{
          coverage: pos_integer() | nil,
          index: non_neg_integer() | nil,
          readings: %{String.t() => reading()}
        }

  @doc "Holds no readings, against no coverage."
  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc "Whether a coverage document is loaded."
  @spec loaded?(t()) :: boolean()
  def loaded?(%__MODULE__{coverage: coverage}), do: coverage != nil

  @doc """
  The readings for `forest`'s function ids against `snapshot` — what
  `Grasp.CoverageStore.snapshot/0` answers — and `index`.

  Returns `held` itself when it was taken against the same document and index and already
  reads every function on the canvas.
  """
  @spec refresh(t(), {pos_integer(), Coverage.document()} | nil, Index.t() | nil, Forest.t()) ::
          t()
  def refresh(%__MODULE__{} = held, snapshot, index, %Forest{} = forest) do
    {generation, document} = snapshot || {nil, nil}
    index_generation = index && index.generation
    ids = forest.cards |> Map.values() |> MapSet.new(& &1.function_id)

    kept =
      if held.coverage == generation and held.index == index_generation,
        do: Map.take(held.readings, MapSet.to_list(ids)),
        else: %{}

    missing = Enum.reject(ids, &Map.has_key?(kept, &1))

    if missing == [] and map_size(kept) == map_size(held.readings) and
         held.coverage == generation and held.index == index_generation do
      held
    else
      readings = Map.new(missing, &{&1, read(document, index, &1)})

      %__MODULE__{
        coverage: generation,
        index: index_generation,
        readings: Map.merge(kept, readings)
      }
    end
  end

  @doc "The reading for `function_id`; `:none` when it holds none."
  @spec for_function(t() | nil, String.t()) :: reading()
  def for_function(%__MODULE__{readings: readings}, function_id),
    do: Map.get(readings, function_id, :none)

  def for_function(nil, _function_id), do: :none

  defp read(nil, _index, _id), do: :none
  defp read(_document, nil, _id), do: :none

  defp read(document, %Index{} = index, id) do
    with {:ok, record} <- Index.fetch_function(index, id),
         {:fresh, %{lines: lines}} <- Coverage.for_function(document, record) do
      gaps = Coverage.gaps(record, lines)

      %{
        lines:
          Map.new(lines, fn {line, count} -> {line, if(count > 0, do: "run", else: "missed")} end),
        gaps:
          Map.merge(
            Map.new(gaps.arms, fn [first, _last] -> {first, "arm"} end),
            Map.new(gaps.clauses, fn [first, _last] -> {first, "clause"} end)
          )
      }
    else
      {:stale, _entry} -> :stale
      _none -> :none
    end
  end
end
