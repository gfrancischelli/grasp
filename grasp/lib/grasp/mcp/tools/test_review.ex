defmodule Grasp.MCP.Tools.TestReview do
  @moduledoc """
  List the tests the branch modified whose assertions it weakened, and the tests it added
  that assert nothing, sorted by id. `mark` is `weakened` or `asserts_nothing`; `reasons`
  names each weakening: `removed: <assertion>` for an assertion of the base with no
  counterpart at the head when the head makes fewer assertions, `dropped: <name>` for an
  `assert_*`/`refute_*` function called fewer times, and `loosened: <assertion>` for an
  `assert left == right` with no counterpart at the head whose left side the head asserts
  with `=~`, `in`, `match?/2` or on its own. Assertions compare by their parsed form, so layout and
  comments do not count. Only calls written in the test body are read: a test whose
  assertions sit in a helper it calls is marked as asserting nothing. Each id can then be
  read with `get_function`.

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
