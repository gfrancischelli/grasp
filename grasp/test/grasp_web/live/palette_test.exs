defmodule GraspWeb.PaletteTest do
  use GraspWeb.ConnCase, async: true

  alias Grasp.Session

  @greet "SampleApp.Greeter.greet/2"
  @greet_all "SampleApp.Greeter.greet_all/1"
  @wrap "SampleApp.Formatter.wrap/1"
  @shout "SampleApp.Formatter.shout/1"
  @last_greet "SampleAppWeb.GreetingComponent.handle_event/3"
  @show "SampleAppWeb.GreetController.show/2"
  @greet_alias "SampleApp.Greeter.greet/1"

  setup %{conn: conn} do
    name = "t-#{System.unique_integer([:positive])}"
    {:ok, view, _html} = live(conn, "/s/#{name}")
    %{view: view, name: name}
  end

  test "the palette is a hook-driven dialog whose results push palette_open", %{view: view} do
    assert has_element?(view, "dialog#palette[phx-hook='Palette'][data-open='false']")
    refute has_element?(view, "dialog#palette[open]")
    refute has_element?(view, ".palette-backdrop")

    search(view, "greet")

    assert has_element?(
             view,
             "#palette-results li[data-id='#{@greet}'] button.palette__item[phx-click='palette_open']"
           )
  end

  test "palette_show opens the dialog and its backdrop", %{view: view} do
    render_hook(view, "palette_show", %{})

    assert has_element?(view, "dialog#palette[open][data-open='true']")
    assert has_element?(view, ".palette-backdrop[phx-click='palette_hide']")
  end

  test "palette_hide closes the dialog and clears the query and results", %{view: view} do
    render_hook(view, "palette_show", %{})
    search(view, "greet")
    assert has_element?(view, "#palette-results li")

    render_hook(view, "palette_hide", %{})

    refute has_element?(view, "dialog#palette[open]")
    refute has_element?(view, ".palette-backdrop")
    refute has_element?(view, "#palette-results li")
    assert has_element?(view, "#palette-form input[name='q'][value='']")
  end

  test "typing searches the index and ranks results", %{view: view} do
    search(view, "greet")

    assert has_element?(view, "#palette-results li[data-id='#{@greet}'] button", @greet)
    assert has_element?(view, "#palette-results li[data-id='#{@greet_all}']")
    refute has_element?(view, "#palette-results li[data-id='#{@wrap}']")
    assert has_element?(view, "#palette-results li:first-child[aria-selected='true']")
  end

  test "an empty query shows no results", %{view: view} do
    search(view, "  ")
    refute has_element?(view, "#palette-results li")
  end

  test "palette_move walks the results and palette_choose opens the selected one", %{view: view} do
    render_hook(view, "palette_show", %{})
    search(view, "e")

    for _ <- 1..3, do: render_hook(view, "palette_move", %{"delta" => 1})
    assert has_element?(view, "#palette-results li[data-id='#{@shout}'][aria-selected='true']")

    render_hook(view, "palette_choose", %{"child" => false})

    assert has_element?(view, "#node-1[data-depth='0'] #card-1[data-function-id='#{@shout}']")
    refute has_element?(view, "dialog#palette[open]")
    refute has_element?(view, "#palette-results li")
  end

  test "palette_move clamps at both ends of the results", %{view: view} do
    search(view, "greet/")

    render_hook(view, "palette_move", %{"delta" => -1})
    assert has_element?(view, "#palette-results li[data-id='#{@greet}'][aria-selected='true']")

    for _ <- 1..10, do: render_hook(view, "palette_move", %{"delta" => 1})

    assert has_element?(
             view,
             "#palette-results li[data-id='#{@last_greet}'][aria-selected='true']"
           )

    assert has_element?(view, "#palette-results li:last-child[aria-selected='true']")
  end

  test "palette_choose without a child flag opens a root", %{view: view} do
    search(view, "greet")
    render_hook(view, "palette_choose", %{"q" => "greet"})

    assert has_element?(view, "#node-1[data-depth='0'] #card-1[data-function-id='#{@greet}']")
  end

  test "clicking a result opens it as a root and closes the palette", %{view: view} do
    render_hook(view, "palette_show", %{})
    search(view, "wrap")

    view |> element("#palette-results li[data-id='#{@wrap}'] button") |> render_click()

    assert has_element?(view, "#node-1[data-depth='0'] #card-1[data-function-id='#{@wrap}']")
    refute has_element?(view, "dialog#palette[open]")
  end

  test "palette_open opens a root and closes the palette", %{view: view} do
    render_hook(view, "palette_show", %{})
    render_hook(view, "palette_open", %{"id" => @wrap, "child" => false})

    assert has_element?(view, "#node-1[data-depth='0'] #card-1[data-function-id='#{@wrap}']")
    refute has_element?(view, "dialog#palette[open]")
  end

  test "palette_open with child: true opens under the focused card", %{view: view, name: name} do
    Session.open_root(name, @greet)
    render_hook(view, "palette_open", %{"id" => @wrap, "child" => true})

    assert has_element?(
             view,
             "#node-2[data-depth='1'] #card-2[data-function-id='#{@wrap}']"
           )
  end

  test "a child opened by Shift+Enter paints the call site the parent actually writes", %{
    view: view,
    name: name
  } do
    Session.open_root(name, @show)
    render_hook(view, "palette_show", %{})
    search(view, "greet/2")

    assert has_element?(view, "#palette-results li:first-child[data-id='#{@greet}']")

    render_hook(view, "palette_choose", %{"child" => true})

    assert has_element?(
             view,
             "#node-2[data-depth='1'] #card-2[data-function-id='#{@greet}']"
           )

    assert has_element?(
             view,
             "#card-1 span.call[data-target='#{@greet_alias}'][data-open='true'][data-color='0'][data-edge-to='2']"
           )
  end

  test "palette_open with child: true and no focus opens a root", %{view: view} do
    render_hook(view, "palette_open", %{"id" => @wrap, "child" => true})
    assert has_element?(view, "#node-1[data-depth='0'] #card-1")
  end

  test "a result the branch changed wears its change badge", %{view: view} do
    search(view, "shout")

    assert has_element?(
             view,
             "#palette-results li[data-id='#{@shout}'] .badge--change[data-change='modified']",
             "modified"
           )

    search(view, "wrap")

    assert has_element?(view, "#palette-results li[data-id='#{@wrap}']")
    refute has_element?(view, "#palette-results li[data-id='#{@wrap}'] .badge--change")
  end

  defp search(view, query) do
    view |> form("#palette-form", %{q: query}) |> render_change()
  end
end
