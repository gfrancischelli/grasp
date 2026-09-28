defmodule Grasp.MCP.ToolsTest do
  use ExUnit.Case, async: true

  alias Anubis.Server.Frame
  alias Anubis.Server.Response
  alias Grasp.MCP.Tools

  @greet "SampleApp.Greeter.greet/2"
  @greet_all "SampleApp.Greeter.greet_all/1"
  @wrap "SampleApp.Formatter.wrap/1"
  @show "SampleAppWeb.GreetController.show/2"
  @shout "SampleApp.Formatter.shout/1"
  @whisper "SampleApp.Formatter.whisper/1"
  @nested "SampleApp.Greeter.Nested.hello/0"

  defp json!(%Response{content: [%{"type" => "text", "text" => text}]}), do: Jason.decode!(text)

  describe "search_functions" do
    test "ranks matches and caps them at the limit" do
      {:reply, resp, _} = Tools.SearchFunctions.execute(%{query: "greet", limit: 2}, %Frame{})

      refute resp.isError

      assert %{"results" => [%{"id" => _, "kind" => _, "file" => _, "line" => _} = first, _]} =
               json!(resp)

      assert first["id"] =~ "greet"
    end

    test "reports the definition's start line and change" do
      {:reply, resp, _} = Tools.SearchFunctions.execute(%{query: @wrap, limit: 20}, %Frame{})

      assert %{"results" => [result | _]} = json!(resp)

      assert result == %{
               "id" => @wrap,
               "kind" => "def",
               "file" => "lib/sample_app/formatter.ex",
               "line" => 4,
               "change" => "unchanged"
             }
    end
  end

  describe "get_function" do
    test "returns the record, callers, callees and entry points" do
      {:reply, resp, _} =
        Tools.GetFunction.execute(%{id: "SampleApp.Greeter.greet/1"}, %Frame{})

      body = json!(resp)
      assert body["id"] == @greet
      assert @wrap in body["callees"]
      assert @show in body["callers"]
      refute Map.has_key?(body, "base_source")

      {:reply, resp, _} = Tools.GetFunction.execute(%{id: @show}, %Frame{})

      assert %{"entry_points" => [%{"kind" => "route", "label" => "GET /greet/:name"}]} =
               json!(resp)
    end
  end

  describe "get_callers and get_callees" do
    test "answer under the canonical id" do
      {:reply, resp, _} = Tools.GetCallers.execute(%{id: "SampleApp.Greeter.greet/1"}, %Frame{})
      assert %{"id" => @greet, "callers" => callers} = json!(resp)
      assert @show in callers
      assert @greet_all in callers

      {:reply, resp, _} = Tools.GetCallees.execute(%{id: @greet}, %Frame{})
      assert %{"id" => @greet, "callees" => callees} = json!(resp)
      assert @wrap in callees
    end
  end

  describe "unknown ids" do
    test "are tool errors" do
      {:reply, %Response{isError: true}, _} =
        Tools.GetFunction.execute(%{id: "Nope.f/0"}, %Frame{})

      {:reply, %Response{isError: true}, _} =
        Tools.GetCallers.execute(%{id: "Nope.f/0"}, %Frame{})

      {:reply, %Response{isError: true}, _} =
        Tools.GetCallees.execute(%{id: "Nope.f/0"}, %Frame{})

      {:reply, %Response{isError: true}, _} =
        Tools.FindPaths.execute(%{to: "Nope.f/0", max_depth: 6, limit: 5}, %Frame{})

      {:reply, %Response{isError: true}, _} =
        Tools.FindPaths.execute(%{to: @wrap, from: "Nope.f/0", max_depth: 6, limit: 5}, %Frame{})
    end
  end

  describe "find_paths" do
    test "annotates each path's entry point" do
      {:reply, resp, _} =
        Tools.FindPaths.execute(%{to: @wrap, max_depth: 6, limit: 10}, %Frame{})

      assert %{"paths" => paths, "truncated" => false} = json!(resp)

      assert %{
               "ids" => [@show, @greet, @wrap],
               "entry" => %{"kind" => "route", "label" => "GET /greet/:name"}
             } in paths
    end

    test "walks callees when given a from" do
      {:reply, resp, _} =
        Tools.FindPaths.execute(%{to: @wrap, from: @show, max_depth: 6, limit: 5}, %Frame{})

      assert %{"paths" => [%{"ids" => [@show, @greet, @wrap]} | _]} = json!(resp)
    end
  end

  describe "list_entry_points" do
    test "filters by kind and query" do
      {:reply, resp, _} =
        Tools.ListEntryPoints.execute(
          %{kind: "route", query: "greet/:name", limit: 100},
          %Frame{}
        )

      assert %{"total" => 1, "entry_points" => [%{"target" => @show}]} = json!(resp)
    end

    test "matches the target as well as the label, case-insensitively" do
      {:reply, resp, _} =
        Tools.ListEntryPoints.execute(%{query: "hellolive", limit: 100}, %Frame{})

      %{"total" => total, "entry_points" => entry_points} = json!(resp)
      assert total == length(entry_points)
      assert total > 0
      assert Enum.all?(entry_points, &(&1["target"] =~ "HelloLive"))
    end

    test "lists every entry point when unfiltered" do
      {:reply, resp, _} = Tools.ListEntryPoints.execute(%{limit: 100}, %Frame{})
      assert %{"total" => total} = json!(resp)
      assert total > 5
    end
  end

  describe "list_modules and list_sessions" do
    test "list modules matching a query" do
      {:reply, resp, _} = Tools.ListModules.execute(%{query: "greeter", limit: 200}, %Frame{})

      assert %{"total" => 2, "modules" => [%{"name" => "SampleApp.Greeter"} | _]} = json!(resp)
    end

    test "list modules carries file and behaviours" do
      {:reply, resp, _} = Tools.ListModules.execute(%{query: "counter", limit: 200}, %Frame{})

      assert %{
               "modules" => [
                 %{
                   "name" => "SampleApp.Counter",
                   "file" => "lib/sample_app/counter.ex",
                   "behaviours" => ["GenServer"]
                 }
               ]
             } = json!(resp)
    end

    test "list the running sessions" do
      name = "t-#{System.unique_integer([:positive])}"
      :ok = Grasp.Session.ensure(name)

      {:reply, resp, _} = Tools.ListSessions.execute(%{}, %Frame{})
      assert name in json!(resp)["sessions"]
    end
  end

  describe "list_changes" do
    test "lists what the branch did, sorted by id, with the ref it was compared against" do
      {:reply, resp, _} = Tools.ListChanges.execute(%{}, %Frame{})

      refute resp.isError
      body = json!(resp)

      assert body["total"] == 3
      assert body["base_ref"] == "main"
      assert Enum.map(body["changes"], & &1["id"]) == [@shout, @whisper, @nested]

      assert hd(body["changes"]) == %{
               "id" => @shout,
               "change" => "modified",
               "file" => "lib/sample_app/formatter.ex",
               "line" => 8,
               "module" => "SampleApp.Formatter"
             }

      assert Enum.map(body["changes"], & &1["change"]) == ~w(modified removed added)
    end
  end

  describe "tests_for" do
    test "lists the tests reaching a function, nearest first, with their names and files" do
      {:reply, resp, _} =
        Tools.TestsFor.execute(%{function_id: "SampleApp.Counter.handle_call/3"}, %Frame{})

      refute resp.isError

      assert json!(resp) == %{
               "id" => "SampleApp.Counter.handle_call/3",
               "tests" => [
                 %{
                   "id" =>
                     ~s|SampleApp.TallyTest."test handle_call/3 replies with the next number"/1|,
                   "name" => "replies with the next number",
                   "describe" => "handle_call/3",
                   "file" => "test/sample_app/tally_test.exs",
                   "hops" => 1
                 }
               ]
             }
    end

    test "counts hops up to max_hops, four by default" do
      {:reply, resp, _} =
        Tools.TestsFor.execute(%{function_id: "SampleApp.Counter.init/1"}, %Frame{})

      assert %{"tests" => [%{"hops" => 2, "describe" => nil} = test]} = json!(resp)
      assert test["name"] == "init keeps the start count"

      {:reply, resp, _} =
        Tools.TestsFor.execute(%{function_id: "SampleApp.Counter.init/1", max_hops: 1}, %Frame{})

      assert json!(resp)["tests"] == []
    end

    test "answers under the canonical id, and an unknown id is a tool error" do
      {:reply, resp, _} =
        Tools.TestsFor.execute(%{function_id: "SampleApp.Greeter.greet/1"}, %Frame{})

      assert json!(resp)["id"] == @greet

      {:reply, %Response{isError: true} = resp, _} =
        Tools.TestsFor.execute(%{function_id: "Nope.f/0"}, %Frame{})

      assert [%{"text" => "unknown function: Nope.f/0"}] = resp.content
    end
  end

  describe "untested_changes" do
    test "lists the changed application functions no test reaches, sorted by id" do
      {:reply, resp, _} = Tools.UntestedChanges.execute(%{}, %Frame{})

      refute resp.isError

      assert json!(resp) == %{
               "functions" => [
                 %{"id" => @nested, "file" => "lib/sample_app/greeter.ex", "change" => "added"}
               ]
             }

      {:reply, resp, _} = Tools.TestsFor.execute(%{function_id: @shout}, %Frame{})
      assert [_ | _] = json!(resp)["tests"]
    end
  end

  describe "coverage" do
    test "an unknown id is a tool error" do
      {:reply, %Response{isError: true} = resp, _} =
        Tools.Coverage.execute(%{function_id: "Nope.f/0"}, %Frame{})

      assert [%{"text" => "unknown function: Nope.f/0"}] = resp.content
    end

    test "says how to write coverage when there is none" do
      assert Tools.Coverage.__description__() =~ "mix grasp.cover"
    end
  end

  describe "the card lookup" do
    test "answers the card, or the message a tool replies with when there is none" do
      name = "t-#{System.unique_integer([:positive])}"

      assert {:error, "unknown card: 1"} = Tools.fetch_card(name, 1)

      Grasp.Session.open_root(name, @wrap)

      assert {:ok, %{id: 1, function_id: @wrap}} = Tools.fetch_card(name, 1)
    end
  end

  describe "the loaded index" do
    test "answers the store's value" do
      assert {:ok, index} = Tools.index(Grasp.IndexStore.get())
      assert %Grasp.Index{} = index
    end

    test "is the error every index-reading tool replies when none is loaded" do
      assert {:error, %Response{isError: true} = response} = Tools.index(nil)
      assert [%{"type" => "text", "text" => "no index loaded"}] = response.content
    end
  end

  describe "input schemas" do
    test "are what clients see" do
      assert "query" in Tools.SearchFunctions.input_schema()["required"]
      assert "id" in Tools.GetFunction.input_schema()["required"]
      assert "to" in Tools.FindPaths.input_schema()["required"]
      refute "from" in (Tools.FindPaths.input_schema()["required"] || [])
      refute Tools.ListEntryPoints.input_schema()["required"]
      refute Tools.ListChanges.input_schema()["required"]
      assert Tools.TestsFor.input_schema()["required"] == ["function_id"]
      refute Tools.UntestedChanges.input_schema()["required"]
      assert Tools.Coverage.input_schema()["required"] == ["function_id"]
    end

    test "state each bounded field's default and maximum" do
      properties = Tools.SearchFunctions.input_schema()["properties"]

      assert properties["limit"]["description"] ==
               "How many results to return; default 20, maximum 100"

      assert properties["limit"]["maximum"] == 100

      properties = Tools.TestsFor.input_schema()["properties"]

      assert properties["max_hops"]["description"] ==
               "How many call edges a test may be away; default 4, maximum 8"

      assert properties["max_hops"]["minimum"] == 1
      assert properties["max_hops"]["maximum"] == 8
      assert properties["function_id"]["description"] =~ "a test's id quotes its name"
    end
  end
end
