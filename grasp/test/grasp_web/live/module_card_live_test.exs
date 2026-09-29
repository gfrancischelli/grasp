defmodule GraspWeb.ModuleCardLiveTest do
  # The index lives in :persistent_term, so swapping it out would be seen by every other
  # test running at the same time.
  use GraspWeb.ConnCase, async: false

  alias Grasp.{IndexStore, Session}

  @fixture Path.expand("../../fixtures/index.json", __DIR__)
  @greet "SampleApp.Greeter.greet/2"
  @wrap "SampleApp.Formatter.wrap/1"
  @greeter_doc """
  # Greetings

  Greets people through `SampleApp.Formatter` and `SampleApp.Formatter.wrap/1`,
  never `SampleApp.Nowhere`.

  <script>alert(1)</script>
  """

  setup %{conn: conn} do
    :ok = IndexStore.load(with_moduledocs())
    on_exit(fn -> :ok = IndexStore.load(@fixture) end)

    name = "m-#{System.unique_integer([:positive])}"
    {:ok, view, _html} = live(conn, "/s/#{name}")
    %{view: view, name: name}
  end

  describe "opening" do
    test "the module part of a function card's title opens the module card as a root", %{
      view: view
    } do
      render_click(view, "open_root", %{"id" => @greet})

      title = "#card-1 .card__title button.card__module[phx-value-module='SampleApp.Greeter']"
      assert has_element?(view, title <> "[title='Greetings']")

      view |> element(title) |> render_click()

      assert has_element?(view, "#card-2.card--module[data-function-id='SampleApp.Greeter']")
      assert has_element?(view, "#card-2[data-focused='true']")
      assert has_element?(view, "#node-2[data-module='SampleApp.Greeter'][data-near='1']")
      assert has_element?(view, "#node-2[data-depth='0']")
      refute has_element?(view, "#card-1 [data-edge-to='2']")

      render_click(view, "focus_card", %{"card" => "1"})
      view |> element(title) |> render_click()

      assert has_element?(view, "#card-2[data-focused='true']")
      refute has_element?(view, "#card-3")
    end

    test "a module without a summary is titled by its name", %{view: view} do
      render_click(view, "open_root", %{"id" => @wrap})

      assert has_element?(
               view,
               "#card-1 button.card__module[phx-value-module='SampleApp.Formatter']" <>
                 "[title='SampleApp.Formatter']"
             )
    end

    test "open_module with no card opens the module card, and ignores a name the index lacks",
         %{view: view} do
      render_click(view, "open_module", %{"module" => "SampleApp.Nowhere"})
      refute has_element?(view, "#card-1")

      render_click(view, "open_module", %{"module" => "SampleApp.Counter"})

      assert has_element?(view, "#card-1.card--module[data-function-id='SampleApp.Counter']")
      refute has_element?(view, "#node-1[data-near]")
    end

    test "open_module can open the card on its diff", %{view: view} do
      render_click(view, "open_module", %{"module" => "SampleApp.Counter", "view" => "diff"})

      assert has_element?(view, "#card-1[data-view='diff']")
    end
  end

  describe "the card" do
    test "its header names the module, its behaviours and its change", %{view: view} do
      render_click(view, "open_module", %{"module" => "SampleApp.Counter"})

      header = "#card-1 .card__header"
      assert has_element?(view, header <> " .card__fn", "SampleApp.Counter")
      assert has_element?(view, header <> " .badge--module", "module")
      assert has_element?(view, header <> " .badge--behaviour", "GenServer")
      assert has_element?(view, header <> " .badge--change[data-change='modified']")
      assert has_element?(view, header <> " .card__file", "lib/sample_app/counter.ex:1")
      assert has_element?(view, header <> " .card__close")

      refute has_element?(view, header <> " .card__callers")
      refute has_element?(view, header <> " .card__tests")
      refute has_element?(view, header <> " .card__run")
    end

    test "the doc view renders the moduledoc as sanitized Markdown with card links", %{
      view: view
    } do
      render_click(view, "open_module", %{"module" => "SampleApp.Greeter"})

      doc = "#card-1[data-view='doc'] .card__doc"
      assert has_element?(view, doc <> " h1", "Greetings")
      assert has_element?(view, doc <> " button.fn[data-fn='SampleApp.Formatter']")
      assert has_element?(view, doc <> " button.fn[data-fn='SampleApp.Formatter.wrap/1']")
      assert has_element?(view, doc <> " code", "SampleApp.Nowhere")
      refute has_element?(view, doc <> " button.fn[data-fn='SampleApp.Nowhere']")
      refute has_element?(view, doc <> " script")
      refute render(view) =~ "alert(1)"

      render_click(view, "open_root", %{"id" => "SampleApp.Formatter"})
      assert has_element?(view, "#card-2.card--module[data-function-id='SampleApp.Formatter']")
    end

    test "the source view numbers the attribute's lines and takes a line comment", %{
      view: view
    } do
      render_click(view, "open_module", %{"module" => "SampleApp.Greeter"})
      render_click(view, "set_view", %{"card" => "1", "view" => "source"})

      assert has_element?(view, "#card-1[data-view='source'] .card__body .line[data-line='2']")
      refute has_element?(view, "#card-1 .card__doc")

      view |> element("#card-1 .line[data-line='2'] .ln") |> render_click()
      view |> form("#card-1 form.composer", %{"body" => "a doc worth a line"}) |> render_submit()

      assert has_element?(view, "#card-1 .card__body .thread", "a doc worth a line")

      render_click(view, "set_view", %{"card" => "1", "view" => "doc"})
      assert has_element?(view, "#card-1 .card__outdated .thread", "a doc worth a line")
    end

    test "the diff view is offered only for a modified moduledoc", %{view: view} do
      render_click(view, "open_module", %{"module" => "SampleApp.Counter"})

      assert has_element?(view, "#card-1 .card__views button[phx-value-view='diff']")
      render_click(view, "set_view", %{"card" => "1", "view" => "diff"})

      assert has_element?(view, "#card-1[data-view='diff'] .line[data-op='del']", "A counter.")
      assert has_element?(view, "#card-1[data-view='diff'] .line[data-op='ins']", "GenServer")

      render_click(view, "open_module", %{"module" => "SampleApp.Greeter"})

      assert has_element?(view, "#card-2 .card__views button[phx-value-view='source']")
      refute has_element?(view, "#card-2 .card__views button[phx-value-view='diff']")
    end

    test "the keyboard's view toggle swaps a modified moduledoc's doc and diff", %{view: view} do
      render_click(view, "open_module", %{"module" => "SampleApp.Counter"})

      render_click(view, "toggle_view_focused", %{})
      assert has_element?(view, "#card-1[data-view='diff']")

      render_click(view, "toggle_view_focused", %{})
      assert has_element?(view, "#card-1[data-view='doc']")
    end

    test "a hidden moduledoc says so", %{view: view} do
      render_click(view, "open_module", %{"module" => "SampleApp.Formatter"})

      assert has_element?(view, "#card-1 .card__doc", "Hidden from the docs")
      assert has_element?(view, "#card-1 .card__doc code", "@moduledoc false")
    end

    test "a module with no moduledoc says so and has nothing else to show", %{view: view} do
      render_click(view, "open_module", %{"module" => "SampleApp.TallyTest"})

      assert has_element?(view, "#card-1 .card__doc", "No")
      assert has_element?(view, "#card-1 .card__doc code", "@moduledoc")
      refute has_element?(view, "#card-1 .card__views")
    end

    test "a moduledoc that is not a literal shows only its source", %{view: view} do
      render_click(view, "open_module", %{"module" => "SampleApp.Audited"})

      assert has_element?(view, "#card-1[data-view='source'] .line", "@moduledoc @text")
      refute has_element?(view, "#card-1 .card__doc")
      refute has_element?(view, "#card-1 .card__views")
    end

    test "a removed module is drawn from its base, as a removed function is", %{view: view} do
      render_click(view, "open_module", %{"module" => "SampleApp.Legacy"})

      assert has_element?(view, "#card-1.card--removed.card--module")
      assert has_element?(view, "#card-1 .badge--change[data-change='removed']")
      assert has_element?(view, "#card-1 .card__doc", "Retired.")
      refute has_element?(view, "#card-1 a.card__file")
      assert has_element?(view, "#card-1 span.card__file", "lib/sample_app/legacy.ex:1")
    end
  end

  test "a module card is kept by its session and dropped once its module leaves the index", %{
    conn: conn,
    name: name
  } do
    Session.open_root(name, "SampleApp.Counter")
    Session.open_root(name, "SampleApp.Gone")
    forest = Session.get(name)

    assert {:ok, loaded} =
             Grasp.Session.Forest.load(Grasp.Session.Forest.dump(forest), IndexStore.get())

    assert Enum.map(Map.values(loaded.cards), & &1.function_id) == ["SampleApp.Counter"]

    {:ok, view, _html} = live(conn, "/s/#{name}")
    assert has_element?(view, "#card-1.card--module")
  end

  defp with_moduledocs do
    document = @fixture |> File.read!() |> Jason.decode!()

    modules =
      Enum.map(document["modules"], fn
        %{"name" => "SampleApp.Greeter"} = module ->
          %{module | "doc" => %{"text" => @greeter_doc, "hidden" => false}}

        %{"name" => "SampleApp.Counter"} = module ->
          Map.merge(module, %{
            "change" => "modified",
            "base_source" => ~s(  @moduledoc "A counter."),
            "base_doc" => %{"text" => "A counter.", "hidden" => false}
          })

        %{"name" => "SampleApp.Formatter"} = module ->
          Map.merge(module, %{
            "doc" => %{"text" => nil, "hidden" => true},
            "source" => "  @moduledoc false"
          })

        %{"name" => "SampleApp.Audited"} = module ->
          Map.merge(module, %{
            "doc" => %{"text" => nil, "hidden" => false},
            "source" => "  @moduledoc @text"
          })

        module ->
          module
      end)

    legacy = %{
      "id" => "SampleApp.Legacy",
      "kind" => "module",
      "name" => "SampleApp.Legacy",
      "file" => "lib/sample_app/legacy.ex",
      "line" => 1,
      "behaviours" => [],
      "doc" => %{"text" => "Retired.", "hidden" => false},
      "span" => %{"start_line" => 2, "end_line" => 2},
      "source" => ~s(  @moduledoc "Retired."),
      "change" => "removed",
      "removed" => true
    }

    document = %{document | "modules" => modules ++ [legacy]}

    path =
      Path.join(System.tmp_dir!(), "grasp-moduledocs-#{System.unique_integer([:positive])}.json")

    File.write!(path, Jason.encode!(document))
    on_exit(fn -> File.rm(path) end)
    path
  end
end
