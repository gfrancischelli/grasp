defmodule GraspWeb.TestReach do
  @moduledoc """
  The tests reaching each function on the canvas, held between renders.

  `Grasp.Index.tests_for/2` walks the callers graph backwards, so its answers are kept
  together with the index and the set of function ids they were taken against, and taken
  again only when either of the two differs. A move, a focus, a comment or a render leaves
  both alone, and the held answers stand as they are.

  A test or a setup is a test itself rather than something tests reach, so its card holds no
  entry.
  """

  alias Grasp.Index
  alias Grasp.Session.Forest

  defstruct index: nil, ids: MapSet.new(), tests: %{}

  @typedoc """
  The answers in `tests`, keyed by function id, for every id in `ids`, taken against
  `index`.
  """
  @type t :: %__MODULE__{
          index: Index.t() | nil,
          ids: MapSet.t(String.t()),
          tests: %{String.t() => [Index.reach()]}
        }

  @doc "Holds no answers, against no index."
  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc """
  The answers for `forest`'s function ids against `index`.

  Returns `reach` itself when it holds the answers for the same index and the same set of
  function ids, and walks the index again for every function otherwise.
  """
  @spec refresh(t(), Index.t() | nil, Forest.t()) :: t()
  def refresh(%__MODULE__{} = reach, index, %Forest{} = forest) do
    ids = forest.cards |> Map.values() |> MapSet.new(& &1.function_id)

    if reach.index === index and MapSet.equal?(reach.ids, ids),
      do: reach,
      else: %__MODULE__{index: index, ids: ids, tests: answers(index, ids)}
  end

  @doc "The tests reaching `function_id`, nearest first; `[]` when it holds no answer."
  @spec for_function(t(), String.t()) :: [Index.reach()]
  def for_function(%__MODULE__{} = reach, function_id),
    do: Map.get(reach.tests, function_id, [])

  defp answers(%Index{} = index, ids) do
    for id <- ids, not test?(index, id), into: %{}, do: {id, Index.tests_for(index, id)}
  end

  defp answers(_no_index, _ids), do: %{}

  defp test?(index, id) do
    case Index.fetch_function(index, id) do
      {:ok, %{"kind" => kind}} -> kind in ~w(test setup)
      _other -> false
    end
  end
end
