defmodule GraspWeb.ReviewLiveTest do
  use GraspWeb.ConnCase, async: true

  alias Grasp.Comments
  alias Grasp.Session

  @greet "SampleApp.Greeter.greet/2"
  @wrap "SampleApp.Formatter.wrap/1"
  @shout "SampleApp.Formatter.shout/1"
  @greet_all "SampleApp.Greeter.greet_all/1"
  @show "SampleAppWeb.GreetController.show/2"
  @mount "SampleAppWeb.HelloLive.mount/3"
  @perform "SampleApp.Workers.Mailer.perform/1"
  @create "SampleAppWeb.GreetController.create/2"
  @greet_alias "SampleApp.Greeter.greet/1"
  @nested "SampleApp.Greeter.Nested.hello/0"
  @whisper "SampleApp.Formatter.whisper/1"
  @render "SampleAppWeb.HelloLive.render/1"
  @badge "SampleAppWeb.GreetHTML.badge/1"
  @show_template "SampleAppWeb.GreetHTML.show/1"
  @again "SampleAppWeb.GreetController.again/2"
  @split_binary ":erlang.split_binary/2"

  setup %{conn: conn} do
    name = "t-#{System.unique_integer([:positive])}"
    {:ok, view, _html} = live(conn, "/s/#{name}")
    %{view: view, name: name}
  end

  test "the sidebar lists entry points by kind and opens their target", %{view: view} do
    assert has_element?(view, "#entries .group[data-kind='routes'] .group__title", "Routes")

    assert has_element?(
             view,
             "#entries .group[data-kind='routes'] .group__heading",
             "SampleAppWeb.Router"
           )

    assert has_element?(
             view,
             "#entries .group[data-kind='routes'] button.entry[phx-value-id='#{@show}']",
             "GET /greet/:name"
           )

    assert has_element?(view, "#group-oban[hidden]")

    view |> element("#entries .group[data-kind='oban'] .group__title") |> render_click()

    refute has_element?(view, "#group-oban[hidden]")

    assert has_element?(
             view,
             "#entries .group[data-kind='oban'] button.entry[phx-value-id='#{@perform}']",
             "perform/1"
           )

    view |> element("#entries button.entry[phx-value-id='#{@show}']") |> render_click()

    assert has_element?(view, "#card-1[data-function-id='#{@show}']")
    assert has_element?(view, "#card-1 .badge", "GET /greet/:name")
  end

  test "every group but the routes starts collapsed, and callbacks sit under their module", %{
    view: view
  } do
    assert has_element?(view, "#group-genservers[hidden] button.entry")
    view |> element("#entries .group[data-kind='live'] .group__title") |> render_click()
    refute has_element?(view, "#group-live[hidden]")

    assert has_element?(
             view,
             "#entries .group[data-kind='live'] .group__heading",
             "SampleAppWeb.HelloLive"
           )

    assert has_element?(
             view,
             "#entries .group[data-kind='live'] .group__heading",
             "SampleAppWeb.GreetingComponent"
           )

    assert has_element?(
             view,
             "#entries .group[data-kind='live'] button.entry[phx-value-id='#{@mount}'][title='#{@mount}']",
             "mount/3"
           )
  end

  test "a card badges every entry point that reaches it", %{view: view, name: name} do
    Session.open_root(name, @mount)

    assert has_element?(view, "#card-1 .badge.badge--live_route", "live route")
    assert has_element?(view, "#card-1 .badge.badge--live_view", "live view")

    Session.open_root(name, @greet)
    refute has_element?(view, "#card-2 .badge")
  end

  test "renders the module list and expands a module into its functions", %{view: view} do
    assert has_element?(view, "#group-modules[hidden] #modules button.module")

    view |> element("#entries .group[data-kind='modules'] .group__title") |> render_click()

    refute has_element?(view, "#group-modules[hidden]")

    assert has_element?(view, "#modules button.module", "SampleApp.Greeter")
    refute has_element?(view, "#modules button.fn", "greet/2")

    view
    |> element("#modules button.module[phx-value-module='SampleApp.Greeter']")
    |> render_click()

    assert has_element?(view, "#modules button.fn", "greet/2")
  end

  test "opening a function from the sidebar adds a focused root card with highlighted source", %{
    view: view
  } do
    view |> element("#entries .group[data-kind='modules'] .group__title") |> render_click()

    view
    |> element("#modules button.module[phx-value-module='SampleApp.Greeter']")
    |> render_click()

    view |> element("#modules button.fn[phx-value-id='#{@greet}']") |> render_click()

    assert has_element?(
             view,
             "#node-1[data-depth='0'] #card-1[data-function-id='#{@greet}'][data-focused='true']"
           )

    assert has_element?(view, "#card-1 span.call[data-target='#{@wrap}']", "Formatter.wrap")
    assert has_element?(view, "#card-1 .card__file", "lib/sample_app/greeter.ex:6")
  end

  test "a card carries the function's head, which is all a zoomed-out canvas shows", %{
    view: view,
    name: name
  } do
    Session.open_root(name, @greet)
    Session.open_root(name, @whisper)

    assert has_element?(view, "#card-1 .card__signature", ~S|def greet(name, loud? \\ false)|)
    assert has_element?(view, "#card-1 .card__signature .l-keyword-function", "def")
    assert has_element?(view, "#card-2 .card__signature", "def whisper(text)")
  end

  test "a highlighted card renders the ring and the tinted lines", %{view: view, name: name} do
    Session.open_root(name, @greet)
    id = 1
    Session.set_highlight(name, id, %{"call" => @wrap})

    assert has_element?(
             view,
             ~s(#card-#{id} .call[data-highlight="true"][data-target="#{@wrap}"])
           )

    assert has_element?(view, ~s(#card-#{id}[data-highlight-key="call:#{@wrap}"]))

    Session.set_highlight(name, id, %{"lines" => [9, 10]})
    assert has_element?(view, ~s(#card-#{id} .line[data-highlight="true"][data-line="9"]))
    assert has_element?(view, ~s(#card-#{id}[data-highlight-key="lines:9-10"]))
    refute has_element?(view, ~s(#card-#{id} .call[data-highlight="true"]))
  end

  test "a comment in the sidebar opens its card and lights up the line it was written on", %{
    view: view,
    name: name
  } do
    {:ok, thread} =
      Comments.add(%{
        session: name,
        function_id: @greet,
        side: "new",
        line: 9,
        body: "the wrap call is the one to look at ##{System.unique_integer([:positive])}",
        author: "human"
      })

    view
    |> element("#entries .group[data-kind='comments'] button.entry[phx-value-id='#{thread.id}']")
    |> render_click()

    assert has_element?(view, "#card-1[data-function-id='#{@greet}'][data-focused='true']")
    assert has_element?(view, ~s(#card-1[data-highlight-key="lines:9-9"]))
    assert has_element?(view, ~s(#card-1 .line[data-highlight="true"][data-line="9"]))
  end

  test "a comment on a function the index has lost opens nothing", %{view: view, name: name} do
    {:ok, thread} =
      Comments.add(%{
        session: name,
        function_id: "SampleApp.Gone.vanished/1",
        side: "new",
        line: 1,
        body: "this one went with the branch ##{System.unique_integer([:positive])}",
        author: "human"
      })

    view
    |> element(
      "#entries .group[data-kind='comments'] button.entry--orphan[phx-value-id='#{thread.id}']"
    )
    |> render_click()

    refute has_element?(view, "#card-1")
  end

  test "clicking a call opens the callee one column right and colours the call site", %{
    view: view,
    name: name
  } do
    Session.open_root(name, @greet)

    view |> element("#card-1 span.call[data-target='#{@wrap}']") |> render_click()

    assert has_element?(view, "#node-1[data-depth='0'] #card-1")

    assert has_element?(
             view,
             "#node-2[data-depth='1'] #card-2[data-function-id='#{@wrap}'][data-focused='true']"
           )

    assert has_element?(
             view,
             "#card-1 span.call[data-target='#{@wrap}'][data-open='true'][data-color='0'][data-edge-to='2']"
           )

    view |> element("#card-1 span.call[data-target='#{@shout}']") |> render_click()

    assert has_element?(
             view,
             "#node-3[data-depth='1'] #card-3[data-function-id='#{@shout}']"
           )

    assert has_element?(
             view,
             "#card-1 span.call[data-target='#{@shout}'][data-open='true'][data-color='1'][data-edge-to='3']"
           )

    assert has_element?(view, "#card-2[data-focused='false']")

    view |> element("#card-1 span.call[data-target='#{@wrap}']") |> render_click()
    assert has_element?(view, "#card-2[data-focused='true']")
    refute has_element?(view, "#card-4")
  end

  test "a node carries its card's layer and its layer-floored column beside its depth", %{
    view: view,
    name: name
  } do
    Session.open_root(name, @show)

    assert has_element?(view, "#node-1[data-layer='interfaces'][data-column='0'][data-depth='0']")

    view |> element("#card-1 span.call[data-target='#{@greet_alias}']") |> render_click()

    assert has_element?(view, "#node-2[data-layer='core'][data-column='1'][data-depth='1']")

    view |> element("#card-1 span.call[data-target='#{@show_template}']") |> render_click()

    assert has_element?(view, "#node-3[data-layer='html'][data-column='0'][data-depth='1']")
    assert has_element?(view, "#node-1[data-layer='interfaces'][data-column='1'][data-depth='0']")
    assert has_element?(view, "#node-2[data-layer='core'][data-column='2'][data-depth='1']")

    view |> element("#card-2 span.call[data-target='#{@wrap}']") |> render_click()

    assert has_element?(view, "#node-4[data-layer='core'][data-column='3']")
  end

  test "a call the graph has not opened carries neither a colour nor a destination", %{
    view: view,
    name: name
  } do
    Session.open_root(name, @greet)

    assert has_element?(view, "#card-1 span.call[data-target='#{@wrap}'][data-open='false']")
    refute has_element?(view, "#card-1 span.call[data-target='#{@wrap}'][data-color]")
    refute has_element?(view, "#card-1 span.call[data-target='#{@wrap}'][data-edge-to]")
  end

  test "a function two cards call renders once, with a differently coloured call site in each",
       %{view: view, name: name} do
    Session.open_root(name, @create)
    Session.open_root(name, @perform)

    view |> element("#card-1 span.call[data-target='#{@greet}']") |> render_click()
    view |> element("#card-2 span.call[data-target='#{@greet_alias}']") |> render_click()

    assert count(view, ".card[data-function-id='#{@greet}']") == 1
    assert has_element?(view, "#node-3[data-depth='1'] #card-3")

    assert has_element?(
             view,
             "#card-1 span.call[data-target='#{@greet}'][data-open='true'][data-color='0'][data-edge-to='3']"
           )

    assert has_element?(
             view,
             "#card-2 span.call[data-target='#{@greet_alias}'][data-open='true'][data-color='1'][data-edge-to='3']"
           )
  end

  test "closing the middle card of a chain leaves the other two, the last one a source", %{
    view: view,
    name: name
  } do
    Session.open_root(name, @greet_all)
    Session.open_child(name, 1, @greet, @greet_alias)
    Session.open_child(name, 2, @wrap)

    view |> element("#card-2 .card__close") |> render_click()

    refute has_element?(view, "#card-2")
    assert has_element?(view, "#node-1[data-depth='0'] #card-1")
    assert has_element?(view, "#node-3[data-depth='0'] #card-3")
    refute has_element?(view, ".node[data-depth='1']")
  end

  test "close_chain takes the cards that had no other way to be reached", %{
    view: view,
    name: name
  } do
    Session.open_root(name, @greet)
    Session.open_child(name, 1, @wrap)
    Session.open_child(name, 1, @shout)
    assert has_element?(view, "#card-3")

    render_click(view, "close_chain", %{"card" => "1"})

    refute has_element?(view, "#card-1")
    refute has_element?(view, "#card-2")
    refute has_element?(view, "#card-3")
  end

  test "close_focused_chain with nothing focused leaves the canvas as it was", %{view: view} do
    render_hook(view, "close_focused_chain", %{})

    assert has_element?(view, "#stage")
    refute has_element?(view, ".card")
  end

  test "Shift+x closes the focused card's chain", %{view: view, name: name} do
    Session.open_root(name, @greet)
    Session.open_child(name, 1, @wrap)
    Session.focus(name, 1)

    render_hook(view, "close_focused_chain", %{})

    refute has_element?(view, ".card")
  end

  test "collapsing hides the callee behind a count and says so on the button", %{
    view: view,
    name: name
  } do
    Session.open_root(name, @greet)
    Session.open_child(name, 1, @wrap)

    view |> element("#card-1 .card__collapse") |> render_click()

    refute has_element?(view, "#card-2")
    assert has_element?(view, "#card-1 .card__collapse", "▸ 1")

    view |> element("#card-1 .card__collapse") |> render_click()

    assert has_element?(view, "#card-2")
    assert has_element?(view, "#card-1 .card__collapse", "▾")
    refute has_element?(view, "#card-2 .card__collapse")
  end

  test "the close button advertises the chain close", %{view: view, name: name} do
    Session.open_root(name, @greet)

    assert has_element?(
             view,
             "#card-1 .card__close[title='Close (x) · Shift+x closes the chain']"
           )
  end

  test "opening a caller puts it left of the card, which keeps its only copy", %{
    view: view,
    name: name
  } do
    Session.open_root(name, @greet)

    open_caller(view, 1, @greet_all)

    assert has_element?(
             view,
             "#node-2[data-depth='0'] #card-2[data-function-id='#{@greet_all}'][data-focused='true']"
           )

    assert has_element?(view, "#node-1[data-depth='1'] #card-1")
    assert count(view, "#card-1") == 1
    assert count(view, ".card[data-function-id='#{@greet}']") == 1

    open_caller(view, 1, @perform)

    assert count(view, ".node[data-depth='0'] .card") == 2

    assert has_element?(
             view,
             "#node-3[data-depth='0'] #card-3[data-function-id='#{@perform}']"
           )

    assert count(view, "#card-1") == 1
  end

  test "the callers menu opens on click, focuses its card and closes again", %{
    view: view,
    name: name
  } do
    Session.open_root(name, @greet)
    Session.open_child(name, 1, @wrap)
    assert has_element?(view, "#card-1[data-focused='false']")
    refute has_element?(view, "#card-1 .card__callers ul")

    view |> element("#card-1 .card__callers-toggle") |> render_click()
    assert has_element?(view, "#card-1 .card__callers ul button.caller", @greet_all)
    assert has_element?(view, "#card-1[data-focused='true']")

    view |> element("#card-1 .card__callers-toggle") |> render_click()
    refute has_element?(view, "#card-1 .card__callers ul")
  end

  test "opening a caller closes the callers menu", %{view: view, name: name} do
    Session.open_root(name, @greet)
    open_caller(view, 1, @greet_all)

    refute has_element?(view, ".card__callers ul")
  end

  test "an arity alias resolves to the defining function", %{view: view, name: name} do
    Session.open_root(name, @greet_all)

    view
    |> element("#card-1 span.call[data-target='SampleApp.Greeter.greet/1']")
    |> render_click()

    assert has_element?(view, "#card-2[data-function-id='#{@greet}']")
    refute has_element?(view, "#card-3")
  end

  test "a call through an arity alias marks the open child and reuses it", %{
    view: view,
    name: name
  } do
    Session.open_root(name, @greet)
    open_caller(view, 1, @greet_all)

    assert has_element?(
             view,
             "#card-2 span.call[data-target='#{@greet_alias}'][data-open='true'][data-edge-to='1']"
           )

    view
    |> element("#card-2 span.call[data-target='#{@greet_alias}']")
    |> render_click()

    assert has_element?(view, "#card-1[data-focused='true']")
    refute has_element?(view, "#card-3")
  end

  test "a non-string id or target is ignored", %{view: view, name: name} do
    Session.open_root(name, @greet)

    render_hook(view, "palette_open", %{"id" => 123, "child" => false})
    render_click(view, "open_call", %{"card" => "1", "target" => 5})
    render_click(view, "open_root", %{"id" => %{"a" => 1}})
    render_click(view, "open_caller", %{"card" => "1", "caller" => 7})
    render_click(view, "focus_card", %{"card" => %{"a" => 1}})
    render_click(view, "toggle_callers", %{"card" => ["1"]})

    assert has_element?(view, "#card-1")
    refute has_element?(view, "#card-2")
  end

  test "opening a call pushes a focus event for the new card", %{view: view, name: name} do
    Session.open_root(name, @greet)

    view |> element("#card-1 span.call[data-target='#{@wrap}']") |> render_click()
    render(view)

    assert_push_event(view, "focus", %{id: 2})
  end

  test "an external call opens a stub card", %{view: view, name: name} do
    Session.open_root(name, @greet_all)

    view
    |> element("#card-1 span.call[data-target='Enum.map/2'][data-external='true']")
    |> render_click()

    assert has_element?(view, "#card-2.stub", "Enum.map/2")
    # The header splits the module off so that the frame round the cluster can carry it and the
    # card show `fun/arity` alone.
    assert has_element?(view, "#card-2.stub .card__module", "Enum.")
    assert has_element?(view, "#card-2.stub .card__fn", "map/2")
    assert has_element?(view, "#node-2[data-module='Enum'] #card-2.stub")
    assert has_element?(view, "#card-2.stub a[href='https://hexdocs.pm/elixir/Enum.html#map/2']")
  end

  test "a template's interpolated calls are clickable on its own card", %{
    view: view,
    name: name
  } do
    Session.open_root(name, @show_template)

    refute has_element?(view, "#card-1 .card__also")
    assert count(view, "#card-1 span.call[data-target='#{@greet_alias}']") == 4

    view
    |> element(
      "#card-1 .line[data-line='4'] span.call[phx-click='open_call'][data-target='#{@greet_alias}']"
    )
    |> render_click()

    assert has_element?(
             view,
             "#node-2[data-depth='1'] #card-2[data-function-id='#{@greet}']"
           )
  end

  test "a controller's render opens the template it names", %{view: view, name: name} do
    Session.open_root(name, @show)

    view
    |> element("#card-1 span.call[data-target='#{@show_template}']", "render")
    |> render_click()

    assert has_element?(
             view,
             "#node-2[data-depth='1'] #card-2[data-function-id='#{@show_template}']"
           )
  end

  test "a template opens from the palette, and its component tags are clickable", %{view: view} do
    render_hook(view, "palette_show", %{})
    view |> form("#palette-form", %{q: "GreetHTML.show"}) |> render_change()
    view |> element("#palette-results li[data-id='#{@show_template}'] button") |> render_click()

    assert has_element?(view, "#card-1[data-function-id='#{@show_template}']")
    assert has_element?(view, "#card-1 .card__kind", "template")

    assert has_element?(
             view,
             "#card-1 .card__file",
             "lib/sample_app_web/greet_html/show.html.heex:1"
           )

    assert has_element?(view, "#card-1 .line[data-line='1'] .l-tag-attribute", "label")
    assert has_element?(view, "#card-1 span.call[data-target='#{@badge}']", ".badge")

    view |> element("#card-1 span.call[data-target='#{@badge}']") |> render_click()

    assert has_element?(
             view,
             "#node-2[data-depth='1'] #card-2[data-function-id='#{@badge}']"
           )

    view |> element("#card-2 .card__callers-toggle") |> render_click()

    assert has_element?(view, "#card-2 .card__callers ul button.caller", @show_template)
  end

  test "a route a template links to opens the action, named by its verb and path",
       %{view: view, name: name} do
    Session.open_root(name, @show_template)

    assert has_element?(
             view,
             "#card-1 .line[data-line='3'] span.call[data-kind='route'][data-target='#{@show}'][title='GET /greet/:name']"
           )

    assert has_element?(
             view,
             "#card-1 .line[data-line='8'] span.call[data-kind='route'][data-target='#{@create}'][title='POST /greet']"
           )

    view
    |> element("#card-1 .line[data-line='3'] span.call[data-kind='route']")
    |> render_click()

    assert has_element?(view, "#node-2[data-depth='1'] #card-2[data-function-id='#{@show}']")

    view |> element("#card-2 .card__callers-toggle") |> render_click()

    assert has_element?(view, "#card-2 .card__callers ul button.caller", @show_template)
  end

  test "a ~p in a controller action is a route call the reader can follow",
       %{view: view, name: name} do
    Session.open_root(name, @again)

    assert has_element?(
             view,
             "#card-1 span.call[data-kind='route'][data-target='#{@show}'][title='GET /greet/:name']"
           )
  end

  test "a call made inside a ~H is clickable on the card holding it", %{view: view, name: name} do
    Session.open_root(name, @render)

    refute has_element?(view, "#card-1 .card__also")

    view
    |> element(
      "#card-1 .line[data-line='12'] span.call[phx-click='open_call'][data-target='#{@greet_alias}']"
    )
    |> render_click()

    assert has_element?(
             view,
             "#node-2[data-depth='1'] #card-2[data-function-id='#{@greet}']"
           )
  end

  test "changes made through the session API render live", %{view: view, name: name} do
    Session.open_root(name, @greet)
    assert has_element?(view, "#card-1")
    Session.close(name, 1)
    refute has_element?(view, "#card-1")
  end

  test "keyboard focus moves along the edges", %{view: view, name: name} do
    Session.open_root(name, @greet)
    Session.open_child(name, 1, @wrap)
    Session.focus(name, 2)

    render_hook(view, "move_focus", %{"dir" => "parent"})
    assert has_element?(view, "#card-1[data-focused='true']")
    render_hook(view, "move_focus", %{"dir" => "child"})
    assert has_element?(view, "#card-2[data-focused='true']")
  end

  test "the header focuses a card, and the card body does not", %{view: view, name: name} do
    Session.open_root(name, @greet)
    Session.open_child(name, 1, @wrap)
    assert has_element?(view, "#card-2[data-focused='true']")

    view |> element("#card-1 .card__header") |> render_click()
    assert has_element?(view, "#card-1[data-focused='true']")
    refute has_element?(view, "#card-1[phx-click]")
  end

  test "the bare route serves the default session", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/")
    assert has_element?(view, "#app .sidebar .brand", "Grasp")
    assert has_element?(view, "#canvas")
  end

  test "a name that is not a session name is sent to the default session", %{conn: conn} do
    assert {:error, {:live_redirect, %{to: "/"}}} = live(conn, "/?name=../../../x")
    assert {:error, {:live_redirect, %{to: "/"}}} = live(conn, "/s/a.b")
  end

  test "the canvas wraps the cards in a pannable stage with a frame and connector layer and a toolbar",
       %{view: view} do
    assert has_element?(
             view,
             "#canvas[phx-hook='Canvas'] #stage svg#connectors[phx-update='ignore']"
           )

    # Both layers are the hook's to fill, and the frames sit under the edges and the cards.
    assert has_element?(view, "#canvas #stage #frames[phx-update='ignore']")

    assert render(view) =~ ~r/id="frames".*id="connectors"/s

    # The hook draws the edges but cannot build the arrowhead they point at, so the marker
    # for every palette colour is server-rendered inside the ignored layer.
    assert has_element?(view, "#connectors defs marker#arrow-0 path[data-color='0']")
    assert has_element?(view, "#connectors defs marker#arrow-7 path[data-color='7']")
    assert has_element?(view, "#connectors g#edges")

    assert has_element?(view, "#canvas .toolbar #reset-layout[phx-click='reset_layout']")
    assert has_element?(view, "#canvas .toolbar #zoom-in")
    assert has_element?(view, "#canvas .toolbar #zoom-out")
    assert has_element?(view, "#canvas .toolbar #zoom-fit")
    assert has_element?(view, "#canvas .toolbar #zoom-level[phx-update='ignore']", "100%")
    refute has_element?(view, "#canvas .toolbar #zoom-in[phx-click]")

    # Signature mode is the hook's: the button is client-only, starts unpressed, and is kept
    # out of every patch so a patch cannot render a pressed toggle as unpressed.
    assert has_element?(
             view,
             "#canvas .toolbar #toggle-signatures[aria-pressed='false'][phx-update='ignore']",
             "signatures"
           )

    refute has_element?(view, "#canvas .toolbar #toggle-signatures[phx-click]")

    # Module clusters are the hook's in the same way, and they are on until the reader turns
    # them off, so the button starts pressed.
    assert has_element?(
             view,
             "#canvas .toolbar #toggle-modules[aria-pressed='true'][phx-update='ignore']",
             "modules"
           )

    refute has_element?(view, "#canvas .toolbar #toggle-modules[phx-click]")
  end

  test "every toolbar control names itself, and its shortcut where it has one", %{view: view} do
    for id <- ~w(toggle-sidebar zoom-out zoom-level zoom-in zoom-fit
                 toggle-signatures toggle-modules reset-layout toggle-chat help-toggle) do
      assert has_element?(view, "#canvas .toolbar ##{id}[data-tip]"),
             "the toolbar's ##{id} has no data-tip"
    end

    assert has_element?(
             view,
             "#canvas .toolbar #zoom-fit[data-tip='Fit all cards'][data-key='F']"
           )

    assert has_element?(
             view,
             "#canvas .toolbar #toggle-signatures[data-tip='Signatures instead of code'][data-key='S']"
           )

    assert has_element?(
             view,
             "#canvas .toolbar #toggle-modules[data-tip='Module frames'][data-key='M']"
           )

    assert has_element?(
             view,
             "#canvas .toolbar #toggle-chat[data-tip='Ask the agent'][data-key=\"\u2318I\"]"
           )

    assert has_element?(
             view,
             "#canvas .toolbar #help-toggle[data-tip='Keys and gestures'][data-key='?']"
           )

    assert has_element?(view, "#canvas .toolbar #reset-layout[data-tip='Reset layout']")
    refute has_element?(view, "#canvas .toolbar #reset-layout[data-key]")

    # The tooltip is drawn from data-tip; a title alongside would show a second bubble.
    refute has_element?(view, "#canvas .toolbar [title]")
  end

  test "the toolbar's controls read left to right, zoom cluster in the middle", %{view: view} do
    html = render(view)

    at = fn id ->
      case :binary.match(html, ~s(id="#{id}")) do
        {position, _} -> position
        :nomatch -> flunk("the toolbar has no ##{id}")
      end
    end

    ids = ~w(
      toggle-sidebar zoom-out zoom-level zoom-in zoom-fit
      toggle-signatures toggle-modules reset-layout toggle-chat help-toggle
    )

    positions = Enum.map(ids, at)
    assert positions == Enum.sort(positions)
  end

  test "the help dialog lists the gestures and keys the toolbar does not show", %{view: view} do
    # Client-only: which keys exist is not session state, so the server renders the list once
    # and the hook alone opens and closes it.
    assert has_element?(
             view,
             "dialog#help[phx-hook='Help'][phx-update='ignore'][aria-labelledby='help-title']"
           )

    assert has_element?(view, "#help h2#help-title", "Keys and gestures")
    refute has_element?(view, "#help[open]")

    # First in the dialog, so it is both the pointer's way out and what showModal() focuses.
    assert has_element?(view, "#help button.help__close[type='button'][aria-label='Close']")

    assert has_element?(view, "#help dt kbd", "Alt+drag")
    assert has_element?(view, "#help dd", "Move every card connected to it.")
    assert render(view) =~ "<kbd>?</kbd>"

    # ~H does not process escapes, so a backslash key is written as one and must stay one.
    assert render(view) =~ "<kbd>⌘\\</kbd>"

    html = render(view)

    # The vim walk stands beside the arrows, `z` folds and `/` reaches the palette.
    assert html =~ "<kbd>j</kbd>"
    assert html =~ "<kbd>z</kbd>"
    assert html =~ "<kbd>/</kbd>"

    # Folding is `z`'s row; `h` spends itself walking the graph instead.
    assert html =~ ~r{<kbd>z</kbd></dt>\s*<dd>\s*Fold the unchanged lines\.}
    refute html =~ ~r{<kbd>h</kbd></dt>}

    # Module clusters have a key of their own and a gesture of their own.
    assert html =~ ~r{<kbd>m</kbd></dt>\s*<dd>\s*Module frames round the cards\.}
    assert has_element?(view, "#help dd", "Move every card of that module in the flow.")

    for heading <- ["Mouse", "Keys", "Chat"] do
      assert has_element?(view, "#help h3", heading)
    end
  end

  test "the sidebar can be hidden and shown", %{view: view} do
    assert has_element?(view, "main.app[data-sidebar='true'] aside.sidebar")

    render_hook(view, "toggle_sidebar", %{})
    refute has_element?(view, "aside.sidebar")
    assert has_element?(view, "main.app.app--no-sidebar[data-sidebar='false']")

    view |> element("#canvas .toolbar #toggle-sidebar") |> render_click()
    assert has_element?(view, "aside.sidebar")
  end

  test "dragging a card stores its position and reset_layout empties every one", %{
    view: view,
    name: name
  } do
    Session.open_root(name, @greet)
    Session.open_root(name, @perform)
    Session.open_root(name, @show)

    assert count(view, ".node[data-unplaced]") == 3

    render_hook(view, "move_card", %{"card" => 1, "x" => 40, "y" => -12})
    assert has_element?(view, "#node-1[style*='--x: 40px'][style*='--y: -12px'] > #card-1")
    refute has_element?(view, "#node-1[data-unplaced]")

    render_hook(view, "move_card", %{"card" => "1", "x" => "7", "y" => "8"})
    assert has_element?(view, "#node-1[style*='--x: 7px'][style*='--y: 8px']")

    render_hook(view, "move_card", %{"card" => 1, "x" => "nope", "y" => 0})
    assert has_element?(view, "#node-1[style*='--x: 7px'][style*='--y: 8px']")

    render_hook(view, "move_card", %{"card" => 2, "x" => 300, "y" => 0})
    render_hook(view, "place_cards", %{"cards" => [%{"id" => 3, "x" => 0, "y" => 400}]})
    assert count(view, ".node[data-unplaced]") == 0

    render_click(view, "reset_layout", %{})

    assert count(view, ".node[data-unplaced]") == 3
    assert has_element?(view, "#node-1[data-unplaced][style*='--x: 0px'][style*='--y: 0px']")
  end

  test "place_cards fills a position only while a card has none", %{view: view, name: name} do
    Session.open_root(name, @greet)
    Session.open_root(name, @perform)
    Session.open_root(name, @show)

    render_hook(view, "place_cards", %{
      "cards" => [%{"id" => 1, "x" => 100, "y" => 200}, %{"id" => "2", "x" => "0", "y" => "60"}]
    })

    assert has_element?(view, "#node-1[style*='--x: 100px'][style*='--y: 200px']")
    assert has_element?(view, "#node-2[style*='--x: 0px'][style*='--y: 60px']")
    assert count(view, ".node[data-unplaced]") == 1

    # A pass measured before another tab's drag says where a card it saw unplaced should go;
    # the card is somewhere by then, and stays there.
    render_hook(view, "place_cards", %{"cards" => [%{"id" => 1, "x" => 1, "y" => 1}]})
    assert has_element?(view, "#node-1[style*='--x: 100px'][style*='--y: 200px']")

    # An entry the server cannot read costs the card it names and no more: the card beside
    # it in the same pass is placed.
    render_hook(view, "place_cards", %{
      "cards" => ["junk", %{"id" => "nope", "x" => 5, "y" => 5}, %{"id" => 3, "x" => 8, "y" => 9}]
    })

    assert has_element?(view, "#node-3[style*='--x: 8px'][style*='--y: 9px']")
    assert count(view, ".node[data-unplaced]") == 0

    render_hook(view, "place_cards", %{"cards" => "junk"})
    assert has_element?(view, "#node-1[style*='--x: 100px'][style*='--y: 200px']")
  end

  test "dragging a frame's title moves every card of that group", %{view: view, name: name} do
    Session.open_root(name, @greet)
    Session.open_root(name, @perform)
    Session.open_root(name, @show)
    Session.new_group(name, "Greeting", [1, 2])
    render_hook(view, "move_card", %{"card" => 1, "x" => 0, "y" => 0})
    render_hook(view, "move_card", %{"card" => 2, "x" => 5, "y" => 5})

    render_hook(view, "move_group", %{"group" => 1, "dx" => 40, "dy" => -10})

    assert has_element?(view, "#node-1[style*='--x: 40px'][style*='--y: -10px']")
    assert has_element?(view, "#node-2[style*='--x: 45px'][style*='--y: -5px']")
    assert has_element?(view, "#node-3[data-unplaced]")

    render_hook(view, "move_group", %{"group" => "nope", "dx" => 1, "dy" => 1})
    assert has_element?(view, "#node-1[style*='--x: 40px'][style*='--y: -10px']")
  end

  test "a group drag leaves a member nothing has placed unplaced", %{view: view, name: name} do
    Session.open_root(name, @greet)
    Session.open_root(name, @perform)
    Session.new_group(name, "Greeting", [1, 2])
    render_hook(view, "move_card", %{"card" => 1, "x" => 10, "y" => 10})

    render_hook(view, "move_group", %{"group" => 1, "dx" => 5, "dy" => 5})

    assert has_element?(view, "#node-1[style*='--x: 15px'][style*='--y: 15px']")
    assert has_element?(view, "#node-2[data-group='1'][data-unplaced]")
  end

  test "a graph drag moves every listed card and keeps each one's group", %{
    view: view,
    name: name
  } do
    Session.open_root(name, @greet)
    Session.open_root(name, @perform)
    Session.open_root(name, @show)
    Session.new_group(name, "Greeting", [1, 2])
    render_hook(view, "move_card", %{"card" => 1, "x" => 0, "y" => 0})
    render_hook(view, "move_card", %{"card" => 2, "x" => 5, "y" => 5})
    render_hook(view, "move_card", %{"card" => 3, "x" => 90, "y" => 90})

    render_hook(view, "move_cards", %{"cards" => [1, 2], "dx" => 40, "dy" => -10})

    assert has_element?(view, "#node-1[data-group='1'][style*='--x: 40px'][style*='--y: -10px']")
    assert has_element?(view, "#node-2[data-group='1'][style*='--x: 45px'][style*='--y: -5px']")
    assert has_element?(view, "#node-3[style*='--x: 90px'][style*='--y: 90px']")

    render_hook(view, "move_cards", %{"cards" => "nope", "dx" => 1, "dy" => 1})
    render_hook(view, "move_cards", %{"cards" => [1], "dx" => "x", "dy" => 1})

    assert has_element?(view, "#node-1[style*='--x: 40px'][style*='--y: -10px']")
  end

  test "an unhandled direction or an unparsable card id leaves the view alive", %{
    view: view,
    name: name
  } do
    Session.open_root(name, @greet)

    render_hook(view, "move_focus", %{"dir" => "sideways"})
    render_click(view, "close_card", %{"card" => "abc"})
    render_click(view, "nonsense", %{})

    assert render(view) =~ "card-1"
    assert has_element?(view, "#card-1")
  end

  test "a modified card says so, counts its lines and offers the diff", %{view: view, name: name} do
    Session.open_root(name, @shout)

    assert has_element?(view, "#card-1 .badge--change[data-change='modified']", "modified")
    assert has_element?(view, "#card-1 .card__stats", "+1 \u22121")
    # A changed function opens on what changed.
    assert has_element?(view, "#card-1[data-view='diff']")
    assert has_element?(view, "#view-1[phx-click='toggle_view'][phx-value-card='1']", "source")
    assert has_element?(view, "#card-1 .card__body .line[data-op='del']", "text")
    assert has_element?(view, "#card-1 .card__body .line[data-op='ins'][data-line='10']")

    view |> element("#view-1") |> render_click()

    assert has_element?(view, "#card-1[data-view='source']")
    assert has_element?(view, "#view-1", "diff")
    refute has_element?(view, "#card-1 .line[data-op]")

    view |> element("#view-1") |> render_click()

    assert has_element?(view, "#card-1[data-view='diff']")
    assert has_element?(view, "#card-1 .line[data-op='del']")
  end

  test "an added card wears the added badge and has nothing to diff", %{view: view, name: name} do
    Session.open_root(name, @nested)

    assert has_element?(view, "#card-1 .badge--change[data-change='added']", "added")
    refute has_element?(view, "#card-1 .card__stats")
    refute has_element?(view, "#view-1")
  end

  test "an unchanged card wears no change badge", %{view: view, name: name} do
    Session.open_root(name, @greet)

    refute has_element?(view, "#card-1 .badge--change")
    refute has_element?(view, "#view-1")
  end

  test "a removed function opens as a removed card showing what the base had", %{
    view: view,
    name: name
  } do
    Session.open_root(name, @whisper)

    assert has_element?(view, "#card-1.card--removed[data-function-id='#{@whisper}']")
    assert has_element?(view, "#card-1 .badge--change[data-change='removed']", "removed")
    assert has_element?(view, "#card-1 .card__body", "String.downcase")
    refute has_element?(view, "#view-1")
    refute has_element?(view, "#card-1 .card__also")
  end

  test "a short diff opens whole and the header toggles it to the changes alone", %{
    view: view,
    name: name
  } do
    Session.open_root(name, @shout)

    # Three lines of context reach every line of a function this short, so `full` and
    # `hunks` draw the same body — what the toggle changes is the preference the card holds.
    assert has_element?(view, "#card-1[data-context='full']")
    assert has_element?(view, "#context-1[phx-click='toggle_context']", "changes only")
    refute has_element?(view, "#card-1 .line--fold")

    view |> element("#context-1") |> render_click()

    assert has_element?(view, "#card-1[data-context='hunks']")
    assert has_element?(view, "#context-1", "all lines")
    assert has_element?(view, "#card-1 .line[data-op='del']")
    refute has_element?(view, "#card-1 .line--fold")

    render_hook(view, "toggle_context_focused", %{})
    assert has_element?(view, "#card-1[data-context='full']")
  end

  test "the source view has no context toggle and no context of its own", %{
    view: view,
    name: name
  } do
    Session.open_root(name, @shout)

    view |> element("#view-1") |> render_click()

    assert has_element?(view, "#card-1[data-view='source']")
    refute has_element?(view, "#card-1[data-context]")
    refute has_element?(view, "#context-1")
  end

  test "a card with nothing to compare offers no context toggle", %{view: view, name: name} do
    Session.open_root(name, @greet)

    refute has_element?(view, "#context-1")
  end

  test "expanding a fold leaves the card standing, and a fold nobody has is ignored", %{
    view: view,
    name: name
  } do
    Session.open_root(name, @shout)

    render_click(view, "expand_fold", %{"card" => "1", "from" => "8"})
    render_click(view, "expand_fold", %{"card" => "nope", "from" => "eight"})

    assert has_element?(view, "#card-1 .line[data-op='ins']")
  end

  test "d toggles the focused card's view and passes over a card with no diff", %{
    view: view,
    name: name
  } do
    Session.open_root(name, @shout)
    Session.open_root(name, @greet)

    render_hook(view, "toggle_view_focused", %{})
    assert has_element?(view, "#card-2[data-view='source']")

    Session.focus(name, 1)
    assert has_element?(view, "#card-1[data-view='diff']")
    render_hook(view, "toggle_view_focused", %{})
    assert has_element?(view, "#card-1[data-view='source']")

    render_hook(view, "toggle_view_focused", %{})
    assert has_element?(view, "#card-1[data-view='diff']")
  end

  test "the Changes group lists what the branch touched and opens it", %{view: view} do
    assert has_element?(view, "#entries .group[data-kind='changes'] .group__title", "Changes")

    assert has_element?(
             view,
             "#entries .group[data-kind='changes'] .group__title[data-open='true']"
           )

    assert has_element?(
             view,
             "#entries .group[data-kind='changes'] .group__heading",
             "SampleApp.Formatter"
           )

    assert has_element?(
             view,
             "#entries .group[data-kind='changes'] button.entry[phx-value-id='#{@whisper}'] .badge--change[data-change='removed']"
           )

    view
    |> element("#entries .group[data-kind='changes'] button.entry[phx-value-id='#{@shout}']")
    |> render_click()

    assert has_element?(view, "#node-1[data-depth='0'] #card-1[data-function-id='#{@shout}']")
  end

  test "the Changes group collapses like any other", %{view: view} do
    view |> element("#entries .group[data-kind='changes'] .group__title") |> render_click()

    assert has_element?(view, "#group-changes[hidden]")
  end

  test "a group is drawn as its own titled section, numbered from its own left edge", %{
    view: view,
    name: name
  } do
    Session.open_root(name, @greet)
    Session.open_child(name, 1, @wrap)
    Session.open_root(name, @perform)
    Session.group_cards(name, "Greeting", [1, 2])

    # The frame itself is drawn by the hook from where the cards are, so what the server owes
    # it is the section's group id and a header to lift above it.
    assert has_element?(view, "#flow-1[data-grouped][data-group='1'] .flow__title h3", "Greeting")
    assert has_element?(view, "#flow-1 .flow__count", "2 cards")

    assert has_element?(
             view,
             "#flow-1 .flow__title button[phx-click='dissolve_group']",
             "ungroup"
           )

    assert has_element?(view, "#node-1[data-group='1'][data-depth='0'] #card-1")
    assert has_element?(view, "#node-2[data-group='1'][data-depth='1'] #card-2")

    assert has_element?(view, "#node-3[data-group=''][data-depth='0'] #card-3")
    refute has_element?(view, "#flow-none .flow__title")
    refute has_element?(view, "#flow-none[data-grouped]")
  end

  test "a node names the module its card belongs to", %{view: view, name: name} do
    Session.open_root(name, @greet)

    assert has_element?(view, "#node-1[data-module='SampleApp.Greeter'] #card-1")
  end

  test "a function of an Erlang module clusters under that module", %{view: view, name: name} do
    Session.open_root(name, @split_binary)

    assert has_element?(view, "#node-1[data-module=':erlang'] #card-1.stub")
    assert has_element?(view, "#card-1.stub .card__module", ":erlang.")
    assert has_element?(view, "#card-1.stub .card__fn", "split_binary/2")
  end

  test "a caller opened from a framed card is drawn inside that frame", %{
    view: view,
    name: name
  } do
    Session.open_root(name, @greet)
    Session.new_group(name, "Greeting", [1])

    open_caller(view, 1, @greet_all)

    assert has_element?(view, "#node-2[data-group='1'][data-depth='0'] #card-2")
    assert has_element?(view, "#node-1[data-group='1'][data-depth='1'] #card-1")
    assert has_element?(view, "#flow-1 .flow__count", "2 cards")
    refute has_element?(view, "#node-2[data-group=''] #card-2")
  end

  test "a section of one card counts it in the singular", %{view: view, name: name} do
    Session.open_root(name, @greet)
    Session.group_cards(name, "Greeting", [1])

    assert has_element?(view, "#flow-1 .flow__count", "1 card")
  end

  test "ungrouping a section returns its cards to the untitled one", %{view: view, name: name} do
    Session.open_root(name, @greet)
    Session.open_child(name, 1, @wrap)
    Session.group_cards(name, "Greeting", [1, 2])

    view |> element("#flow-1 .flow__title button[phx-click='dissolve_group']") |> render_click()

    refute has_element?(view, "#flow-1")
    assert has_element?(view, "#node-1[data-group=''][data-depth='0'] #card-1")
    assert has_element?(view, "#node-2[data-group=''][data-depth='1'] #card-2")
  end

  test "Shift-clicked cards are marked selected, and ⌘G frames them without a name", %{
    view: view,
    name: name
  } do
    Session.open_root(name, @greet)
    Session.open_child(name, 1, @wrap)

    refute has_element?(view, ".card__group-toggle")
    assert has_element?(view, "#card-1[data-selected='false']")

    render_hook(view, "toggle_select", %{"card" => "1"})
    render_hook(view, "toggle_select", %{"card" => "2"})

    assert has_element?(view, "#card-1.card--selected[data-selected='true']")
    assert has_element?(view, "#card-2.card--selected[data-selected='true']")

    render_hook(view, "group_selected", %{})

    assert has_element?(
             view,
             "#flow-1[data-grouped] .flow__title .flow__title-text--empty",
             "Untitled group"
           )

    assert has_element?(view, "#node-1[data-group='1'] #card-1")
    assert has_element?(view, "#node-2[data-group='1'] #card-2")
    assert has_element?(view, "#flow-1 .flow__count", "2 cards")
    refute has_element?(view, ".card--selected")
  end

  test "⌘G with nothing selected frames the focused card alone", %{view: view, name: name} do
    Session.open_root(name, @greet)
    Session.open_root(name, @perform)

    render_hook(view, "group_selected", %{})

    assert has_element?(view, "#flow-1[data-grouped]")
    assert has_element?(view, "#node-2[data-group='1'] #card-2")
    assert has_element?(view, "#node-1[data-group=''] #card-1")
  end

  test "⇧⌘G returns the selected cards to the unframed section and keeps them selected", %{
    view: view,
    name: name
  } do
    Session.open_root(name, @greet)
    Session.open_child(name, 1, @wrap)
    Session.group_cards(name, "Greeting", [1, 2])

    render_hook(view, "toggle_select", %{"card" => "2"})
    render_hook(view, "ungroup_selected", %{})

    assert has_element?(view, "#node-2[data-group=''] #card-2")
    assert has_element?(view, "#node-1[data-group='1'] #card-1")
    assert has_element?(view, "#card-2.card--selected")
  end

  test "a card dragged into a frame takes the rest of the selection with it", %{
    view: view,
    name: name
  } do
    Session.open_root(name, @greet)
    Session.open_root(name, @perform)
    Session.open_root(name, @show)
    Session.group_cards(name, "Greeting", [1])

    render_hook(view, "toggle_select", %{"card" => "2"})
    render_hook(view, "toggle_select", %{"card" => "3"})
    render_hook(view, "move_card", %{"card" => 2, "x" => 10, "y" => 5, "group" => 1})

    assert has_element?(view, "#node-2[data-group='1'][style*='--x: 10px'][style*='--y: 5px']")
    assert has_element?(view, "#node-3[data-group='1'][data-unplaced]")
  end

  test "the selection is cleared by Escape and loses a card that closes", %{
    view: view,
    name: name
  } do
    Session.open_root(name, @greet)
    Session.open_child(name, 1, @wrap)

    render_hook(view, "toggle_select", %{"card" => "1"})
    render_hook(view, "toggle_select", %{"card" => "2"})
    render_hook(view, "clear_selection", %{})

    refute has_element?(view, ".card--selected")

    render_hook(view, "toggle_select", %{"card" => "1"})
    view |> element("#card-1 .card__close") |> render_click()

    # The closed card is out of the selection, so grouping falls back to the card focus fell
    # to rather than framing a card nobody can see.
    render_hook(view, "group_selected", %{})

    assert has_element?(view, "#node-2[data-group='1'] #card-2")
    assert has_element?(view, "#flow-1 .flow__count", "1 card")
  end

  test "a card closed from outside the tab leaves the selection with it", %{
    view: view,
    name: name
  } do
    Session.open_root(name, @greet)
    Session.open_root(name, @perform)
    Session.open_root(name, @show)

    render_hook(view, "toggle_select", %{"card" => "1"})
    render_hook(view, "toggle_select", %{"card" => "2"})

    # An agent over MCP, or another tab on the same session: the forest arrives by broadcast
    # rather than from anything this view was asked to do.
    Session.close(name, 1)

    refute has_element?(view, "#card-1")
    assert has_element?(view, "#card-2.card--selected")
    assert count(view, ".card--selected") == 1

    render_hook(view, "group_selected", %{})

    assert has_element?(view, "#node-2[data-group='1'] #card-2")
    assert has_element?(view, "#flow-1 .flow__count", "1 card")
  end

  test "a plain click on a card lets the selection go", %{view: view, name: name} do
    Session.open_root(name, @greet)
    Session.open_root(name, @perform)
    Session.open_root(name, @show)

    render_hook(view, "toggle_select", %{"card" => "1"})
    render_hook(view, "toggle_select", %{"card" => "2"})

    view |> element("#card-3 .card__header") |> render_click()

    refute has_element?(view, ".card--selected")

    render_hook(view, "group_selected", %{})

    assert has_element?(view, "#node-3[data-group='1'] #card-3")
    assert has_element?(view, "#flow-1 .flow__count", "1 card")
  end

  test "an untitled frame is named by clicking its placeholder", %{view: view, name: name} do
    Session.open_root(name, @greet)
    Session.new_group(name, nil, [1])

    assert has_element?(view, "#flow-1 .flow__title-text--empty", "Untitled group")

    view |> element("#flow-1 .flow__title h3") |> render_click()

    assert has_element?(view, "#flow-1 form.flow__rename input[name='title']")
    refute has_element?(view, "#flow-1 form.flow__rename input[value='Untitled group']")

    view |> form("#flow-1 form.flow__rename", %{"title" => "Greeting"}) |> render_submit()

    assert has_element?(view, "#flow-1 .flow__title h3", "Greeting")
    refute has_element?(view, "#flow-1 .flow__title-text--empty")
  end

  test "a frame's title is renamed in place", %{view: view, name: name} do
    Session.open_root(name, @greet)
    Session.group_cards(name, "Greeting", [1])

    refute has_element?(view, "#flow-1 form.flow__rename")

    view |> element("#flow-1 .flow__title h3") |> render_click()

    assert has_element?(view, "#flow-1 form.flow__rename input[name='title'][value='Greeting']")
    refute has_element?(view, "#flow-1 .flow__title h3")

    view
    |> form("#flow-1 form.flow__rename", %{"title" => "  The greeting flow  "})
    |> render_submit()

    assert has_element?(view, "#flow-1 .flow__title h3", "The greeting flow")
    refute has_element?(view, "#flow-1 form.flow__rename")
  end

  test "a blank rename leaves the frame untitled and Escape closes the form", %{
    view: view,
    name: name
  } do
    Session.open_root(name, @greet)
    Session.group_cards(name, "Greeting", [1])

    view |> element("#flow-1 .flow__title h3") |> render_click()
    view |> form("#flow-1 form.flow__rename", %{"title" => "   "}) |> render_submit()

    assert has_element?(view, "#flow-1 .flow__title h3")
    refute has_element?(view, "#flow-1 .flow__title h3", "Greeting")
    refute has_element?(view, "#flow-1 form.flow__rename")

    view |> element("#flow-1 .flow__title h3") |> render_click()

    view
    |> element("#flow-1 form.flow__rename input[name='title']")
    |> render_keydown(%{"key" => "Escape"})

    refute has_element?(view, "#flow-1 form.flow__rename")
    refute has_element?(view, "#flow-1 .flow__title h3", "Greeting")
  end

  test "a card dropped on a frame joins its group, and a plain drop keeps membership", %{
    view: view,
    name: name
  } do
    Session.open_root(name, @greet)
    Session.open_root(name, @perform)
    Session.group_cards(name, "Greeting", [1])

    render_hook(view, "move_card", %{"card" => 2, "x" => 10, "y" => 5, "group" => 1})

    assert has_element?(view, "#node-2[data-group='1'][style*='--x: 10px'][style*='--y: 5px']")

    render_hook(view, "move_card", %{"card" => 2, "x" => 20, "y" => 6})

    assert has_element?(view, "#node-2[data-group='1'][style*='--x: 20px'][style*='--y: 6px']")
  end

  test "opening the callers menu closes a rename under way, and a rename closes it", %{
    view: view,
    name: name
  } do
    Session.open_root(name, @greet)
    Session.group_cards(name, "Greeting", [1])

    view |> element("#card-1 .card__callers-toggle") |> render_click()

    assert has_element?(view, "#card-1 .card__callers ul")

    view |> element("#flow-1 .flow__title h3") |> render_click()

    assert has_element?(view, "#flow-1 form.flow__rename")
    refute has_element?(view, "#card-1 .card__callers ul")

    view |> element("#card-1 .card__callers-toggle") |> render_click()

    refute has_element?(view, "#flow-1 form.flow__rename")
    assert has_element?(view, "#card-1 .card__callers ul")
  end

  test "a stub dropped into a frame leaves it with the selection", %{
    view: view,
    name: name
  } do
    Session.open_root(name, @greet_all)

    view
    |> element("#card-1 span.call[data-target='Enum.map/2'][data-external='true']")
    |> render_click()

    Session.group_cards(name, "Greeting", [1])

    render_hook(view, "move_card", %{"card" => 2, "x" => 0, "y" => 0, "group" => 1})

    assert has_element?(view, "#node-2[data-group='1'] #card-2.stub")

    render_hook(view, "toggle_select", %{"card" => "2"})

    assert has_element?(view, "#card-2.stub.card--selected")

    render_hook(view, "ungroup_selected", %{})

    assert has_element?(view, "#node-2[data-group=''] #card-2.stub")
  end

  test "the project line names the base the review is against", %{view: view} do
    assert has_element?(view, ".sidebar__project", "sample_app")
    assert has_element?(view, ".sidebar__base", "main…feature")
  end

  defp open_caller(view, card_id, caller) do
    view |> element("#card-#{card_id} .card__callers-toggle") |> render_click()

    view
    |> element("#card-#{card_id} .card__callers button.caller[phx-value-caller='#{caller}']")
    |> render_click()
  end

  # has_element?/3 answers whether a selector matches at all; a graph keeps one card per
  # function, which is a statement about how many times it matches.
  defp count(view, selector) do
    view |> render() |> LazyHTML.from_fragment() |> LazyHTML.query(selector) |> Enum.count()
  end
end
