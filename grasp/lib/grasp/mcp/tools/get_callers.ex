defmodule Grasp.MCP.Tools.GetCallers do
  @moduledoc "List the functions that call a given function, by id. Use it to walk a call graph upwards, towards the entry points."

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
        "callers" => Index.callers(index, record["id"])
      })
    else
      {:error, reason} -> Tools.error(frame, reason)
    end
  end
end
