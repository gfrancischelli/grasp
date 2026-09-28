defmodule GraspWeb.TestReviewLiveTest do
  # The index lives in :persistent_term, so swapping it out would be seen by every other
  # test running at the same time.
  use GraspWeb.ConnCase, async: false

  alias Anubis.Server.Frame
  alias Anubis.Server.Response
  alias Grasp.IndexStore
  alias Grasp.MCP.Tools

  @fixture Path.expand("../../fixtures/index.json", __DIR__)
  @init ~s|SampleApp.TallyTest."test init keeps the start count"/1|
  @plain ~s|SampleAppWeb.RoutesTest."test a plain path reaches the controller"/1|
  @base_assertion "assert init_with(7) == {:ok, 7}"

  setup %{conn: conn} do
    :ok = IndexStore.load(with_review())
    on_exit(fn -> :ok = IndexStore.load(@fixture) end)

    {:ok, view, _html} = live(conn, "/s/t-#{System.unique_integer([:positive])}")
    %{view: view}
  end

  test "a weakened test's card wears the mark, with the reasons on its title", %{view: view} do
    render_click(view, "open_root", %{"id" => @init})

    badge = "#card-1 .card__header .badge--review[data-review='weakened']"
    assert has_element?(view, badge, "assertion weakened")

    badge_html = view |> element(badge) |> render() |> LazyHTML.from_fragment()

    assert LazyHTML.attribute(badge_html, "title") == [
             "removed: #{@base_assertion}\nloosened: #{@base_assertion}"
           ]
  end

  test "an added test with no assertion wears asserts nothing", %{view: view} do
    render_click(view, "open_root", %{"id" => @plain})

    assert has_element?(
             view,
             "#card-1 .card__header .badge--review[data-review='asserts_nothing']",
             "asserts nothing"
           )
  end

  test "an unmarked test's card wears no review badge", %{view: view} do
    render_click(view, "open_root", %{
      "id" => ~s|SampleApp.TallyTest."test handle_call/3 replies with the next number"/1|
    })

    assert has_element?(view, "#card-1")
    refute has_element?(view, "#card-1 .badge--review")
  end

  test "the Test review group opens on arrival and opens a marked test as a root", %{
    view: view
  } do
    assert has_element?(view, "#group-review:not([hidden])")

    view
    |> element("#group-review button", "init keeps the start count")
    |> render_click()

    assert has_element?(view, "#card-1[data-function-id='#{@init}']")
  end

  test "the test_review tool answers the marks, sorted by id" do
    {:reply, %Response{isError: false} = resp, _frame} = Tools.TestReview.execute(%{}, %Frame{})
    [%{"type" => "text", "text" => text}] = resp.content

    assert Jason.decode!(text) == %{
             "tests" => [
               %{
                 "id" => @init,
                 "mark" => "weakened",
                 "reasons" => ["removed: #{@base_assertion}", "loosened: #{@base_assertion}"]
               },
               %{"id" => @plain, "mark" => "asserts_nothing", "reasons" => []}
             ]
           }
  end

  test "the test_review tool answers an empty list without a base ref" do
    :ok = IndexStore.load(@fixture)

    {:reply, resp, _frame} = Tools.TestReview.execute(%{}, %Frame{})
    [%{"type" => "text", "text" => text}] = resp.content

    assert Jason.decode!(text) == %{"tests" => []}
    refute Tools.TestReview.input_schema()["required"]
  end

  defp with_review do
    document = @fixture |> File.read!() |> Jason.decode!()

    functions =
      Enum.map(document["functions"], fn
        %{"id" => @init, "source" => source} = record ->
          Map.merge(record, %{
            "change" => "modified",
            "base_source" => source,
            "source" =>
              String.replace(source, @base_assertion, "assert match?({:ok, _}, init_with(7))")
          })

        %{"id" => @plain, "source" => source} = record ->
          Map.merge(record, %{
            "change" => "added",
            "source" => String.replace(source, ~r/assert .*/, ":ok")
          })

        record ->
          record
      end)

    path = Path.join(System.tmp_dir!(), "grasp-review-#{System.unique_integer([:positive])}.json")
    File.write!(path, Jason.encode!(%{document | "functions" => functions}))
    on_exit(fn -> File.rm(path) end)
    path
  end
end
