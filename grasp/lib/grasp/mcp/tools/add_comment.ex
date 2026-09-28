defmodule Grasp.MCP.Tools.AddComment do
  @moduledoc """
  Write a review comment on a line, or a range of lines, of a function, as the agent. The
  thread appears in the reviewer's gutter beside that code, next to the human's own comments,
  and belongs to the review session it is written in: that session's viewer shows it, and
  no other does. It outlives the canvas — closing the card does not lose it — and goes when
  the session is deleted.

  Use it to leave a finding where the code is, rather than in prose the reviewer has to map
  back onto the file: one thread per finding, on the line it is about. The line is numbered
  as `get_function` shows the source, so read the function first and write on a line it
  actually has; a line outside the function is an error naming the range.

  `end_line` covers several lines at once, for a finding that is about a whole clause or
  block rather than about one line of it. It belongs to the same side as `line` and has to
  come after it, and the thread then reads on the pull request as a multi-line comment.

  `side` is `new` for the branch's code and `old` for the base version of a function the
  branch modified, which is how a comment lands on a line the branch deleted.
  """

  use Anubis.Server.Component, type: :tool

  alias Grasp.Comments
  alias Grasp.MCP.Comments, as: Shape
  alias Grasp.MCP.Tools
  alias Grasp.Session

  @sides ~w(new old)

  @session_field Tools.comment_session_field_description()

  schema do
    field(:session, :string,
      required: true,
      description: @session_field
    )

    field(:function_id, :string,
      required: true,
      description:
        "The function to comment on, `Module.fun/arity`; a test's id quotes its name, as in `SampleApp.CheckTest.\"test counts\"/1`"
    )

    field(:line, :integer,
      required: true,
      description:
        "The line to write on, numbered as the source is: the `new` side from the " <>
          "function's first line, the `old` side from 1"
    )

    field(:end_line, :integer,
      description: "The last line of a range, numbered as `line` is; omit for one line"
    )

    field(:body, :string, required: true, description: "What the comment says")

    field(:side, :string,
      default: "new",
      description:
        "`new` for the branch's code, `old` for the base version of a modified " <>
          "function; default `new`"
    )
  end

  @impl true
  def execute(%{function_id: function_id, line: line, body: body} = params, frame) do
    end_line = Map.get(params, :end_line)

    with {:ok, session} <- Tools.check_session(Map.get(params, :session)),
         {:ok, index} <- Tools.index(),
         {:ok, side} <- side(Map.get(params, :side, "new")),
         {:ok, record} <- Tools.fetch_function(index, function_id),
         :ok <- Shape.check_line(record, side, line),
         :ok <- check_end_line(record, side, line, end_line),
         {:ok, thread} <- add(session, record, side, line, end_line, body) do
      Tools.reply(frame, Shape.thread_map(thread, index))
    else
      {:error, reason} -> Tools.error(frame, reason)
    end
  end

  defp side(side) when side in @sides, do: {:ok, side}
  defp side(side), do: {:error, ~s(side must be "new" or "old", not "#{side}")}

  # Both ends of a range are lines of the function, so the far end is checked the same way
  # the near one is and the agent reads the same sentence about either.
  defp check_end_line(_record, _side, _line, nil), do: :ok

  defp check_end_line(record, side, line, end_line) when end_line > line,
    do: Shape.check_line(record, side, end_line)

  defp check_end_line(_record, _side, line, end_line),
    do: {:error, "end_line #{end_line} must come after line #{line}"}

  # The snippet is read off the record now, since it is the text the comment is about and
  # the line it sits on may be edited before anyone reads the thread. A range records its
  # first line, which is the line the thread is anchored by. The session is started once the
  # thread is written, so a session written into is one the session menu lists and deletes,
  # and a refused call leaves the viewer's sessions as they were.
  defp add(session, record, side, line, end_line, body) do
    attrs = %{
      session: session,
      function_id: record["id"],
      side: side,
      line: line,
      end_line: end_line,
      body: body,
      author: "agent",
      snippet: Comments.snippet(record, side, line)
    }

    case Comments.add(attrs) do
      {:ok, thread} ->
        :ok = Session.ensure(session)
        {:ok, thread}

      {:error, :invalid} ->
        {:error, "body must not be blank"}
    end
  end
end
