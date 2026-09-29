defmodule GraspWeb.IndexReloadTest do
  # The index lives in :persistent_term, so swapping it out would be seen by every other
  # test running at the same time.
  use GraspWeb.ConnCase, async: false

  alias Grasp.{IndexStore, Session}

  @fixture Path.expand("../../fixtures/index.json", __DIR__)
  @shout "SampleApp.Formatter.shout/1"

  setup do
    on_exit(fn -> :ok = IndexStore.load(@fixture) end)
    :ok
  end

  test "a card whose function leaves the index becomes a stub and comes back", %{conn: conn} do
    name = "t-#{System.unique_integer([:positive])}"
    {:ok, view, _html} = live(conn, "/s/#{name}")
    Session.open_root(name, @shout)
    assert has_element?(view, "#card-1[data-function-id='#{@shout}']:not(.stub)")

    :ok = IndexStore.load(without_shout())

    assert has_element?(
             view,
             "#card-1.stub .stub__text",
             "No longer in the index — renamed or removed since it was written."
           )

    refute has_element?(view, "#card-1 .stub__docs")

    :ok = IndexStore.load(@fixture)
    assert has_element?(view, "#card-1[data-function-id='#{@shout}']:not(.stub)")
  end

  test "a module card whose module leaves the index reads as a stale card, not a dependency", %{
    conn: conn
  } do
    name = "t-#{System.unique_integer([:positive])}"
    {:ok, view, _html} = live(conn, "/s/#{name}")
    Session.open_root(name, "SampleApp.Counter")
    assert has_element?(view, "#card-1.card--module[data-function-id='SampleApp.Counter']")

    :ok = IndexStore.load(without_counter_module())

    assert has_element?(
             view,
             "#card-1.stub .stub__text",
             "No longer in the index — renamed or removed since it was written."
           )

    :ok = IndexStore.load(@fixture)
    assert has_element?(view, "#card-1.card--module[data-function-id='SampleApp.Counter']")
  end

  test "an index that gains changes opens the Changes group under a running viewer", %{
    conn: conn
  } do
    :ok = IndexStore.load(unchanged())
    {:ok, view, _html} = live(conn, "/s/t-#{System.unique_integer([:positive])}")
    refute has_element?(view, "#group-changes")

    :ok = IndexStore.load(@fixture)

    assert has_element?(view, "#entries .group[data-kind='changes'] .group__title", "Changes")
    assert has_element?(view, "#group-changes:not([hidden])")
  end

  # A review run without `--base` compares nothing: every function is unchanged and no
  # function the base alone had is carried over.
  defp unchanged do
    write(fn document ->
      Map.update!(document, "functions", fn records ->
        records
        |> Enum.reject(& &1["removed"])
        |> Enum.map(&Map.put(&1, "change", "unchanged"))
      end)
    end)
  end

  defp without_shout do
    write(fn document ->
      Map.update!(document, "functions", fn records ->
        Enum.reject(records, &(&1["id"] == @shout))
      end)
    end)
  end

  defp without_counter_module do
    write(fn document ->
      Map.update!(document, "modules", fn modules ->
        Enum.reject(modules, &(&1["name"] == "SampleApp.Counter"))
      end)
    end)
  end

  defp write(edit) do
    path = Path.join(System.tmp_dir!(), "grasp-reload-#{System.unique_integer([:positive])}.json")
    document = @fixture |> File.read!() |> Jason.decode!() |> edit.()

    File.write!(path, Jason.encode!(document))
    on_exit(fn -> File.rm(path) end)
    path
  end
end
