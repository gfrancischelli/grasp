defmodule GraspWeb.ChatTest do
  use GraspWeb.ConnCase, async: true

  @greeter "SampleApp.Greeter.greet/2"

  setup %{conn: conn} do
    name = "t-#{System.unique_integer([:positive])}"
    {:ok, view, _html} = live(conn, "/s/#{name}")
    %{view: view, name: name}
  end

  test "the panel toggles from the toolbar and starts hidden", %{view: view} do
    assert has_element?(view, "#chat[hidden]")
    view |> element("#toggle-chat") |> render_click()
    refute has_element?(view, "#chat[hidden]")
    assert has_element?(view, ~s(#chat textarea#chat-prompt[phx-update="ignore"]))
    view |> element("#toggle-chat") |> render_click()
    assert has_element?(view, "#chat[hidden]")
  end

  test "sending a prompt streams the transcript into the panel", %{view: view, name: name} do
    view |> element("#toggle-chat") |> render_click()
    # Subscribed before the run starts: the fake CLI can finish before a later subscribe lands.
    :ok = Grasp.Agent.subscribe(name)
    view |> form("#chat-form", %{"prompt" => "show me greet"}) |> render_submit()
    assert has_element?(view, ~s(#chat .msg[data-type="user"]), "show me greet")

    assert_receive {:agent, ^name, %{running?: false}}, 2_000
    eventually(view, fn -> not has_element?(view, ~s(#chat button[phx-click="chat_stop"])) end)
    log = view |> element("#chat-log") |> render()

    # The block that follows the deltas is the authoritative text, not a second copy of it.
    assert length(String.split(log, "Looking at the flow.")) == 2

    assert has_element?(view, ~s(#chat details.tools summary), "Used 2 tools")
    assert has_element?(view, ~s(#chat .tool[data-status="done"]), ~s(Searched "greet"))
    assert has_element?(view, ~s(#chat .tool[data-status="error"]), "Arranged 3 cards")
    assert has_element?(view, ~s(#chat .tool[data-status="error"] pre), "no such function")
    assert has_element?(view, ~s(#chat .msg[data-type="done"]), "$0.01 · 2 turns · 4.2 s")
    refute has_element?(view, "#chat .chat__status")
    assert has_element?(view, ~s(#chat button[type="submit"]), "Send")
    refute has_element?(view, "#chat button[disabled]", "Send")
  end

  test "a live run shows that the agent is working", %{view: view, name: name} do
    view |> element("#toggle-chat") |> render_click()
    :ok = Grasp.Agent.subscribe(name)
    view |> form("#chat-form", %{"prompt" => "SLOW one"}) |> render_submit()

    # The dots belong to the status line, which stands for the whole run: nothing is
    # inserted into or removed from the log between the events of one run.
    assert has_element?(view, "#chat .chat__status", "Working")
    assert has_element?(view, "#chat .chat__status .dots")
    assert has_element?(view, "#chat .chat__status span[data-elapsed-from]")
    refute has_element?(view, ~s(#chat .msg[data-type="thinking"]))

    assert_receive {:agent, ^name, %{running?: false}}, 2_000
    eventually(view, fn -> not has_element?(view, ~s(#chat button[phx-click="chat_stop"])) end)
    refute has_element?(view, ~s(#chat .msg[data-type="thinking"]))
    refute has_element?(view, "#chat .chat__status")
  end

  test "a tools group stays open until the run ends", %{view: view, name: name} do
    view |> element("#toggle-chat") |> render_click()
    :ok = Grasp.Agent.subscribe(name)
    view |> form("#chat-form", %{"prompt" => "SLOW one"}) |> render_submit()

    eventually(view, fn -> has_element?(view, ~s(#chat details.tools[open])) end)

    assert_receive {:agent, ^name, %{running?: false}}, 2_000
    eventually(view, fn -> not has_element?(view, ~s(#chat button[phx-click="chat_stop"])) end)

    assert has_element?(view, ~s(#chat details.tools))
    refute has_element?(view, ~s(#chat details.tools[open]))
  end

  test "an answer renders as Markdown whose function ids open cards", %{view: view, name: name} do
    view |> element("#toggle-chat") |> render_click()
    :ok = Grasp.Agent.subscribe(name)
    view |> form("#chat-form", %{"prompt" => "show me greet"}) |> render_submit()
    assert_receive {:agent, ^name, %{running?: false}}, 2_000
    eventually(view, fn -> not has_element?(view, ~s(#chat button[phx-click="chat_stop"])) end)

    assert has_element?(view, ~s(#chat .msg[data-type="assistant"] strong), "greet")
    assert has_element?(view, ~s(#chat pre.fence[data-lang="elixir"]))
    assert has_element?(view, ~s(#chat pre.fence span.l-module), "SampleApp")

    # An id the fixture index holds is a button; one it does not stays as written. The button
    # carries the id and no event: the panel's hook, not the answer's markup, names the event.
    assert has_element?(view, ~s(#chat button.fn[data-fn="#{@greeter}"]), @greeter)
    assert has_element?(view, ~s(#chat .msg[data-type="assistant"] button.copy[data-copy="msg"]))
    assert has_element?(view, "#chat code", "Nope.Missing.fun/1")

    # The panel's own buttons inside the log carry events; nothing the model wrote does.
    refute has_element?(view, ~s(#chat-log .msg[data-type="assistant"] [phx-click]))

    log = view |> element("#chat-log") |> render()
    refute log =~ "script"
    refute log =~ "alert(1)"

    # What the hook pushes when that button is clicked.
    view |> element("#chat") |> render_hook("open_root", %{"id" => @greeter})
    assert has_element?(view, ~s(.card[data-function-id="#{@greeter}"]))
  end

  test "the model picker chooses the CLI model for the next run", %{view: view, name: name} do
    view |> element("#toggle-chat") |> render_click()
    assert has_element?(view, ~s(#chat-model-select option[value=""][selected]))

    view |> form("#chat-model", %{"model" => "sonnet"}) |> render_change()
    assert has_element?(view, ~s(#chat-model-select option[value="sonnet"][selected]))

    :ok = Grasp.Agent.subscribe(name)
    view |> form("#chat-form", %{"prompt" => "show me greet"}) |> render_submit()
    assert_receive {:agent, ^name, %{running?: false}}, 2_000
    assert Grasp.Agent.get(name).last_result =~ "--model sonnet"
  end

  test "the mode picker lets the next run edit files", %{view: view, name: name} do
    view |> element("#toggle-chat") |> render_click()
    assert has_element?(view, ~s(#chat-mode-select option[value="read"][selected]))

    view |> form("#chat-mode", %{"mode" => "edit"}) |> render_change()
    assert has_element?(view, ~s(#chat-mode-select option[value="edit"][selected]))
    assert Grasp.Agent.get(name).mode == "edit"

    :ok = Grasp.Agent.subscribe(name)
    view |> form("#chat-form", %{"prompt" => "address the comments"}) |> render_submit()
    assert_receive {:agent, ^name, %{running?: false}}, 2_000
    assert Grasp.Agent.get(name).last_result =~ "Bash(mix:*)"
  end

  test "a mode the agent does not know leaves the chat as it was", %{view: view, name: name} do
    view |> element("#toggle-chat") |> render_click()
    render_change(view, :chat_mode, %{"mode" => "sudo"})

    assert Grasp.Agent.get(name).mode == "read"
    assert has_element?(view, ~s(#chat-mode-select option[value="read"][selected]))
  end

  test "a blank prompt is ignored", %{view: view} do
    view |> element("#toggle-chat") |> render_click()
    view |> form("#chat-form", %{"prompt" => "   "}) |> render_submit()
    refute has_element?(view, ~s(#chat .msg[data-type="user"]))
  end

  test "a failed run shows its log under the error and retries the prompt", %{
    view: view,
    name: name
  } do
    view |> element("#toggle-chat") |> render_click()
    :ok = Grasp.Agent.subscribe(name)
    view |> form("#chat-form", %{"prompt" => "FAIL please"}) |> render_submit()
    assert_receive {:agent, ^name, %{running?: false}}, 2_000
    eventually(view, fn -> not has_element?(view, ~s(#chat button[phx-click="chat_stop"])) end)
    assert has_element?(view, ~s(#chat .msg[data-type="error"]), "status 3")

    assert has_element?(
             view,
             "#chat .chat__failure details[open]",
             "something went wrong on stderr"
           )

    view |> element(~s(#chat button[phx-click="chat_retry"]), "Retry") |> render_click()
    assert_receive {:agent, ^name, %{running?: false}}, 2_000
    eventually(view, fn -> not has_element?(view, ~s(#chat button[phx-click="chat_stop"])) end)

    log = view |> element("#chat-log") |> render()
    assert length(String.split(log, "FAIL please")) == 3
  end

  test "a live run keeps Send for the queue, and Stop empties it", %{view: view, name: name} do
    view |> element("#toggle-chat") |> render_click()
    :ok = Grasp.Agent.subscribe(name)
    view |> form("#chat-form", %{"prompt" => "SLOW one"}) |> render_submit()

    assert has_element?(view, ~s(#chat button[type="submit"]), "Send")
    refute has_element?(view, "#chat button[disabled]", "Send")
    view |> form("#chat-form", %{"prompt" => "then this"}) |> render_submit()
    assert has_element?(view, ~s(#chat .msg[data-type="queued"]), "then this")

    view |> element(~s(#chat button[phx-click="chat_stop"]), "Stop") |> render_click()
    refute has_element?(view, ~s(#chat .msg[data-type="queued"]))

    view |> element(~s(#chat button[phx-click="chat_reset"]), "New") |> render_click()
    refute has_element?(view, ~s(#chat .msg[data-type="user"]))
  end

  test "a prompt typed during a run is queued and runs when the first one ends", %{
    view: view,
    name: name
  } do
    view |> element("#toggle-chat") |> render_click()
    :ok = Grasp.Agent.subscribe(name)
    view |> form("#chat-form", %{"prompt" => "SLOW one"}) |> render_submit()
    view |> form("#chat-form", %{"prompt" => "then this"}) |> render_submit()

    assert has_element?(view, ~s(#chat .msg[data-type="queued"]), "then this")
    refute has_element?(view, ~s(#chat .msg[data-type="user"]), "then this")

    assert_receive {:agent, ^name, %{running?: false}}, 4_000
    eventually(view, fn -> not has_element?(view, ~s(#chat button[phx-click="chat_stop"])) end)

    refute has_element?(view, ~s(#chat .msg[data-type="queued"]))
    assert has_element?(view, ~s(#chat .msg[data-type="user"]), "SLOW one")
    assert has_element?(view, ~s(#chat .msg[data-type="user"]), "then this")

    log = view |> element("#chat-log") |> render()
    assert length(String.split(log, "Looking at the flow.")) == 3
  end

  test "a queued prompt is withdrawn by its own button", %{view: view, name: name} do
    view |> element("#toggle-chat") |> render_click()
    :ok = Grasp.Agent.subscribe(name)
    view |> form("#chat-form", %{"prompt" => "SLOW one"}) |> render_submit()
    view |> form("#chat-form", %{"prompt" => "then this"}) |> render_submit()

    # The row names the prompt it withdraws, not the position it is drawn at.
    assert has_element?(
             view,
             ~s(#chat .msg[data-type="queued"] button[phx-click="chat_dequeue"][phx-value-id])
           )

    view
    |> element(~s(#chat .msg[data-type="queued"] button[phx-click="chat_dequeue"]))
    |> render_click()

    refute has_element?(view, ~s(#chat .msg[data-type="queued"]))

    assert_receive {:agent, ^name, %{running?: false}}, 4_000
    eventually(view, fn -> not has_element?(view, ~s(#chat button[phx-click="chat_stop"])) end)
    refute has_element?(view, ~s(#chat .msg[data-type="user"]), "then this")
  end

  test "an empty transcript offers prompts to start from", %{view: view, name: name} do
    view |> element("#toggle-chat") |> render_click()

    assert has_element?(view, ~s(#chat .chat__suggest button), "Show me what changed")
    assert has_element?(view, ~s(#chat .chat__suggest button), "Where does GET /again lead?")
    refute has_element?(view, ~s(#chat .chat__suggest button), "Explain #{@greeter}")

    # The focused card is the subject the reader is already looking at.
    view |> element("#chat") |> render_hook("open_root", %{"id" => @greeter})
    assert has_element?(view, ~s(#chat .chat__suggest button), "Explain #{@greeter}")

    :ok = Grasp.Agent.subscribe(name)

    view
    |> element(~s(#chat .chat__suggest button), "Show me what changed")
    |> render_click()

    assert has_element?(view, ~s(#chat .msg[data-type="user"]), "Show me what changed")
    refute has_element?(view, "#chat .chat__suggest")
    assert_receive {:agent, ^name, %{running?: false}}, 2_000
  end

  test "an empty transcript offers a plan of tests for the changes and the focused card", %{
    view: view,
    name: name
  } do
    view |> element("#toggle-chat") |> render_click()
    assert has_element?(view, ~s(#chat .chat__suggest button), "Plan tests for the changes")
    refute has_element?(view, ~s(#chat .chat__suggest button), "Plan tests for #{@greeter}")

    {:ok, _thread} =
      Grasp.Comments.add(%{
        session: name,
        function_id: @greeter,
        side: "new",
        line: 9,
        body: "worth a test ##{System.unique_integer([:positive])}",
        author: "human"
      })

    view |> element("#chat") |> render_hook("open_root", %{"id" => @greeter})

    assert suggestions(view) == [
             "Show me what changed",
             "Plan tests for the changes",
             "Explain #{@greeter}",
             "Plan tests for #{@greeter}",
             "Publish the comments",
             "Where does GET /again lead?"
           ]

    :ok = Grasp.Agent.subscribe(name)

    view
    |> element(~s(#chat .chat__suggest button), "Plan tests for #{@greeter}")
    |> render_click()

    assert has_element?(view, ~s(#chat .msg[data-type="user"]), "Plan tests for #{@greeter}")
    assert_receive {:agent, ^name, %{running?: false}}, 2_000
  end

  defp suggestions(view) do
    view
    |> element("#chat .chat__suggest")
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("button")
    |> Enum.map(&(&1 |> LazyHTML.text() |> String.trim()))
  end

  # A broadcast the test received is not a broadcast the LiveView has handled: PubSub
  # dispatches by registry partition, so the subscriber that joined second can be notified
  # first, and a render asked for in that window shows the run as it was. Every assertion
  # that reads the panel the moment a run ends waits here until the panel itself says the
  # run is over — the Stop button is drawn only while one is live.
  defp eventually(view, predicate, attempts \\ 100) do
    cond do
      predicate.() ->
        :ok

      attempts == 0 ->
        flunk("the panel never reached the state the test waited for")

      true ->
        Process.sleep(10)
        render(view)
        eventually(view, predicate, attempts - 1)
    end
  end
end
