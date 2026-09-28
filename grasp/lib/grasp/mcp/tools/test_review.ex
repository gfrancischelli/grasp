defmodule Grasp.MCP.Tools.TestReview do
  @moduledoc """
  List the tests the branch modified whose assertions it weakened, and the tests it added
  that assert nothing, sorted by id. `mark` is `weakened` or `asserts_nothing`; `reasons`
  names each weakening: `removed: <assertion>` for an assertion of the base the head
  makes fewer times, `dropped: <name>` for an `assert_*`/`refute_*` function called fewer
  times, and `loosened: <assertion>` for an `assert left == right` whose left side the head
  asserts with `=~`, `in`, `match?/2` or on its own. Each id can then be read with
  `get_function`.

  Empty for an index built without a base ref, which has nothing to compare against.
  """

  use Anubis.Server.Component, type: :tool

  alias Grasp.Index
  alias Grasp.MCP.Tools

  schema do
  end

  @impl true
  def execute(_params, frame) do
    case Tools.index() do
      {:error, response} ->
        {:reply, response, frame}

      {:ok, index} ->
        Tools.reply(frame, %{
          "tests" =>
            Enum.map(
              Index.test_review(index),
              &%{"id" => &1.id, "mark" => Atom.to_string(&1.mark), "reasons" => &1.reasons}
            )
        })
    end
  end
end
