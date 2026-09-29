defmodule GraspWeb.BareModuleRecordsTest do
  # The index lives in :persistent_term and the sessions directory is application-wide, so
  # swapping either out would be seen by every other test running at the same time.
  use GraspWeb.ConnCase, async: false

  alias Anubis.Server.Frame
  alias Anubis.Server.Response
  alias Grasp.{IndexStore, Session}
  alias Grasp.MCP.Tools
  alias Grasp.Session.{Disk, Forest}

  @moduletag :tmp_dir

  @fixture Path.expand("../../fixtures/index.json", __DIR__)

  # An index document whose module entries carry only the keys below is still a version-1
  # document, and every reader of a module record has to take it.
  @bare_keys ~w(name file line behaviours)

  setup %{conn: conn, tmp_dir: tmp_dir} do
    :ok = IndexStore.load(bare_index(tmp_dir))
    on_exit(fn -> :ok = IndexStore.load(@fixture) end)

    previous = Application.get_env(:grasp, :sessions_dir)
    Application.put_env(:grasp, :sessions_dir, tmp_dir)
    on_exit(fn -> Application.put_env(:grasp, :sessions_dir, previous) end)

    name = "bare-#{System.unique_integer([:positive])}"
    on_exit(fn -> Session.delete(name) end)

    %{conn: conn, name: name}
  end

  test "a module card reads that the module has no moduledoc", %{conn: conn, name: name} do
    {:ok, view, _html} = live(conn, "/s/#{name}")

    render_click(view, "open_module", %{"module" => "SampleApp.Counter"})

    assert has_element?(view, "#card-1.card--module[data-function-id='SampleApp.Counter']")
    assert has_element?(view, "#card-1 .card__header .badge--behaviour", "GenServer")
    assert has_element?(view, "#card-1[data-view='doc'] .card__doc-note", "No @moduledoc")
  end

  test "a backticked module name opens its module card", %{conn: conn, name: name} do
    {:ok, view, _html} = live(conn, "/s/#{name}")

    render_click(view, "open_root", %{"id" => "SampleApp.Greeter"})

    assert has_element?(view, "#card-1.card--module[data-function-id='SampleApp.Greeter']")
    assert has_element?(view, "#card-1 .card__doc-note", "No @moduledoc")
  end

  test "the palette finds a module and opens its card", %{conn: conn, name: name} do
    {:ok, view, _html} = live(conn, "/s/#{name}")

    view |> form("#palette-form", %{q: "SampleApp.Counter"}) |> render_change()

    assert has_element?(view, "#palette-results li:first-child[data-id='SampleApp.Counter']")
    refute has_element?(view, "#palette-results li[data-id='']")

    render_hook(view, "palette_choose", %{"child" => false})

    assert has_element?(view, "#card-1.card--module[data-function-id='SampleApp.Counter']")
  end

  test "a saved session holding a module card mounts with it", %{conn: conn, name: name} do
    {forest, _card} = Forest.open_root(Forest.new(), "SampleApp.Counter")
    :ok = Disk.write(name, forest)

    {:ok, view, _html} = live(conn, "/s/#{name}")

    assert has_element?(view, "#card-1.card--module[data-function-id='SampleApp.Counter']")
    assert has_element?(view, "#card-1 .card__doc-note", "No @moduledoc")
  end

  describe "the MCP tools" do
    test "open_card opens a module card", %{name: name} do
      body = json!(run(Tools.OpenCard, %{session: name, function_id: "SampleApp.Counter"}))

      assert body["card_id"] == 1
      assert Enum.find(body["cards"], &(&1["id"] == 1))["function_id"] == "SampleApp.Counter"
    end

    test "get_module answers the module with no moduledoc" do
      assert json!(run(Tools.GetModule, %{name: "SampleApp.Counter"})) == %{
               "name" => "SampleApp.Counter",
               "file" => "lib/sample_app/counter.ex",
               "line" => 1,
               "behaviours" => ["GenServer"],
               "doc" => nil,
               "hidden" => false,
               "change" => nil,
               "base_doc" => nil
             }
    end
  end

  defp bare_index(dir) do
    document =
      @fixture
      |> File.read!()
      |> Jason.decode!()
      |> Map.update!("modules", &Enum.map(&1, fn module -> Map.take(module, @bare_keys) end))

    path = Path.join(dir, "bare-index.json")
    File.write!(path, Jason.encode!(document))
    path
  end

  defp json!(%Response{content: [%{"type" => "text", "text" => text}]}), do: Jason.decode!(text)

  defp run(tool, params) do
    {:reply, response, _frame} = tool.execute(params, %Frame{})
    response
  end
end
