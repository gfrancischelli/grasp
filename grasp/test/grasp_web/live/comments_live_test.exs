defmodule GraspWeb.CommentsLiveTest do
  use GraspWeb.ConnCase, async: true

  alias Grasp.Comments
  alias Grasp.Session

  @badge "SampleAppWeb.GreetHTML.badge/1"
  @greet "SampleApp.Greeter.greet/2"
  @shout "SampleApp.Formatter.shout/1"

  setup %{conn: conn} do
    name = "c-#{System.unique_integer([:positive])}"
    {:ok, view, _html} = live(conn, "/s/#{name}")
    %{view: view, name: name}
  end

  test "a line's gutter opens a composer, and the comment lands under that line", %{
    view: view,
    name: name
  } do
    Session.open_root(name, @greet)
    body = unique("the default argument hides an arity")

    view |> element("#card-1 .line[data-line='6'] .ln") |> render_click()

    assert has_element?(view, "#card-1 form.composer input[name='line'][value='6']")
    assert has_element?(view, "#card-1 form.composer input[name='side'][value='new']")

    view |> form("#card-1 form.composer", %{"body" => body}) |> render_submit()

    refute has_element?(view, "#card-1 form.composer")
    assert has_element?(view, "#card-1 .thread .comment[data-author='human']")
    assert has_element?(view, "#card-1 .thread .comment__author", "you")

    html = card(view)
    assert before?(html, ~s(data-line="6"), body)
    assert before?(html, body, ~s(data-line="7"))
  end

  test "a range of lines takes one comment, drawn under its last line", %{view: view, name: name} do
    Session.open_root(name, @badge)
    body = unique("these three lines are one thought")

    render_click(view, "comment_start", %{
      "card" => "1",
      "side" => "new",
      "line" => "9",
      "end_line" => "11"
    })

    assert has_element?(view, "#card-1 .composer__lines", "Lines 9–11")
    assert has_element?(view, "#card-1 form.composer input[name='line'][value='9']")

    view |> form("#card-1 form.composer", %{"body" => body}) |> render_submit()

    id = thread_id(body)
    assert %{line: 9, end_line: 11} = Comments.fetch(id) |> then(fn {:ok, thread} -> thread end)

    # No other test writes on this function, so every tinted line of the card is this
    # thread's own.
    html = card(view)
    assert html =~ ~s|data-line="9" data-commented="true"|
    assert html =~ ~s|data-line="10" data-commented="true"|
    assert html =~ ~s|data-line="11" data-commented="true"|
    refute html =~ ~s|data-line="8" data-commented|
    refute html =~ ~s|data-line="12" data-commented|

    assert before?(html, ~s(data-line="11"), body)
    assert before?(html, body, ~s(data-line="12"))

    assert has_element?(
             view,
             "#entries .entry--comment[phx-value-id='#{id}'] .entry__where",
             "badge/1 · L9–L11"
           )
  end

  test "Shift stretches the open composer to the line clicked", %{view: view, name: name} do
    Session.open_root(name, @greet)

    view |> element("#card-1 .line[data-line='9'] .ln") |> render_click()
    assert has_element?(view, "#card-1 .composer__lines", "Line 9")

    render_click(view, "comment_start", %{
      "card" => "1",
      "side" => "new",
      "line" => "11",
      "shift" => true
    })

    assert has_element?(view, "#card-1 .composer__lines", "Lines 9–11")

    assert composing(view) ==
             %{card: 1, side: "new", anchor: 9, line: 9, end_line: 11, reply_to: nil, edit: nil}

    # The anchor is where the composer was opened, so a Shift click above it runs the range
    # the other way rather than off the composer's far end.
    render_click(view, "comment_start", %{
      "card" => "1",
      "side" => "new",
      "line" => "7",
      "shift" => true
    })

    assert has_element?(view, "#card-1 .composer__lines", "Lines 7–9")

    # Every stretch runs from the same anchor, so Shift-clicking the anchor itself is what
    # takes the box back to the one line it was opened on.
    render_click(view, "comment_start", %{
      "card" => "1",
      "side" => "new",
      "line" => "9",
      "shift" => true
    })

    assert has_element?(view, "#card-1 .composer__lines", "Line 9")
  end

  test "stretching a composer upwards keeps the box the draft was typed in", %{
    view: view,
    name: name
  } do
    Session.open_root(name, @greet)

    view |> element("#card-1 .line[data-line='9'] .ln") |> render_click()
    assert has_element?(view, "#card-1 form.composer#composer-1-new-9-new")

    render_click(view, "comment_start", %{
      "card" => "1",
      "side" => "new",
      "line" => "7",
      "shift" => true
    })

    assert has_element?(view, "#card-1 .composer__lines", "Lines 7–9")
    assert has_element?(view, "#card-1 form.composer#composer-1-new-9-new")
    refute has_element?(view, "#card-1 form.composer#composer-1-new-7-new")
  end

  test "a line the function has not got opens no composer over it", %{view: view, name: name} do
    Session.open_root(name, @greet)

    render_click(view, "comment_start", %{
      "card" => "1",
      "side" => "new",
      "line" => "8",
      "end_line" => "9999"
    })

    assert has_element?(view, "#card-1 .composer__lines", "Line 8")

    view |> form("#card-1 form.composer", %{"body" => unique("only one line")}) |> render_submit()

    assert [%{line: 8, end_line: nil}] =
             Comments.list(function_id: @greet, include_resolved: true)
             |> Enum.filter(&(&1.body =~ "only one line"))

    render_click(view, "comment_start", %{"card" => "1", "side" => "new", "line" => "9999"})
    refute has_element?(view, "#card-1 form.composer")
  end

  test "a thread is replied to, resolved, expanded and taken apart again", %{
    view: view,
    name: name
  } do
    Session.open_root(name, @greet)
    body = unique("this clause never runs")
    reply = unique("it does when loud? is true")

    view |> element("#card-1 .line[data-line='8'] .ln") |> render_click()
    view |> form("#card-1 form.composer", %{"body" => body}) |> render_submit()

    id = thread_id(body)

    view |> element("#thread-#{id} .thread__actions button", "reply") |> render_click()
    assert has_element?(view, "#thread-#{id} form.composer textarea[placeholder='Reply…']")

    view |> form("#thread-#{id} form.composer", %{"body" => reply}) |> render_submit()

    assert has_element?(view, "#thread-#{id} .comment__body", body)
    assert has_element?(view, "#thread-#{id} .comment__body", reply)

    view |> element("#thread-#{id} .thread__actions button", "resolve") |> render_click()

    assert has_element?(view, "#thread-#{id}[data-resolved='true'] .thread__toggle")
    assert has_element?(view, "#thread-#{id} .thread__toggle", "Resolved · 2 comments")
    refute has_element?(view, "#thread-#{id} .comment__body")

    view |> element("#thread-#{id} .thread__toggle") |> render_click()

    assert has_element?(view, "#thread-#{id} .comment__body", reply)
    assert has_element?(view, "#thread-#{id} .thread__actions button", "reopen")

    [%{id: reply_id}] = Comments.fetch(id) |> then(fn {:ok, thread} -> thread.replies end)

    view
    |> element("#thread-#{id} .comment__delete[phx-value-reply='#{reply_id}']")
    |> render_click()

    assert has_element?(view, "#thread-#{id} .comment__body", body)
    refute has_element?(view, "#thread-#{id} .comment__body", reply)

    view |> element("#thread-#{id} .thread__actions button", "reply") |> render_click()
    assert has_element?(view, "#thread-#{id} form.composer")

    view |> element("#thread-#{id} .comment__delete") |> render_click()

    refute has_element?(view, "#thread-#{id}")
    assert composing(view) == nil
  end

  test "a comment and a reply are edited in place", %{view: view, name: name} do
    Session.open_root(name, @greet)
    body = unique("this clause never runs")
    reply = unique("it does when loud? is true")

    view |> element("#card-1 .line[data-line='8'] .ln") |> render_click()
    view |> form("#card-1 form.composer", %{"body" => body}) |> render_submit()
    id = thread_id(body)
    view |> element("#thread-#{id} .thread__actions button", "reply") |> render_click()
    view |> form("#thread-#{id} form.composer", %{"body" => reply}) |> render_submit()
    [%{id: reply_id}] = Comments.fetch(id) |> then(fn {:ok, thread} -> thread.replies end)

    view |> element("#thread-#{id} .comment__edit:not([phx-value-reply])") |> render_click()

    assert has_element?(view, "#thread-#{id} form.composer#edit-#{id}-thread textarea", body)
    refute has_element?(view, "#thread-#{id} .comment__body", body)

    view |> element("#edit-#{id}-thread button", "Cancel") |> render_click()
    assert has_element?(view, "#thread-#{id} .comment__body", body)
    refute has_element?(view, "#thread-#{id} .comment__edited")

    view |> element("#thread-#{id} .comment__edit:not([phx-value-reply])") |> render_click()
    view |> form("#edit-#{id}-thread", %{"body" => "  "}) |> render_submit()
    assert has_element?(view, "#edit-#{id}-thread")

    edited = unique("this clause runs when loud? is true")
    view |> form("#edit-#{id}-thread", %{"body" => edited}) |> render_submit()

    refute has_element?(view, "#edit-#{id}-thread")
    assert has_element?(view, "#thread-#{id} .comment__body", edited)
    refute has_element?(view, "#thread-#{id} .comment__body", body)
    assert has_element?(view, "#thread-#{id} .comment__edited", "edited")
    assert has_element?(view, "#thread-#{id} .comment__body", reply)

    view
    |> element("#thread-#{id} .comment__edit[phx-value-reply='#{reply_id}']")
    |> render_click()

    assert has_element?(view, "#edit-#{id}-#{reply_id} textarea", reply)

    answer = unique("only when loud? is true")
    view |> form("#edit-#{id}-#{reply_id}", %{"body" => answer}) |> render_submit()

    assert has_element?(view, "#thread-#{id} .comment__body", answer)
    refute has_element?(view, "#thread-#{id} .comment__body", reply)
    assert {:ok, %{body: ^edited, replies: [%{body: ^answer}]}} = Comments.fetch(id)
    assert composing(view) == nil
  end

  test "a blank body keeps the composer rather than writing an empty comment", %{
    view: view,
    name: name
  } do
    Session.open_root(name, @greet)
    written = threads_at(@greet, 10)

    view |> element("#card-1 .line[data-line='10'] .ln") |> render_click()
    view |> form("#card-1 form.composer", %{"body" => "   "}) |> render_submit()

    assert has_element?(view, "#card-1 form.composer input[name='line'][value='10']")
    assert threads_at(@greet, 10) == written
  end

  test "a comment whose line no longer reads as it did is kept in the card's footer", %{
    view: view,
    name: name
  } do
    Session.open_root(name, @greet)
    body = unique("written against a line that has moved")

    {:ok, thread} =
      Comments.add(%{
        function_id: @greet,
        side: "new",
        line: 7,
        body: body,
        author: "human",
        snippet: "def greet(name, shouted?) do"
      })

    assert has_element?(view, "#card-1 footer.card__outdated #thread-#{thread.id}")

    assert has_element?(
             view,
             "#thread-#{thread.id}.thread--outdated .thread__snippet",
             "Outdated · L7"
           )

    refute has_element?(view, "#card-1 .card__body #thread-#{thread.id}")

    {:ok, on_a_base} =
      Comments.add(%{
        function_id: @greet,
        side: "old",
        line: 3,
        body: unique("written on a base version this function has not got"),
        author: "human",
        snippet: "def greet(name) do"
      })

    assert has_element?(view, "#thread-#{on_a_base.id} .thread__snippet", "Outdated · L3")
  end

  test "comments belong to the project, so another session shows them", %{
    conn: conn,
    view: view,
    name: name
  } do
    Session.open_root(name, @greet)
    body = unique("the wrap call is the interesting one")

    view |> element("#card-1 .line[data-line='9'] .ln") |> render_click()
    view |> form("#card-1 form.composer", %{"body" => body}) |> render_submit()

    other_name = "c-#{System.unique_integer([:positive])}"
    {:ok, other, _html} = live(conn, "/s/#{other_name}")
    Session.open_root(other_name, @greet)

    assert has_element?(other, "#card-1 .thread .comment__body", body)
    refute has_element?(other, "#card-1 form.composer")
  end

  test "a line the branch deleted takes a comment on the base side", %{view: view, name: name} do
    Session.open_root(name, @shout)
    body = unique("this is the clause that went")

    view |> element("#card-1 .line[data-op='del'] .ln") |> render_click()

    assert has_element?(view, "#card-1 form.composer input[name='side'][value='old']")
    assert has_element?(view, "#card-1 form.composer input[name='line'][value='3']")

    view |> form("#card-1 form.composer", %{"body" => body}) |> render_submit()

    assert has_element?(view, "#card-1 .thread .comment__body", body)

    html = card(view)
    assert before?(html, ~s(data-base-line="3"), body)
    assert before?(html, body, ~s(data-line="10"))
  end

  test "a comment on a deleted line waits in the footer while the card reads as source", %{
    view: view,
    name: name
  } do
    Session.open_root(name, @shout)
    body = unique("the branch dropped this clause")

    view |> element("#card-1 .line[data-op='del'] .ln") |> render_click()
    view |> form("#card-1 form.composer", %{"body" => body}) |> render_submit()

    id = thread_id(body)
    assert has_element?(view, "#card-1 .card__body #thread-#{id}")
    refute has_element?(view, "#card-1 footer.card__outdated #thread-#{id}")

    view |> element("#card-1 .card__view") |> render_click()

    assert has_element?(view, "#card-1[data-view='source']")
    assert has_element?(view, "#card-1 footer.card__outdated #thread-#{id}")
    assert has_element?(view, "#thread-#{id} .thread__snippet", "Old · L3")
  end

  defp unique(text), do: "#{text} ##{System.unique_integer([:positive])}"

  # The store holds the whole project's threads, other tests' included, so what a submission
  # did is asked of the anchor this test writes at rather than of the store as a whole.
  defp threads_at(function_id, line) do
    Comments.list(function_id: function_id, include_resolved: true)
    |> Enum.filter(&(&1.side == "new" and &1.line == line))
    |> Enum.map(& &1.id)
  end

  # The composer's anchor is the view's own state and shows in no markup once the thread it
  # replies to is gone, so this is the only place a test can see it was let go of.
  defp composing(view), do: :sys.get_state(view.pid).socket.assigns.composing

  defp thread_id(body) do
    thread = Enum.find(Comments.list(include_resolved: true), &(&1.body == body))
    assert thread, "no thread was written with the body #{inspect(body)}"
    thread.id
  end

  # The sidebar lists every open thread of the project, so where a thread falls relative to
  # a line is a question about the card alone.
  defp card(view), do: view |> element("#card-1") |> render()

  # Where two strings fall in the card's markup, which is how a thread is shown to hang off
  # the line above it without depending on what other threads the store happens to hold.
  defp before?(html, first, second) do
    case {:binary.match(html, first), :binary.match(html, second)} do
      {{at, _length}, {then, _then_length}} -> at < then
      _missing -> false
    end
  end
end
