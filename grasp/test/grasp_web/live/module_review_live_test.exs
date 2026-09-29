defmodule GraspWeb.ModuleReviewLiveTest do
  # The index lives in :persistent_term, so swapping it out would be seen by every other
  # test running at the same time.
  use GraspWeb.ConnCase, async: false

  alias Grasp.{Comments, IndexStore}

  @fixture Path.expand("../../fixtures/index.json", __DIR__)
  @shout "SampleApp.Formatter.shout/1"
  @hello "SampleApp.Greeter.Nested.hello/0"

  setup %{conn: conn} do
    :ok = IndexStore.load(with_changed_moduledocs())
    on_exit(fn -> :ok = IndexStore.load(@fixture) end)

    name = "mr-#{System.unique_integer([:positive])}"
    {:ok, view, _html} = live(conn, "/s/#{name}")
    %{conn: conn, view: view, name: name}
  end

  describe "the Changes group" do
    test "a changed moduledoc is the first row under its module's heading, with its badge", %{
      view: view
    } do
      module = "#group-changes .group__module:has(.entry[phx-value-module='SampleApp.Formatter'])"

      assert has_element?(
               view,
               module <>
                 " .entry:first-of-type[phx-click='open_module']" <>
                 "[phx-value-module='SampleApp.Formatter']",
               "@moduledoc"
             )

      assert has_element?(
               view,
               module <>
                 " .entry[phx-value-module='SampleApp.Formatter'] " <>
                 ".badge--change[data-change='modified']"
             )

      assert has_element?(view, module <> " .entry[phx-value-id='#{@shout}']")
    end

    test "a modified moduledoc's row opens the module card on its diff", %{view: view} do
      view
      |> element("#group-changes .entry[phx-value-module='SampleApp.Formatter']")
      |> render_click()

      assert has_element?(
               view,
               "#card-1.card--module[data-function-id='SampleApp.Formatter'][data-view='diff']"
             )
    end

    test "a module whose only change is its moduledoc gets a heading for its row", %{
      view: view
    } do
      assert has_element?(view, "#group-changes .group__heading", "SampleAppWeb.RequestId")

      row = "#group-changes .entry[phx-value-module='SampleAppWeb.RequestId']"
      assert has_element?(view, row <> " .badge--change[data-change='added']")
      refute has_element?(view, row <> "[phx-value-view]")

      view |> element(row) |> render_click()

      assert has_element?(
               view,
               "#card-1.card--module[data-function-id='SampleAppWeb.RequestId'][data-view='doc']"
             )
    end

    test "a moduledoc is never an untested change, nor paired with tests", %{view: view} do
      assert has_element?(view, "#group-untested .group__heading", "SampleApp.Greeter.Nested")
      assert has_element?(view, "#group-untested .entry[phx-value-id='#{@hello}']")

      assert has_element?(
               view,
               "#entries [data-kind='untested'] .group__title .group__count",
               "1"
             )

      refute has_element?(view, "#group-untested .entry[phx-value-id='SampleApp.Greeter.Nested']")
      refute has_element?(view, "#group-untested .entry[phx-value-id='SampleAppWeb.RequestId']")
      refute has_element?(view, "#group-untested .group__heading", "SampleAppWeb.RequestId")
      refute has_element?(view, "#group-changes .entry--moduledoc [data-untested]")

      refute has_element?(
               view,
               "#group-changes .group__module:has(.entry[phx-value-module='SampleAppWeb.RequestId']) " <>
                 ".entry--paired"
             )
    end
  end

  describe "comments on a module card" do
    test "a thread on a moduledoc line is listed under its module and opens its card on it", %{
      view: view,
      name: name
    } do
      {:ok, thread} =
        Comments.add(%{
          session: name,
          function_id: "SampleApp.Greeter",
          side: "new",
          line: 2,
          author: "human",
          body: "say what it greets",
          snippet:
            ~s(@moduledoc "Greets people, exercising aliases, imports, defaults, ) <>
              ~s(captures and nesting.")
        })

      render(view)
      row = "#entries .entry--comment[phx-value-id='#{thread.id}']"

      assert has_element?(
               view,
               "#group-comments .group__module:has(.entry--comment[phx-value-id='#{thread.id}']) " <>
                 ".group__heading",
               "SampleApp.Greeter"
             )

      assert has_element?(view, row <> " .entry__where", "@moduledoc · L2")
      refute has_element?(view, row <> ".entry--orphan")

      view |> element(row) |> render_click()

      assert has_element?(
               view,
               "#card-1.card--module[data-view='source'] .line[data-line='2'][data-highlight='true']"
             )

      assert has_element?(view, "#card-1 .card__body .thread", "say what it greets")
    end

    test "a moduledoc the branch removed shows its base lines and takes comments on them", %{
      view: view
    } do
      render_click(view, "open_module", %{"module" => "SampleApp.Workers.Mailer"})

      assert has_element?(view, "#card-1 .card__views button[phx-value-view='diff']")
      render_click(view, "set_view", %{"card" => "1", "view" => "diff"})

      line = "#card-1[data-view='diff'] .line[data-op='del'][data-base-line='1']"
      assert has_element?(view, line, "An Oban worker.")

      view |> element(line <> " .ln") |> render_click()
      view |> form("#card-1 form.composer", %{"body" => "why did it go"}) |> render_submit()

      assert has_element?(view, "#card-1 .card__body .thread", "why did it go")

      render_click(view, "set_view", %{"card" => "1", "view" => "doc"})
      assert has_element?(view, "#card-1 .card__outdated .thread", "why did it go")
    end

    test "the new side of a module without moduledoc lines takes no comment", %{view: view} do
      render_click(view, "open_module", %{"module" => "SampleApp.Workers.Mailer"})

      render_click(view, "comment_start", %{"card" => "1", "side" => "new", "line" => "2"})

      refute has_element?(view, "#card-1 form.composer")
    end

    test "a thread on a module the index lost is listed under its name, muted", %{
      view: view,
      name: name
    } do
      {:ok, thread} =
        Comments.add(%{
          session: name,
          function_id: "SampleApp.Gone",
          side: "new",
          line: 2,
          author: "human",
          body: "gone"
        })

      render(view)
      row = "#entries .entry--comment[phx-value-id='#{thread.id}']"

      assert has_element?(view, row <> ".entry--orphan .entry__where", "@moduledoc · L2")

      assert has_element?(
               view,
               "#group-comments .group__module:has(.entry--comment[phx-value-id='#{thread.id}']) " <>
                 ".group__heading",
               "SampleApp.Gone"
             )
    end
  end

  describe "the palette" do
    test "answers a module by name, marked module, and opens its card", %{view: view} do
      view |> form("#palette-form", %{q: "SampleApp.Counter"}) |> render_change()

      result = "#palette-results li:first-child[data-id='SampleApp.Counter']"
      assert has_element?(view, result <> " .badge--module", "module")
      assert has_element?(view, result <> " .palette__meta", "lib/sample_app/counter.ex")
      refute has_element?(view, result <> " .palette__meta", "module")
      assert has_element?(view, "#palette-results li[data-id='SampleApp.Counter.init/1']")

      render_hook(view, "palette_choose", %{"child" => false})

      assert has_element?(view, "#card-1.card--module[data-function-id='SampleApp.Counter']")
      refute has_element?(view, "dialog#palette[open]")
    end

    test "clicking a module result opens the module card beside the focused card", %{
      view: view
    } do
      render_click(view, "open_root", %{"id" => @shout})
      view |> form("#palette-form", %{q: "SampleApp.Counter"}) |> render_change()

      view
      |> element("#palette-results li[data-id='SampleApp.Counter'] button")
      |> render_click()

      assert has_element?(view, "#node-2[data-depth='0'] #card-2.card--module")
      assert has_element?(view, "#node-2[data-near='1']")
    end
  end

  defp with_changed_moduledocs do
    document = @fixture |> File.read!() |> Jason.decode!()

    modules =
      Enum.map(document["modules"], fn
        %{"name" => "SampleApp.Formatter"} = module ->
          Map.merge(module, %{
            "change" => "modified",
            "base_source" => ~s(  @moduledoc "Decorations."),
            "base_doc" => %{"text" => "Decorations.", "hidden" => false}
          })

        %{"name" => "SampleApp.Greeter.Nested"} = module ->
          Map.merge(module, %{
            "change" => "modified",
            "base_source" => ~s(    @moduledoc "Nested."),
            "base_doc" => %{"text" => "Nested.", "hidden" => false}
          })

        %{"name" => "SampleAppWeb.RequestId"} = module ->
          Map.put(module, "change", "added")

        %{"name" => "SampleApp.Workers.Mailer"} = module ->
          module
          |> Map.drop(["source", "span"])
          |> Map.merge(%{
            "doc" => nil,
            "change" => "removed",
            "base_source" => ~s(  @moduledoc "An Oban worker."),
            "base_doc" => %{"text" => "An Oban worker.", "hidden" => false}
          })

        module ->
          module
      end)

    document = %{document | "modules" => modules}

    path =
      Path.join(
        System.tmp_dir!(),
        "grasp-module-review-#{System.unique_integer([:positive])}.json"
      )

    File.write!(path, Jason.encode!(document))
    on_exit(fn -> File.rm(path) end)
    path
  end
end
