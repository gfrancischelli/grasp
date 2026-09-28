defmodule Grasp.MCP.Tools.GetFunction do
  @moduledoc """
  Read one function of the indexed project: its source, span, calls, the ids that call it,
  the ids it calls, the entry points that reach it, and the review comments still open on
  its lines. Accepts any arity a definition with default arguments answers to.
  """

  use Anubis.Server.Component, type: :tool

  alias Grasp.Index
  alias Grasp.MCP.Comments, as: Shape
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
      entry_points =
        index
        |> Index.entry_points_for(record["id"])
        |> Enum.map(&Map.take(&1, ["kind", "label"]))

      body =
        record
        |> Map.drop(["base_source"])
        |> Map.merge(%{
          "callers" => Index.callers(index, record["id"]),
          "callees" => Index.callees(index, record["id"]),
          "entry_points" => entry_points,
          "comments" => comments(record, index)
        })

      Tools.reply(frame, body)
    else
      {:error, reason} -> Tools.error(frame, reason)
    end
  end

  defp comments(record, index) do
    [function_id: record["id"]]
    |> Grasp.Comments.list()
    |> Enum.map(&Shape.thread_map(&1, index))
  end
end
