defmodule Grasp.MCP.Tools.ResolveComment do
  @moduledoc """
  Close a review comment, or reopen one, and get the whole thread back.

  A resolved thread drops out of `list_comments` and out of the reviewer's open count, so
  resolve one only once what it asked for is done or answered — it is the record of what is
  still outstanding, not a way to tidy the gutter. `resolved: false` puts a thread back on
  the list when it turns out the matter is not settled.

  A thread is closed in the session it belongs to: an id of another session's thread is
  refused as an unknown comment.
  """

  use Anubis.Server.Component, type: :tool

  alias Grasp.Comments
  alias Grasp.MCP.Comments, as: Shape
  alias Grasp.MCP.Tools

  @session_field Tools.comment_session_field_description()

  schema do
    field(:session, :string,
      required: true,
      description: @session_field
    )

    field(:comment_id, :integer,
      required: true,
      description: "Id of the thread to close, as `list_comments` reports it"
    )

    field(:resolved, :boolean,
      default: true,
      description: "false reopens a resolved thread; default true"
    )
  end

  @impl true
  def execute(%{comment_id: id} = params, frame) do
    with {:ok, session} <- Tools.check_session(Map.get(params, :session)),
         {:ok, index} <- Tools.index(),
         {:ok, thread} <- set_resolved(session, id, Map.get(params, :resolved, true)) do
      Tools.reply(frame, Shape.thread_map(thread, index))
    else
      {:error, reason} -> Tools.error(frame, reason)
    end
  end

  defp set_resolved(session, id, resolved) do
    with {:ok, _thread} <- Comments.fetch(id, session),
         {:ok, thread} <- Comments.set_resolved(id, resolved) do
      {:ok, thread}
    else
      :error -> {:error, "unknown comment: #{id}"}
      {:error, :unknown} -> {:error, "unknown comment: #{id}"}
    end
  end
end
