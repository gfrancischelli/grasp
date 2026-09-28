defmodule GraspWeb.DoublesLiveTest do
  # The index lives in :persistent_term, so swapping it out would be seen by every other
  # test running at the same time.
  use GraspWeb.ConnCase, async: false

  alias Grasp.{IndexStore, TracedDoubles}

  @fixture Path.expand("../../fixtures/index.json", __DIR__)
  @init ~s|SampleApp.TallyTest."test init keeps the start count"/1|
  @wrap "SampleApp.Formatter.wrap/1"

  setup %{conn: conn} do
    :ok = IndexStore.load(with_double())
    on_exit(fn -> :ok = IndexStore.load(@fixture) end)

    {:ok, view, _html} = live(conn, "/s/t-#{System.unique_integer([:positive])}")
    %{view: view}
  end

  test "a double reads as one on the test card, opens its target and draws a kinded edge", %{
    view: view
  } do
    render_click(view, "open_root", %{"id" => @init})

    site =
      "#card-1 .line[data-line='18'] span.call[data-kind='double'][data-target='#{@wrap}']" <>
        "[title='Mox double of SampleApp.Formatting']"

    assert has_element?(view, site)

    view |> element(site) |> render_click()

    assert has_element?(view, "#node-2[data-depth='1'] #card-2[data-function-id='#{@wrap}']")
    assert has_element?(view, site <> "[data-open='true'][data-edge-to='2']")
  end

  test "a traced expectation reads as its double, and every other implementation is one click away",
       %{conn: conn} do
    :ok = IndexStore.load(with_traced_doubles())
    {:ok, view, _html} = live(conn, "/s/t-#{System.unique_integer([:positive])}")

    render_click(view, "open_root", %{"id" => TracedDoubles.test_id()})

    site =
      "#card-1 .line[data-line='6'] span.call[data-kind='double']" <>
        "[data-target='SampleApp.Geo.Ip.lookup/1']" <>
        "[title='Mox double of SampleApp.Geo: SampleApp.Geo.Ip, SampleApp.Geo.Static']"

    assert has_element?(view, site)
    refute has_element?(view, "#card-1 span.call[data-target^='Mox.']")

    also =
      "#card-1 .card__also button.also[data-kind='double']" <>
        "[title='Mox double of SampleApp.Geo'][phx-value-target='SampleApp.Geo.Static.lookup/1']"

    assert has_element?(view, also, "SampleApp.Geo.Static.lookup/1")

    view |> element(also) |> render_click()

    assert has_element?(
             view,
             "#node-2[data-depth='1'] #card-2[data-function-id='SampleApp.Geo.Static.lookup/1']"
           )

    assert has_element?(view, also <> "[data-open='true'][data-edge-to='2']")

    view |> element(site) |> render_click()

    assert has_element?(view, "#card-3[data-function-id='SampleApp.Geo.Ip.lookup/1']")
    assert has_element?(view, site <> "[data-open='true'][data-edge-to='3']")
  end

  test "the doubled function's callers menu leaves the test out", %{view: view} do
    render_click(view, "open_root", %{"id" => @wrap})
    view |> element("#card-1 .card__callers-toggle", "callers (1)") |> render_click()

    assert has_element?(view, "#card-1 .card__callers ul button.caller", "SampleApp.Greeter")
    refute has_element?(view, "#card-1 .card__callers ul", "init keeps")
  end

  test "the stylesheet dashes a double's edge and dots its call site", %{conn: conn} do
    css = conn |> get("/assets/grasp.css") |> response(200)

    assert css =~ ~r/\.connectors \.edge\[data-kind="?double"?\],?[^{]*\{[^}]*stroke-dasharray/
    assert css =~ ~r/\.call\[data-kind="?double"?\][^{]*\{[^}]*border-bottom-style: dotted/
  end

  defp with_traced_doubles do
    document = @fixture |> File.read!() |> Jason.decode!()

    document = %{
      document
      | "functions" => document["functions"] ++ TracedDoubles.records_json(),
        "modules" => document["modules"] ++ TracedDoubles.modules()
    }

    path = Path.join(System.tmp_dir!(), "grasp-traced-#{System.unique_integer([:positive])}.json")
    File.write!(path, Jason.encode!(document))
    on_exit(fn -> File.rm(path) end)
    path
  end

  defp with_double do
    document = @fixture |> File.read!() |> Jason.decode!()

    functions =
      Enum.map(document["functions"], fn
        %{"id" => @init} = record ->
          Map.update!(record, "calls", fn calls ->
            Enum.map(calls, fn
              %{"target" => "SampleApp.TallyTest.init_with/1"} = call ->
                %{
                  call
                  | "target" => @wrap,
                    "kind" => "double"
                }
                |> Map.put("double", %{
                  "mock" => "SampleApp.FormattingMock",
                  "behaviour" => "SampleApp.Formatting"
                })

              call ->
                call
            end)
          end)

        record ->
          record
      end)

    path = Path.join(System.tmp_dir!(), "grasp-double-#{System.unique_integer([:positive])}.json")
    File.write!(path, Jason.encode!(%{document | "functions" => functions}))
    on_exit(fn -> File.rm(path) end)
    path
  end
end
