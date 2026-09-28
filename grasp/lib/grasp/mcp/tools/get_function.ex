defmodule Grasp.MCP.Tools.GetFunction do
  @moduledoc """
  Read one function of the indexed project: its source, span, calls, the ids that call it,
  the ids it calls, the entry points that reach it, and the review comments still open on
  its lines. Accepts any arity a definition with default arguments answers to.

  A thread belongs to the review session it was written in, so the comments are those of
  the session named, and a call naming no session carries none.
  """

  use Anubis.Server.Component, type: :tool

  alias Grasp.Index
  alias Grasp.MCP.Comments, as: Shape
  alias Grasp.MCP.Tools

  @session_field "The review session whose open comments on the function to include; " <>
                   "#{Grasp.Session.Disk.name_rule()}. Omit it and the answer carries no comments"

  schema do
    field(:id, :string,
      required: true,
      description:
        "A function id, `Module.fun/arity`; a test's id quotes its name, as in `SampleApp.CheckTest.\"test counts\"/1`"
    )

    field(:session, :string, description: @session_field)
  end

  @impl true
  def execute(%{id: id} = params, frame) do
    with {:ok, session} <- session(params),
         {:ok, index} <- Tools.index(),
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
          "comments" => comments(session, record, index)
        })

      Tools.reply(frame, body)
    else
      {:error, reason} -> Tools.error(frame, reason)
    end
  end

  defp session(params) do
    case Map.get(params, :session) do
      nil -> {:ok, nil}
      session -> Tools.check_session(session)
    end
  end

  defp comments(nil, _record, _index), do: []

  defp comments(session, record, index) do
    [session: session, function_id: record["id"]]
    |> Grasp.Comments.list()
    |> Enum.map(&Shape.thread_map(&1, index))
  end
end
