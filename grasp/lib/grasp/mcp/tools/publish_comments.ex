defmodule Grasp.MCP.Tools.PublishComments do
  @moduledoc """
  Post the review comments written in one review session onto the project's pull request,
  as review comments with their replies under them. Another session's threads are another
  review's, and are not posted.

  A thread whose line the pull request's diff covers goes on that line; one written on a
  line the diff does not show, or on the base version of a modified function, goes on the
  file with the function and line it was written on at the top of it, since GitHub takes a
  line comment only inside the diff. Threads already published are skipped, so publishing
  again posts only what has been written since.

  The answer says what happened to every thread: `published` with the kind each went as,
  `skipped` with why, `failed` with what GitHub said, and `warnings` for anything that came
  through but not cleanly — a reply that did not post, or an index built at a commit other
  than the pull request's head, which is when the line numbers can be off.
  """

  use Anubis.Server.Component, type: :tool

  alias Grasp.Comments.Publisher
  alias Grasp.MCP.Tools

  @session_field Tools.comment_session_field_description()

  schema do
    field(:session, :string,
      required: true,
      description: @session_field
    )

    field(:pull_request, :integer,
      description:
        "The number of the pull request to publish to; the current branch's pull request " <>
          "is used when omitted"
    )

    field(:include_resolved, :boolean,
      default: false,
      description: "Publish resolved threads as well; default false"
    )
  end

  @impl true
  def execute(params, frame) do
    with {:ok, session} <- Tools.check_session(Map.get(params, :session)),
         {:ok, index} <- Tools.index(),
         {:ok, report} <- Publisher.publish(index, publish_opts(session, params)) do
      Tools.reply(frame, report_map(report))
    else
      {:error, reason} -> Tools.error(frame, reason)
    end
  end

  defp publish_opts(session, params) do
    [
      session: session,
      pull_request: Map.get(params, :pull_request),
      include_resolved: Map.get(params, :include_resolved, false)
    ]
  end

  defp report_map(report) do
    %{
      "pull_request" => %{
        "number" => report.pull_request.number,
        "url" => report.pull_request.url
      },
      "published" =>
        Enum.map(report.published, fn published ->
          %{
            "comment_id" => published.comment_id,
            "url" => published.url,
            "kind" => Atom.to_string(published.kind)
          }
        end),
      "skipped" =>
        Enum.map(report.skipped, &%{"comment_id" => &1.comment_id, "reason" => &1.reason}),
      "failed" => Enum.map(report.failed, &%{"comment_id" => &1.comment_id, "error" => &1.error}),
      "warnings" => report.warnings
    }
  end
end
