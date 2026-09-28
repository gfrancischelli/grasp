defmodule GraspWeb.CardResults do
  @moduledoc """
  How each card on the canvas reads in the loaded test results, held between renders.

  A test card wears its test's latest result; a function card counts the failures among the
  tests reaching it. Reading either hashes a test's source (`Grasp.TestResults.for_test/2`),
  so the answers are kept together with the generation of the results document, the
  generation of the index and the function ids they are taken for, as
  `GraspWeb.CardCoverage` keeps coverage readings. Another document or another index takes
  every answer again; a card opened on a function not yet read takes that one alone; a
  move, a focus, a comment, a line of run output or a render leaves the held answers as
  they are. The LiveView hands each card its own reading from `for_function/2`, so a card's
  result differs between renders only when its reading does.

  A test's reading is its status when the result is fresh and `"passed"`, `"failed"`,
  `"skipped"` or `"invalid"` — a test whose module's `setup_all` failed, so it never ran —
  and `"stale"` when a result of one of those is recorded against another source. An
  `"excluded"` result, a test the run loaded but did not run, says nothing about the test,
  and reads as no result. A function's reading counts its reaching tests
  (`GraspWeb.TestReach`) whose fresh result is `"failed"` or `"invalid"`: either is a test
  that did not pass.

  A test whose fresh result is `"failed"` also holds its errors, read with `failures/2`,
  which the card draws under its lines and `open failure` walks. They are the result's,
  read with it and gone with it: a stale result or any other status holds none.
  """

  alias Grasp.Index
  alias Grasp.Session.Forest
  alias Grasp.TestResults
  alias GraspWeb.TestReach

  @worn ~w(passed failed skipped invalid)
  @failing ~w(failed invalid)

  defstruct results: nil, index: nil, readings: %{}, failures: %{}

  @typedoc "What a card wears for its function's results."
  @type reading :: :none | {:result, String.t()} | {:failing, pos_integer()}

  @typedoc """
  The readings, keyed by function id, taken against the results document of generation
  `results` (`nil` when none is loaded) and the index of generation `index`, and the errors
  of each test among them whose fresh result is `"failed"`.
  """
  @type t :: %__MODULE__{
          results: pos_integer() | nil,
          index: non_neg_integer() | nil,
          readings: %{String.t() => reading()},
          failures: %{String.t() => [map()]}
        }

  @doc "Holds no readings, against no results."
  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc """
  The readings for `forest`'s function ids against `snapshot` — what
  `Grasp.ResultsStore.snapshot/0` answers — `index`, and `reach`, the tests reaching each of
  those functions.

  Returns `held` itself when its readings are of the same document and index and already
  read every function on the canvas.
  """
  @spec refresh(
          t(),
          {pos_integer(), TestResults.document()} | nil,
          Index.t() | nil,
          Forest.t(),
          TestReach.t()
        ) :: t()
  def refresh(%__MODULE__{} = held, snapshot, index, %Forest{} = forest, %TestReach{} = reach) do
    {generation, document} = snapshot || {nil, nil}
    index_generation = index && index.generation
    ids = forest.cards |> Map.values() |> MapSet.new(& &1.function_id)
    same? = held.results == generation and held.index == index_generation

    kept = if same?, do: Map.take(held.readings, MapSet.to_list(ids)), else: %{}
    kept_failures = if same?, do: Map.take(held.failures, Map.keys(kept)), else: %{}
    missing = Enum.reject(ids, &Map.has_key?(kept, &1))

    if same? and missing == [] and map_size(kept) == map_size(held.readings) do
      held
    else
      taken = Map.new(missing, &{&1, read(document, index, reach, &1)})

      %__MODULE__{
        results: generation,
        index: index_generation,
        readings:
          Map.merge(kept, Map.new(taken, fn {id, {reading, _errors}} -> {id, reading} end)),
        failures:
          Map.merge(
            kept_failures,
            for({id, {_reading, [_ | _] = errors}} <- taken, into: %{}, do: {id, errors})
          )
      }
    end
  end

  @doc "The reading for `function_id`; `:none` when it holds none."
  @spec for_function(t() | nil, String.t()) :: reading()
  def for_function(%__MODULE__{readings: readings}, function_id),
    do: Map.get(readings, function_id, :none)

  def for_function(nil, _function_id), do: :none

  @doc """
  The errors of `function_id`'s fresh failed result, in the order the run recorded them;
  empty for anything else.
  """
  @spec failures(t() | nil, String.t()) :: [map()]
  def failures(%__MODULE__{failures: failures}, function_id),
    do: Map.get(failures, function_id, [])

  def failures(nil, _function_id), do: []

  defp read(nil, _index, _reach, _id), do: {:none, []}
  defp read(_document, nil, _reach, _id), do: {:none, []}

  defp read(document, %Index{} = index, reach, id) do
    case Index.fetch_function(index, id) do
      {:ok, %{"kind" => "test"} = record} ->
        case TestResults.for_test(document, record) do
          {:fresh, %{"status" => "failed"} = result} ->
            {{:result, "failed"}, errors(result)}

          {:fresh, %{"status" => status}} when status in @worn ->
            {{:result, status}, []}

          {:stale, %{"status" => status}} when status in @worn ->
            {{:result, "stale"}, []}

          _none ->
            {:none, []}
        end

      {:ok, %{"kind" => "setup"}} ->
        {:none, []}

      {:ok, _function} ->
        failing =
          reach
          |> TestReach.for_function(id)
          |> Enum.count(&failed?(document, index, &1.test))

        {if(failing > 0, do: {:failing, failing}, else: :none), []}

      :error ->
        {:none, []}
    end
  end

  defp errors(%{"errors" => errors}) when is_list(errors), do: Enum.filter(errors, &is_map/1)
  defp errors(_result), do: []

  defp failed?(document, index, test_id) do
    with {:ok, record} <- Index.fetch_function(index, test_id),
         {:fresh, %{"status" => status}} when status in @failing <-
           TestResults.for_test(document, record) do
      true
    else
      _other -> false
    end
  end
end
