defmodule Grasp.MCP.Comments do
  @moduledoc """
  Shapes comment threads for the MCP tools, and checks the line a comment is being written
  on.

  A thread names the line it was written on, and the code under it moves, so the number it
  carries is not on its own where the thread now belongs. Every thread an agent reads is
  therefore placed against the record the index currently holds — `"status"` says whether
  the line was found and `"anchored_line"` where, next to the `"line"` the thread was
  written on, so an agent can tell a remark still sitting on its code from one whose line
  has been edited away.

  A line is checked before a comment is written rather than after, because a thread on a
  line outside the function would be stored and then never placed anywhere: the reply names
  the function's own range instead, which is the range the agent should have read from
  `get_function`.
  """

  alias Grasp.Comments
  alias Grasp.Comments.Anchor

  @doc """
  `thread` as a JSON map, placed against the function record `index` holds for it.

  Beyond the thread's own fields it carries `"file"` (the record's, `nil` when the function
  has left the index), `"status"` — `"anchored"`, `"outdated"` for a line that is no longer
  there, `"orphan"` for a function that is gone — `"anchored_line"`, the line the thread
  now sits on, `nil` unless it is anchored, and `"github_url"`, where the thread reads on
  the pull request, `nil` while it has not been published. `"end_line"` is the last line of
  a thread written over a range and `nil` for one written on a single line; it is counted
  from `"line"` rather than from `"anchored_line"`, so a moved range is `"anchored_line"`
  through `"anchored_line" + "end_line" - "line"`.
  """
  @spec thread_map(Comments.thread(), Grasp.Index.t()) :: map()
  def thread_map(thread, %Grasp.Index{} = index) do
    record = record(index, thread.function_id)

    {status, anchored_line} =
      case Anchor.place(thread, record) do
        {_side, line} -> {"anchored", line}
        placement -> {Atom.to_string(placement), nil}
      end

    %{
      "id" => thread.id,
      "function_id" => thread.function_id,
      "file" => record && record["file"],
      "side" => thread.side,
      "line" => thread.line,
      "end_line" => thread.end_line,
      "anchored_line" => anchored_line,
      "status" => status,
      "snippet" => thread.snippet,
      "body" => thread.body,
      "author" => thread.author,
      "created_at" => thread.created_at,
      "edited_at" => thread.edited_at,
      "resolved" => thread.resolved,
      "github_url" => thread.github && thread.github.url,
      "replies" => Enum.map(thread.replies, &reply_map/1)
    }
  end

  @doc """
  Whether line `line` of `record` on `side` is a line a comment can be written on.

  The `"new"` side is numbered by the record's span, as the cards and `get_function` number
  it; the `"old"` side is numbered from 1 over the base version, which only a function the
  branch modified has. The error message names the function and the range it does have.
  """
  @spec check_line(map(), Comments.side(), integer()) :: :ok | {:error, String.t()}
  def check_line(record, "new", line) do
    # A record whose span stops at the start line is read as that one line: a line the agent
    # cannot comment on comes back as the error naming the range, which is what it can act
    # on, rather than as a crash in the tool call.
    case record["span"] do
      %{"start_line" => first, "end_line" => last} -> in_range(record, line, first, last)
      %{"start_line" => first} -> in_range(record, line, first, first)
    end
  end

  def check_line(record, "old", line) do
    case Anchor.lines(record, "old") do
      nil -> {:error, ~s(#{record["id"]} has no base version to comment on; use side "new")}
      lines -> in_range(record, line, 1, length(lines))
    end
  end

  defp in_range(_record, line, first, last) when line >= first and line <= last, do: :ok

  defp in_range(record, line, first, last),
    do: {:error, "line #{line} is outside #{record["id"]} (lines #{first}..#{last})"}

  defp record(index, function_id) do
    case Grasp.Index.fetch_function(index, function_id) do
      {:ok, record} -> record
      :error -> nil
    end
  end

  defp reply_map(reply) do
    %{
      "id" => reply.id,
      "author" => reply.author,
      "body" => reply.body,
      "created_at" => reply.created_at,
      "edited_at" => reply.edited_at
    }
  end
end
