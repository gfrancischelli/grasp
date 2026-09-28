defmodule Grasp.MCP.DoublesToolTest do
  # The index lives in :persistent_term, so swapping it out would be seen by every other
  # test running at the same time.
  use ExUnit.Case, async: false

  alias Anubis.Server.Frame
  alias Anubis.Server.Response
  alias Grasp.{IndexStore, TracedDoubles}
  alias Grasp.MCP.Tools

  @fixture Path.expand("../../fixtures/index.json", __DIR__)

  setup do
    document = @fixture |> File.read!() |> Jason.decode!()

    document = %{
      document
      | "functions" => document["functions"] ++ TracedDoubles.records_json(),
        "modules" => document["modules"] ++ TracedDoubles.modules()
    }

    path =
      Path.join(System.tmp_dir!(), "grasp-doubles-#{System.unique_integer([:positive])}.json")

    File.write!(path, Jason.encode!(document))

    :ok = IndexStore.load(path)

    on_exit(fn ->
      :ok = IndexStore.load(@fixture)
      File.rm(path)
    end)
  end

  defp json!(%Response{content: [%{"type" => "text", "text" => text}]}), do: Jason.decode!(text)

  test "get_callees answers a test's doubles apart from its calls" do
    {:reply, resp, _} = Tools.GetCallees.execute(%{id: TracedDoubles.test_id()}, %Frame{})

    assert %{"callees" => callees, "doubles" => doubles} = json!(resp)

    refute "SampleApp.Geo.Ip.lookup/1" in callees
    refute "SampleApp.Geo.Static.lookup/1" in callees

    assert doubles == [
             %{
               "target" => "SampleApp.Geo.Ip.lookup/1",
               "behaviour" => "SampleApp.Geo",
               "mock" => "SampleApp.GeoMock"
             },
             %{
               "target" => "SampleApp.Geo.Static.lookup/1",
               "behaviour" => "SampleApp.Geo",
               "mock" => "SampleApp.GeoMock"
             }
           ]
  end

  test "get_callees answers no doubles for a function that has none" do
    {:reply, resp, _} = Tools.GetCallees.execute(%{id: "SampleApp.Greeter.greet/2"}, %Frame{})

    assert %{"callees" => callees, "doubles" => []} = json!(resp)
    assert "SampleApp.Formatter.wrap/1" in callees
  end

  test "get_callees says a double is not a call" do
    assert Tools.GetCallees.__description__() |> String.replace(~r/\s+/, " ") =~
             "a double stands in for the code it names rather than running it, so it is not a call"
  end
end
