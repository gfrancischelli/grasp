defmodule Grasp.MCP.Tools.ListComments do
  @moduledoc """
  Read the review comments written in one review session — the reviewer's, and the ones the
  agent left itself. A thread belongs to the session it was written in, so another
  session's threads are not listed. Each thread carries the function and line it was
  written on, the text of that line, its author and its replies.

  The first call when picking up a review: it says what the reviewer is asking about, and
  each thread can then be answered with `reply_comment` and closed with `resolve_comment`.
  Open threads only unless `include_resolved` is set, since a resolved thread is a
  conversation already finished.

  A thread is placed against the code as it now reads: `status` is `anchored` when the line
  it was written on was found — at `anchored_line`, which moves as the file is edited —
  `outdated` when that line is gone, and `orphan` when the function itself is. An
  `outdated` thread still names what the reviewer wanted changed, so read it rather than
  skip it.
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

    field(:function_id, :string,
      description:
        "Keep only the threads on this function, `Module.fun/arity`; a test's id quotes its name, as in `SampleApp.CheckTest.\"test counts\"/1`"
    )

    field(:include_resolved, :boolean,
      default: false,
      description: "Include threads already resolved; default false"
    )
  end

  @impl true
  def execute(params, frame) do
    with {:ok, session} <- Tools.check_session(Map.get(params, :session)),
         {:ok, index} <- Tools.index() do
      threads =
        Comments.list(
          session: session,
          function_id: function_id(index, Map.get(params, :function_id)),
          include_resolved: Map.get(params, :include_resolved, false)
        )

      Tools.reply(frame, %{
        "total" => length(threads),
        "comments" => Enum.map(threads, &Shape.thread_map(&1, index))
      })
    else
      {:error, response} -> Tools.error(frame, response)
    end
  end

  # Threads are stored under the canonical id, the one a definition with default arguments
  # is indexed by, so a filter written with any arity that definition answers to finds them.
  # An id the index does not know is left as it stands and matches nothing.
  defp function_id(_index, nil), do: nil

  defp function_id(index, id) do
    case Grasp.Index.fetch_function(index, id) do
      {:ok, record} -> record["id"]
      :error -> id
    end
  end
end
