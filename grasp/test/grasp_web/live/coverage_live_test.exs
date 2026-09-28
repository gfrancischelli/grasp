defmodule GraspWeb.CoverageLiveTest do
  # The coverage document lives in :persistent_term, so loading one would be seen by every
  # other test running at the same time.
  use GraspWeb.ConnCase, async: false

  alias Grasp.{Coverage, CoverageStore, IndexStore, Session}

  @greet "SampleApp.Greeter.greet/2"
  @shout "SampleApp.Formatter.shout/1"
  @wrap "SampleApp.Formatter.wrap/1"

  setup do
    path = CoverageStore.path()

    on_exit(fn ->
      File.rm(path)
      :ok = CoverageStore.reload()
    end)

    %{path: path}
  end

  describe "with coverage loaded" do
    setup %{conn: conn, path: path} do
      document =
        Coverage.build(
          IndexStore.get(),
          %{
            {"SampleApp.Greeter", "greet", 2} => %{9 => 2, 10 => 0},
            {"SampleApp.Formatter", "shout", 1} => %{9 => 1, 10 => 0},
            {"SampleApp.Formatter", "wrap", 1} => %{6 => 4}
          },
          %{generated_at: "2026-09-28T12:00:00Z", git_head: nil}
        )

      # wrap/1's entry is written against a body other than the one the index holds.
      document = put_in(document, ["functions", @wrap, "source_hash"], "0")
      :ok = Coverage.write(document, path)
      :ok = CoverageStore.reload()
      mount(conn)
    end

    test "a fresh card marks each counted line run or missed, and no other", %{
      view: view,
      name: name
    } do
      Session.open_root(name, @greet)

      assert has_element?(view, "#card-1 .line[data-line='9'][data-coverage='run']")
      assert has_element?(view, "#card-1 .line[data-line='10'][data-coverage='missed']")
      refute has_element?(view, "#card-1 .line[data-line='8'][data-coverage]")
      refute has_element?(view, "#card-1 .line[data-line='11'][data-coverage]")
      refute has_element?(view, "#card-1 .card__coverage")
      # The clause ran, so nothing in it is a gap.
      refute has_element?(view, "#card-1 .line[data-gap]")
    end

    test "a clause whose every counted line ran zero times is marked never entered", %{
      view: view,
      name: name
    } do
      Session.open_root(name, @shout)

      assert has_element?(view, "#card-1 .line[data-line='10'][data-gap='clause']")
      assert has_element?(view, "#card-1 .line[data-line='10'] .gap-label", "never entered")
      assert has_element?(view, "#card-1 .line[data-gap]", "never entered")
    end

    test "in a diff only the inserted lines carry the tint", %{view: view, name: name} do
      Session.open_root(name, @shout)

      assert has_element?(view, "#card-1[data-view='diff']")
      assert has_element?(view, "#card-1 .line[data-op='ins'][data-coverage='missed']")
      refute has_element?(view, "#card-1 .line[data-op='eq'][data-coverage]")
    end

    test "a stale card says so in its header and marks no line", %{view: view, name: name} do
      Session.open_root(name, @wrap)

      assert has_element?(view, "#card-1 .card__header .card__coverage", "coverage stale")
      refute has_element?(view, "#card-1 .line[data-coverage]")
      refute has_element?(view, "#card-1 .line[data-gap]")
    end

    test "the toolbar's coverage toggle is the hook's and is enabled", %{view: view} do
      assert has_element?(
               view,
               "#canvas .toolbar #toggle-coverage[aria-pressed='false'][phx-update='ignore'][data-available='true']:not([disabled])",
               "coverage"
             )

      refute has_element?(view, "#canvas .toolbar #toggle-coverage[phx-click]")
    end

    test "coverage that goes away marks the toggle unavailable and unmarks the cards", %{
      view: view,
      name: name,
      path: path
    } do
      Session.open_root(name, @greet)
      assert has_element?(view, "#card-1 .line[data-coverage]")

      File.rm!(path)
      :ok = CoverageStore.reload()

      # `disabled` on the ignored button is the hook's to keep in step; a patch carries only
      # its data attributes.
      assert has_element?(view, "#toggle-coverage[data-available='false']")
      refute has_element?(view, "#card-1 .line[data-coverage]")
    end
  end

  describe "without coverage" do
    setup %{conn: conn}, do: mount(conn)

    test "a card with no coverage entry marks nothing", %{view: view, name: name} do
      Session.open_root(name, @greet)

      assert has_element?(view, "#card-1 .line[data-line='9']")
      refute has_element?(view, "#card-1 .line[data-coverage]")
      refute has_element?(view, "#card-1 .card__coverage")
    end

    test "without coverage the toggle is disabled, and a document written later makes it available",
         %{
           view: view,
           path: path
         } do
      assert has_element?(view, "#toggle-coverage[disabled][data-available='false']")

      document =
        Coverage.build(
          IndexStore.get(),
          %{{"SampleApp.Greeter", "greet", 2} => %{9 => 1}},
          %{generated_at: "2026-09-28T12:00:00Z", git_head: nil}
        )

      :ok = Coverage.write(document, path)
      :ok = CoverageStore.reload()

      assert has_element?(view, "#toggle-coverage[data-available='true']")
    end

    test "the toggle sits beside signatures and names its key", %{view: view} do
      html = render(view)

      positions =
        for id <- ~w(toggle-signatures toggle-coverage toggle-modules) do
          {position, _length} = :binary.match(html, ~s(id="#{id}"))
          position
        end

      assert positions == Enum.sort(positions)

      assert has_element?(
               view,
               "#canvas .toolbar #toggle-coverage[data-tip='What the suite ran'][data-key='V']"
             )
    end

    test "the help dialog lists the coverage key", %{view: view} do
      assert render(view) =~ "<kbd>v</kbd>"

      assert has_element?(
               view,
               "#help dd",
               "What the suite ran, and the clauses it never entered."
             )
    end
  end

  defp mount(conn) do
    name = "t-#{System.unique_integer([:positive])}"
    {:ok, view, _html} = live(conn, "/s/#{name}")
    %{view: view, name: name}
  end
end
