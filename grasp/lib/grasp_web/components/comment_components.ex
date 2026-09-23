defmodule GraspWeb.CommentComponents do
  @moduledoc """
  A review thread and the box that writes into it, as the card draws them under a line.

  A thread reads as prose sitting inside a block of code, so it is rendered as a sibling of
  the line it belongs to rather than inside it: the line keeps its monospace, preformatted
  layout and the thread sets its own.

  Resolved threads collapse to a single line. A resolution is a statement that the
  conversation is over, and a card whose every settled argument is still spelled out in full
  buries the code it was written about; the toggle keeps the thread one click away.

  Each comment and reply has an edit action, which draws the box in place of the text it
  rewrites, holding that text, and an entry once rewritten says so beside its time.

  A published thread carries a link to the review comment it was posted as, beside the
  actions that act on it, so the conversation on the pull request is one click from the
  conversation on the card.

  The composer's text is the browser's alone. The textarea is `phx-update="ignore"` so a
  patch arriving mid-sentence cannot rewrite what is being typed, and its id names the
  anchor the box was opened at — card, side, anchor line and the thread it replies to — so a
  draft belongs to the one place it was written and never reappears under another line. A new
  thread's box names the lines it will cover, and neither end of that range is part of the
  id: stretching the selection either way is the same box, and keeps the half-written
  sentence in it.
  """

  use GraspWeb, :html

  attr :thread, :map, required: true
  attr :card_id, :integer, required: true
  attr :expanded, :boolean, default: false

  attr :aside, :atom,
    doc:
      "why the thread is drawn in the card's footer rather than under a line: `:outdated` " <>
        "when the anchor no longer finds its line, `:hidden` when the view draws no line on " <>
        "its side",
    values: [nil, :outdated, :hidden],
    default: nil

  attr :composing, :map, doc: "the open composer, which may be this thread's reply", default: nil

  @doc """
  One thread: its comments oldest first, the actions that act on it, and the reply box while
  it is open on this thread.
  """
  def thread(assigns) do
    thread = assigns.thread

    entries = [
      entry(thread, nil) | Enum.map(thread.replies, &entry(&1, &1.id))
    ]

    assigns =
      assign(assigns,
        entries: entries,
        collapsed?: thread.resolved and not assigns.expanded,
        summary: "Resolved · #{count(length(entries))}",
        replying?: is_map(assigns.composing) and assigns.composing.reply_to == thread.id,
        editing: editing(assigns.composing, thread.id)
      )

    ~H"""
    <div
      id={"thread-#{@thread.id}"}
      class={[
        "thread",
        @thread.resolved && "thread--resolved",
        @aside && "thread--outdated"
      ]}
      data-comment-id={@thread.id}
      data-resolved={to_string(@thread.resolved)}
    >
      <p :if={@aside} class="thread__snippet">
        <span class="thread__label">{aside_label(@aside, @thread)}</span>
        <code>{@thread.snippet}</code>
      </p>
      <button
        :if={@collapsed?}
        class="thread__toggle"
        phx-click="toggle_thread"
        phx-value-id={@thread.id}
      >{@summary}</button>
      <%= if not @collapsed? do %>
        <div :for={entry <- @entries} class="comment" data-author={entry.author}>
          <span class="comment__author">{author(entry.author)}</span>
          <time datetime={entry.created_at}>{stamp(entry.created_at)}</time>
          <span
            :if={entry.edited_at}
            class="comment__edited"
            title={"Edited " <> stamp(entry.edited_at)}
          >edited</span>
          <button
            class="comment__edit"
            phx-click="comment_edit"
            phx-value-card={@card_id}
            phx-value-id={@thread.id}
            phx-value-reply={entry.reply_id}
            title="Edit"
          >edit</button>
          <button
            class="comment__delete"
            phx-click="comment_delete"
            phx-value-id={@thread.id}
            phx-value-reply={entry.reply_id}
            title="Delete"
          >×</button>
          <%= if @editing == {:ok, entry.reply_id} do %>
            <.composer
              composing={@composing}
              card_id={@card_id}
              id={"edit-#{@thread.id}-#{entry.reply_id || "thread"}"}
              body={entry.body}
            />
          <% else %>
            <p class="comment__body">{entry.body}</p>
          <% end %>
        </div>
        <div class="thread__actions">
          <button phx-click="comment_reply" phx-value-card={@card_id} phx-value-id={@thread.id}>
            reply
          </button>
          <button
            phx-click="comment_resolve"
            phx-value-id={@thread.id}
            phx-value-resolved={to_string(!@thread.resolved)}
          >
            {if @thread.resolved, do: "reopen", else: "resolve"}
          </button>
          <button :if={@thread.resolved} phx-click="toggle_thread" phx-value-id={@thread.id}>
            hide
          </button>
          <a
            :if={@thread.github}
            class="thread__github"
            href={@thread.github.url}
            target="_blank"
            rel="noopener"
          >on GitHub</a>
        </div>
        <.composer :if={@replying?} composing={@composing} card_id={@card_id} />
      <% end %>
    </div>
    """
  end

  attr :composing, :map, required: true
  attr :card_id, :integer, required: true

  attr :id, :string,
    doc: "the box's id when it rewrites an entry rather than writing one",
    default: nil

  attr :body, :string, doc: "the text a rewrite starts from", default: nil

  @doc """
  The box a comment is written in, naming in its markup the anchor it was opened at: the
  view answers the submit from its own record of where the box stands, and the fields are
  what a reader — or a test — sees that record as.
  """
  def composer(assigns) do
    composing = assigns.composing

    id =
      assigns.id ||
        "composer-#{assigns.card_id}-#{composing.side}-#{composing.anchor}-#{composing.reply_to || "new"}"

    edit? = assigns.body != nil

    assigns =
      assign(assigns,
        id: id,
        edit?: edit?,
        reply?: composing.reply_to != nil,
        lines: heading(composing)
      )

    ~H"""
    <form id={@id} class="composer" phx-submit="comment_save" phx-hook="Composer">
      <p :if={not @reply? and not @edit?} class="composer__lines">{@lines}</p>
      <input type="hidden" name="card" value={@card_id} />
      <input type="hidden" name="side" value={@composing.side} />
      <input type="hidden" name="line" value={@composing.line} />
      <input type="hidden" name="reply_to" value={@composing.reply_to} />
      <textarea
        name="body"
        id={"#{@id}-body"}
        rows="3"
        placeholder={if @reply?, do: "Reply…", else: "Leave a comment…"}
        aria-label="Comment"
        phx-update="ignore"
      >{@body}</textarea>
      <button type="submit">{if @edit?, do: "Save", else: "Comment"}</button>
      <button type="button" phx-click="comment_cancel">Cancel</button>
    </form>
    """
  end

  defp entry(comment, reply_id) do
    %{
      reply_id: reply_id,
      author: comment.author,
      body: comment.body,
      created_at: comment.created_at,
      edited_at: Map.get(comment, :edited_at)
    }
  end

  # The entry of this thread the open box rewrites, as `{:ok, reply_id}` with `nil` for the
  # thread's own comment, or `:none` when the box is not rewriting any of this thread.
  defp editing(%{edit: %{thread: thread_id, reply: reply_id}}, thread_id), do: {:ok, reply_id}
  defp editing(_composing, _thread_id), do: :none

  # Why a thread sits in the card's footer instead of under a line. A thread the view simply
  # draws no line for — a comment on the base side, in a card reading as source — is still
  # current, and is named for the side it was written on rather than reported as stale.
  defp aside_label(:hidden, thread), do: "Old · #{lines_label(thread)}"
  defp aside_label(:outdated, thread), do: "Outdated · #{lines_label(thread)}"

  # A thread names the lines it was written on, whether that is one line or a range of them.
  defp lines_label(%{end_line: nil} = thread), do: "L#{thread.line}"
  defp lines_label(thread), do: "L#{thread.line}–L#{thread.end_line}"

  # What the box says it is about, so the range a drag selected is readable once the pointer
  # is gone and the tint is the only other trace of it.
  defp heading(%{end_line: nil} = composing), do: "Line #{composing.line}"
  defp heading(composing), do: "Lines #{composing.line}–#{composing.end_line}"

  # The two writers a thread can hold, named as the reviewer would say them rather than as
  # the store records them.
  defp author("human"), do: "you"
  defp author("agent"), do: "claude"
  defp author(other), do: other

  defp count(1), do: "1 comment"
  defp count(n), do: "#{n} comments"

  # Times are stored as UTC ISO 8601. A stamp the store wrote in another shape is printed as
  # it stands: a comment is worth more than the formatting of its date.
  defp stamp(created_at) do
    case DateTime.from_iso8601(created_at) do
      {:ok, at, _offset} -> Calendar.strftime(at, "%b %-d, %H:%M") <> " UTC"
      {:error, _reason} -> created_at
    end
  end
end
