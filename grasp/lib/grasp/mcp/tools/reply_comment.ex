defmodule Grasp.MCP.Tools.ReplyComment do
  @moduledoc """
  Answer a review comment, as the agent. The reply joins the thread under the reviewer's
  own, on the line the thread hangs off, and the whole thread comes back.

  Use it to answer what a comment asked — what the code does, what was changed, why a
  suggestion does not hold — so the exchange stays on the line it is about instead of
  scattering across the chat. A thread that is answered and needs nothing further is then
  closed with `resolve_comment`.

  A thread is answered in the session it belongs to: an id of another session's thread is
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
      description: "Id of the thread to answer, as `list_comments` reports it"
    )

    field(:body, :string, required: true, description: "What the reply says")
  end

  @impl true
  def execute(%{comment_id: id, body: body} = params, frame) do
    with {:ok, session} <- Tools.check_session(Map.get(params, :session)),
         {:ok, index} <- Tools.index(),
         {:ok, thread} <- reply(session, id, body) do
      Tools.reply(frame, Shape.thread_map(thread, index))
    else
      {:error, reason} -> Tools.error(frame, reason)
    end
  end

  defp reply(session, id, body) do
    with {:ok, _thread} <- Comments.fetch(id, session),
         {:ok, thread} <- Comments.reply(id, %{body: body, author: "agent"}) do
      {:ok, thread}
    else
      :error -> {:error, "unknown comment: #{id}"}
      {:error, :unknown} -> {:error, "unknown comment: #{id}"}
      {:error, :invalid} -> {:error, "body must not be blank"}
    end
  end
end
