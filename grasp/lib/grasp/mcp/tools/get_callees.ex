defmodule Grasp.MCP.Tools.GetCallees do
  @moduledoc """
  List the functions a given function calls, by id, under `callees`. Targets outside the
  indexed project — the standard library, a dependency — are listed too, and `get_function`
  has nothing to say about those. A test's Mox doubles are answered apart, under `doubles`,
  each with its `target`, `behaviour` and `mock`: a double stands in for the code it names
  rather than running it, so it is not a call, and the test is not among that function's
  callers or its tests.
  """

  use Anubis.Server.Component, type: :tool

  alias Grasp.Index
  alias Grasp.MCP.Tools

  schema do
    field(:id, :string,
      required: true,
      description:
        "A function id, `Module.fun/arity`; a test's id quotes its name, as in `SampleApp.CheckTest.\"test counts\"/1`"
    )
  end

  @impl true
  def execute(%{id: id}, frame) do
    with {:ok, index} <- Tools.index(),
         {:ok, record} <- Tools.fetch_function(index, id) do
      Tools.reply(frame, %{
        "id" => record["id"],
        "callees" => Index.callees(index, record["id"], doubles: false),
        "doubles" => Index.doubles(index, record["id"])
      })
    else
      {:error, reason} -> Tools.error(frame, reason)
    end
  end
end
