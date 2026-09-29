defmodule Grasp.Comments.Publisher do
  @moduledoc """
  Posts the review threads written in the viewer onto a pull request.

  A review read in Grasp ends up where the rest of the team reads reviews. A review is one
  session, and its threads are the ones that session's cards show, so publishing walks that
  session's threads in id order, posts each one as a review comment with its replies under
  it, and stamps the thread with what GitHub answered. The stamp is what makes a second
  publish safe: a thread already carrying one is skipped rather than posted twice, so a
  reviewer can publish, write three more comments and publish again.

  Where a thread lands depends on the pull request's own diff. GitHub accepts a line comment
  only on a line the diff covers, so the diff's hunks are read first and a thread whose line
  falls outside them — or one written on the base side, which has no line on the head commit
  — is posted as a file comment instead, opening with the function and line it was written
  on so nothing about it is lost. A thread on a module card is posted the same way, on the
  lines of the module's moduledoc and under the module's name. A thread written over a range
  goes up as a multi-line comment when the diff covers both of its ends, and on the file when
  it covers only one: half a range is a comment about code its author did not mark. That is
  a degradation rather than a failure: a remark posted on the file is still a remark the
  author reads, and refusing to post it would leave the review half published.

  Nothing is rolled back. A comment GitHub refuses is reported under `failed` and the rest
  of the review still goes; a reply that fails after its comment landed is a warning, because
  the comment it belongs to is already on the pull request and taking it down would lose the
  reviewer's words. The report is what the caller tells the reviewer: what went on its line,
  what went on the file, what did not go at all.
  """

  alias Grasp.Comments
  alias Grasp.GitHub
  alias Grasp.GitHub.Diff
  alias Grasp.Index

  @typedoc "What became of the review: where each thread went, and what could not be posted."
  @type report :: %{
          pull_request: %{number: pos_integer(), url: String.t()},
          published: [%{comment_id: pos_integer(), url: String.t(), kind: :line | :file}],
          skipped: [%{comment_id: pos_integer(), reason: String.t()}],
          failed: [%{comment_id: pos_integer(), error: String.t()}],
          warnings: [String.t()]
        }

  @agent_prefix "claude: "

  @doc """
  Publishes the open review threads of one session to a pull request of the checkout.

  `:session` (required) names the session whose threads are posted: a thread belongs to the
  session it was written in, and another session's threads are another review's.
  `:pull_request` names the pull request by number, and defaults to the one the checkout's
  current branch is open on; `:include_resolved` (false by default) publishes the resolved
  threads as well. The project root the index names has to be a directory on this machine,
  since `gh` runs from it and reads the repository it belongs to.

  An error is only ever the review not being publishable at all — a number that is not a
  pull request number, no checkout, no pull request, no diff. Once those are in hand every
  thread is attempted, and what happened to each is in the report.
  """
  @spec publish(Index.t(), keyword()) :: {:ok, report()} | {:error, String.t()}
  def publish(%Index{} = index, opts) when is_list(opts) do
    session = Keyword.fetch!(opts, :session)
    root = index.project["root"]
    number = opts[:pull_request]

    with :ok <- check_root(root),
         :ok <- check_number(number),
         {:ok, pull_request} <- GitHub.pull_request(root, number),
         {:ok, diff} <- GitHub.diff(root, pull_request.number) do
      ranges = Diff.commentable_lines(diff)

      threads =
        Comments.list(
          session: session,
          include_resolved: Keyword.get(opts, :include_resolved, false)
        )

      report =
        Enum.reduce(
          threads,
          empty(pull_request, head_warnings(index, pull_request)),
          &publish_thread(&1, &2, index, root, pull_request, ranges)
        )

      {:ok, finish(report)}
    end
  end

  defp check_root(nil), do: {:error, "the index names no project root"}

  defp check_root(root) do
    if is_binary(root) and File.dir?(root),
      do: :ok,
      else: {:error, "project root #{root} is not a directory on this machine"}
  end

  # A number `gh` would refuse is refused here instead, so a caller that passed one reads a
  # sentence rather than the way `gh pr view 0` puts it.
  defp check_number(nil), do: :ok
  defp check_number(number) when is_integer(number) and number > 0, do: :ok
  defp check_number(_number), do: {:error, "pull_request must be a positive number"}

  # A short head in the index is the same commit as the full sha `gh` answers with, so the
  # two are compared by prefix rather than by equality. An empty sha is a prefix of
  # everything and would silence the warning, so it counts as a mismatch.
  defp head_warnings(%Index{git: %{"head" => head}}, pull_request) when is_binary(head) do
    if same_commit?(head, pull_request.head_sha) do
      []
    else
      [
        "the index was built at #{head}, the pull request head is #{pull_request.head_sha}; " <>
          "line numbers may be off"
      ]
    end
  end

  defp head_warnings(_index, _pull_request), do: []

  defp same_commit?("", _head_sha), do: false
  defp same_commit?(_head, ""), do: false

  defp same_commit?(head, head_sha),
    do: String.starts_with?(head, head_sha) or String.starts_with?(head_sha, head)

  # Every list is built by prepending and turned round once, in `finish/1`.
  defp empty(pull_request, warnings) do
    %{
      pull_request: %{number: pull_request.number, url: pull_request.url},
      published: [],
      skipped: [],
      failed: [],
      warnings: warnings
    }
  end

  defp finish(report) do
    %{
      report
      | published: Enum.reverse(report.published),
        skipped: Enum.reverse(report.skipped),
        failed: Enum.reverse(report.failed),
        warnings: Enum.reverse(report.warnings)
    }
  end

  defp publish_thread(%{github: github} = thread, report, _index, _root, _pr, _ranges)
       when not is_nil(github),
       do: skip(report, thread.id, "already published")

  defp publish_thread(thread, report, index, root, pull_request, ranges) do
    case Index.fetch_record(index, thread.function_id) do
      :error ->
        fail(report, thread.id, "#{gone(thread.function_id)} is no longer in the index")

      {:ok, record} ->
        post(thread, report, record, root, pull_request, ranges)
    end
  end

  # A function id ends in its arity and a module name never does, which is how a thread on a
  # module card is told apart once its record is gone.
  defp gone(id) do
    if Regex.match?(~r|/\d+$|, id), do: "function", else: "module"
  end

  defp post(thread, report, record, root, pull_request, ranges) do
    path = record["file"]
    kind = kind(thread, path, ranges)

    comment =
      %{
        body: body(thread, record, kind),
        path: path,
        commit_id: pull_request.head_sha,
        kind: kind,
        line: thread.end_line || thread.line
      }
      |> start_line(thread, kind)

    case GitHub.create_review_comment(root, pull_request.number, comment) do
      {:ok, posted} ->
        report
        |> reply_all(thread, root, pull_request, posted)
        |> stamp(thread, posted, kind)

      {:error, error} ->
        fail(report, thread.id, error)
    end
  end

  # A range GitHub would only half accept is posted on the file whole: a comment truncated to
  # the lines the diff happens to show would claim to be about code its author never marked.
  defp kind(%{side: "new"} = thread, path, ranges) do
    commentable = Map.get(ranges, path, [])
    ends = [thread.line, thread.end_line || thread.line]

    if Enum.all?(ends, fn line -> Enum.any?(commentable, &(line in &1)) end),
      do: :line,
      else: :file
  end

  defp kind(_thread, _path, _ranges), do: :file

  # GitHub's `start_line` is the first line of a multi-line comment, so it is only sent for a
  # thread that was written over a range and landed on its lines.
  defp start_line(comment, %{end_line: end_line} = thread, :line) when is_integer(end_line),
    do: Map.put(comment, :start_line, thread.line)

  defp start_line(comment, _thread, _kind), do: comment

  defp body(thread, _record, :line), do: prefixed(thread.author, thread.body)

  defp body(thread, record, :file) do
    [location(thread, record), snippet(thread), prefixed(thread.author, thread.body)]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n\n")
  end

  defp location(%{side: "old", end_line: nil} = thread, record),
    do: "`#{record["id"]}` · deleted line #{thread.line}"

  defp location(%{side: "old"} = thread, record),
    do: "`#{record["id"]}` · deleted lines #{thread.line}–#{thread.end_line}"

  defp location(%{end_line: nil} = thread, record), do: "`#{record["id"]}` · L#{thread.line}"

  defp location(thread, record),
    do: "`#{record["id"]}` · L#{thread.line}–L#{thread.end_line}"

  defp snippet(%{snippet: nil}), do: nil
  defp snippet(thread), do: "> #{thread.snippet}"

  defp prefixed("agent", body), do: @agent_prefix <> body
  defp prefixed(_human, body), do: body

  defp reply_all(report, thread, root, pull_request, posted) do
    Enum.reduce(thread.replies, report, fn reply, report ->
      body = prefixed(reply.author, reply.body)

      case GitHub.reply_review_comment(root, pull_request.number, posted.id, body) do
        {:ok, _reply} ->
          report

        {:error, error} ->
          warn(report, "reply #{reply.id} of comment #{thread.id} was not posted: #{error}")
      end
    end)
  end

  defp stamp(report, thread, posted, kind) do
    report =
      case Comments.mark_published(thread.id, %{id: posted.id, url: posted.url}) do
        {:ok, _thread} ->
          report

        {:error, _reason} ->
          warn(
            report,
            "comment #{thread.id} was posted as #{posted.url} but the thread could not be " <>
              "marked published; publishing again would post it a second time"
          )
      end

    %{
      report
      | published: [%{comment_id: thread.id, url: posted.url, kind: kind} | report.published]
    }
  end

  defp skip(report, id, reason),
    do: %{report | skipped: [%{comment_id: id, reason: reason} | report.skipped]}

  defp fail(report, id, error),
    do: %{report | failed: [%{comment_id: id, error: error} | report.failed]}

  defp warn(report, warning), do: %{report | warnings: [warning | report.warnings]}
end
