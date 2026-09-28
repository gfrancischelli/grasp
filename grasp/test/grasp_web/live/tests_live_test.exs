defmodule GraspWeb.TestsLiveTest do
  use GraspWeb.ConnCase, async: true

  alias Grasp.Comments

  @reply ~s|SampleApp.TallyTest."test handle_call/3 replies with the next number"/1|
  @init ~s|SampleApp.TallyTest."test init keeps the start count"/1|
  @setup "SampleApp.TallyTest.__ex_unit_setup_0/1"
  @plain ~s|SampleAppWeb.RoutesTest."test a plain path reaches the controller"/1|

  setup %{conn: conn} do
    name = "t-#{System.unique_integer([:positive])}"
    {:ok, view, _html} = live(conn, "/s/#{name}")
    %{view: view}
  end

  describe "a test card" do
    test "wears the test badge and titles itself with the test's name under its describe", %{
      view: view
    } do
      render_click(view, "open_root", %{"id" => @reply})

      assert has_element?(
               view,
               "#card-1 .card__header .badge--test[data-test-kind='test']",
               "test"
             )

      assert has_element?(view, "#card-1 .card__module", "handle_call/3")
      refute has_element?(view, "#card-1 .card__module", "SampleApp.TallyTest")
      assert has_element?(view, "#card-1 .card__fn", "replies with the next number")
      refute has_element?(view, "#card-1 .card__fn", "/1")
      refute has_element?(view, "#card-1 .card__kind")
    end

    test "with no describe carries its module in the module slot", %{view: view} do
      render_click(view, "open_root", %{"id" => @init})

      assert has_element?(view, "#card-1 .card__module", "SampleApp.TallyTest")
      assert has_element?(view, "#card-1 .card__fn", "init keeps the start count")
    end

    test "clusters under the module its record names", %{view: view} do
      render_click(view, "open_root", %{"id" => @reply})

      assert has_element?(view, "#node-1[data-module='SampleApp.TallyTest'] #card-1")
    end

    test "reads its assertion lines where a function card reads its head", %{view: view} do
      render_click(view, "open_root", %{"id" => @reply})

      refute has_element?(view, "#card-1 p.card__signature")

      assert has_element?(
               view,
               "#card-1 .card__signature.card__assertions .card__assertion[data-line='13']",
               "assert {:reply, 42, 42} = Counter.handle_call(:next, self(), start)"
             )

      refute has_element?(view, "#card-1 .card__assertion", "@tag")
      refute has_element?(view, "#card-1 .card__assertion", "test \"replies")
    end

    test "highlights each assertion line as code", %{view: view} do
      render_click(view, "open_root", %{"id" => @init})

      html = view |> element("#card-1 .card__assertion[data-line='18']") |> render()

      assert html =~ ~s|<span class="l-function-call">assert</span>|
      assert html =~ ~s|<span class="l-function-call">init_with</span>|
    end
  end

  test "a setup card wears the setup badge and is titled setup", %{view: view} do
    render_click(view, "open_root", %{"id" => @setup})

    assert has_element?(view, "#card-1 .badge--test[data-test-kind='setup']", "setup")
    assert has_element?(view, "#card-1 .card__fn", "setup")
    assert has_element?(view, "#card-1 .card__module", "SampleApp.TallyTest")
    refute has_element?(view, "#card-1 .card__signature")
  end

  describe "the Tests group" do
    test "lists test modules by file, after the entry points and before the modules", %{
      view: view
    } do
      html = render(view)

      kinds =
        html
        |> LazyHTML.from_fragment()
        |> LazyHTML.query("#entries > section.group")
        |> Enum.map(&(LazyHTML.attribute(&1, "data-kind") |> List.first()))

      assert Enum.take(kinds, -2) == ["tests", "modules"]
      assert has_element?(view, "#group-tests[hidden]")
      assert has_element?(view, "#entries .group[data-kind='tests'] .group__count", "4")

      rows =
        html
        |> LazyHTML.from_fragment()
        |> LazyHTML.query("#tests button.module")
        |> Enum.map(&LazyHTML.text/1)
        |> Enum.map(&String.trim/1)

      assert rows == ["SampleApp.TallyTest", "SampleAppWeb.RoutesTest", "SampleApp.SampleCase"]
    end

    test "keeps modules under the test paths out of the module list", %{view: view} do
      assert has_element?(view, "#modules button.module", "SampleApp.Greeter")
      refute has_element?(view, "#modules button.module", "SampleApp.TallyTest")
      refute has_element?(view, "#modules button.module", "SampleApp.SampleCase")
    end

    test "opens a module into its setups and its tests under their describes", %{view: view} do
      view |> element("#entries .group[data-kind='tests'] .group__title") |> render_click()
      refute has_element?(view, "#group-tests[hidden]")
      refute has_element?(view, "#tests button.fn")

      view
      |> element("#tests button.module[phx-value-module='SampleApp.TallyTest']")
      |> render_click()

      assert has_element?(view, "#tests button.fn--setup[phx-value-id='#{@setup}']", "setup")

      assert has_element?(
               view,
               "#tests .tests__describe:has(.tests__heading) button.fn--test[phx-value-id='#{@reply}']",
               "replies with the next number"
             )

      assert has_element?(view, "#tests .tests__heading", "handle_call/3")

      assert has_element?(
               view,
               "#tests .tests__describe:not(:has(.tests__heading)) button[phx-value-id='#{@init}']",
               "init keeps the start count"
             )

      refute has_element?(view, "#tests button[phx-value-id='#{@plain}']")
    end

    test "opens a test's card as a root", %{view: view} do
      view
      |> element("#tests button.module[phx-value-module='SampleAppWeb.RoutesTest']")
      |> render_click()

      view |> element("#tests button[phx-value-id='#{@plain}']") |> render_click()

      assert has_element?(view, "#node-1[data-depth='0'] #card-1[data-function-id='#{@plain}']")
    end
  end

  describe "an id the index does not hold" do
    test "a stub for a test's id reads its module and quoted name", %{view: view} do
      gone = ~s|SampleApp.TallyTest."test handle_call/3 answers nothing"/1|
      render_click(view, "open_root", %{"id" => gone})

      assert has_element?(view, "#node-1[data-module='SampleApp.TallyTest'] #card-1.stub")
      assert has_element?(view, "#card-1 .card__module", "SampleApp.TallyTest.")
      assert has_element?(view, "#card-1 .card__fn", ~s|"test handle_call/3 answers nothing"/1|)
      assert has_element?(view, "#card-1 .stub__text", "No longer in the index")
    end

    test "a thread on a test sits under its module, named as the test is", %{view: view} do
      body = "is 42 the right answer #{System.unique_integer([:positive])}"

      {:ok, thread} =
        Comments.add(%{
          function_id: @reply,
          side: "new",
          line: 13,
          body: body,
          author: "human",
          snippet: "assert {:reply, 42, 42} = Counter.handle_call(:next, self(), start)"
        })

      html = render(view)
      assert html =~ body

      assert has_element?(
               view,
               "#group-comments .group__module:has(.entry--comment[phx-value-id='#{thread.id}']) .group__heading",
               "SampleApp.TallyTest"
             )

      assert has_element?(
               view,
               "#entries .entry--comment[phx-value-id='#{thread.id}'] .entry__where",
               "replies with the next number · L13"
             )
    end
  end

  describe "the palette" do
    test "finds a test by a word of its name and wears its badge", %{view: view} do
      view |> form("#palette-form", %{q: "keeps the start"}) |> render_change()

      assert has_element?(
               view,
               "#palette-results li[data-id='#{@init}'] .badge--test[data-test-kind='test']",
               "test"
             )
    end

    test "finds a test by its module and describe", %{view: view} do
      view |> form("#palette-form", %{q: "tallytest handle_call/3 replies"}) |> render_change()

      assert has_element?(view, "#palette-results li:first-child[data-id='#{@reply}']")
    end
  end
end
