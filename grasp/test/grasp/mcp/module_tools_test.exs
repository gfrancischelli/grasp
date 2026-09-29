defmodule Grasp.MCP.ModuleToolsTest do
  # The index lives in :persistent_term, so swapping it out would be seen by every other
  # test running at the same time.
  use ExUnit.Case, async: false

  alias Anubis.Server.Frame
  alias Anubis.Server.Response
  alias Grasp.IndexStore
  alias Grasp.MCP.Tools

  @fixture Path.expand("../../fixtures/index.json", __DIR__)
  @shout "SampleApp.Formatter.shout/1"

  setup do
    :ok = IndexStore.load(with_changed_moduledocs())
    on_exit(fn -> :ok = IndexStore.load(@fixture) end)
    %{session: "mcp-mod-#{System.unique_integer([:positive])}"}
  end

  defp json!(%Response{content: [%{"type" => "text", "text" => text}]}), do: Jason.decode!(text)

  defp run(tool, params) do
    {:reply, response, _frame} = tool.execute(params, %Frame{})
    response
  end

  defp card(body, id), do: Enum.find(body["cards"], &(&1["id"] == id))

  describe "get_module" do
    test "answers a module's moduledoc and its change against the base" do
      body = json!(run(Tools.GetModule, %{name: "SampleApp.Formatter"}))

      assert body == %{
               "name" => "SampleApp.Formatter",
               "file" => "lib/sample_app/formatter.ex",
               "line" => 1,
               "behaviours" => [],
               "doc" => "String decorations used by the greeter.",
               "hidden" => false,
               "change" => "modified",
               "base_doc" => "Decorations."
             }
    end

    test "answers null for a module without a moduledoc or a change" do
      body = json!(run(Tools.GetModule, %{name: "SampleApp.TallyTest"}))

      assert %{"doc" => nil, "hidden" => false, "change" => nil, "base_doc" => nil} = body
    end

    test "answers the base text of a moduledoc the branch removed" do
      body = json!(run(Tools.GetModule, %{name: "SampleApp.Workers.Mailer"}))

      assert %{"doc" => nil, "change" => "removed", "base_doc" => "An Oban worker."} = body
      assert body["behaviours"] == ["Oban.Worker"]
    end

    test "answers whether a moduledoc is hidden" do
      assert %{"doc" => nil, "hidden" => true, "change" => nil} =
               json!(run(Tools.GetModule, %{name: "SampleAppWeb.Endpoint"}))
    end

    test "an unknown module is an error" do
      response = run(Tools.GetModule, %{name: "SampleApp.Nope"})

      assert response.isError
      assert [%{"text" => "unknown module: SampleApp.Nope"}] = response.content
    end
  end

  describe "list_changes" do
    test "lists the changed moduledocs, sorted by module" do
      body = json!(run(Tools.ListChanges, %{}))

      assert body["moduledocs"] == [
               %{"module" => "SampleApp.Formatter", "change" => "modified"},
               %{"module" => "SampleApp.Workers.Mailer", "change" => "removed"},
               %{"module" => "SampleAppWeb.RequestId", "change" => "added"}
             ]

      assert body["total"] == 3
    end
  end

  describe "open_card" do
    test "a module name opens its module card", %{session: session} do
      body = json!(run(Tools.OpenCard, %{session: session, function_id: "SampleApp.Formatter"}))

      assert body["card_id"] == 1
      assert card(body, 1)["function_id"] == "SampleApp.Formatter"
    end

    test "a module card takes no parent card", %{session: session} do
      run(Tools.OpenCard, %{session: session, function_id: @shout})

      response =
        run(Tools.OpenCard, %{
          session: session,
          function_id: "SampleApp.Formatter",
          parent_card_id: 1
        })

      assert response.isError
      assert [%{"text" => text}] = response.content
      assert text =~ "SampleApp.Formatter is a module"
    end

    test "a module card has no calls to highlight, but its lines can be shaded", %{
      session: session
    } do
      response =
        run(Tools.OpenCard, %{
          session: session,
          function_id: "SampleApp.Formatter",
          highlight: %{call: @shout}
        })

      assert response.isError
      assert [%{"text" => "SampleApp.Formatter does not call " <> @shout}] = response.content

      body =
        json!(
          run(Tools.OpenCard, %{
            session: session,
            function_id: "SampleApp.Formatter",
            highlight: %{lines: [2, 2]}
          })
        )

      assert card(body, 1)["highlight"] == %{"lines" => [2, 2]}
    end

    test "an id naming neither a function nor a module names both forms", %{session: session} do
      response =
        run(Tools.OpenCard, %{session: session, function_id: "SampleApp.Formatter.shout"})

      assert response.isError
      assert [%{"text" => text}] = response.content
      assert text =~ "unknown function or module: SampleApp.Formatter.shout"
      assert text =~ "a function id ends in /arity"
    end
  end

  describe "set_cards" do
    test "lays out module cards beside function cards", %{session: session} do
      body =
        json!(
          run(Tools.SetCards, %{
            session: session,
            cards: [
              %{key: "m", function_id: "SampleApp.Formatter"},
              %{key: "f", function_id: @shout}
            ]
          })
        )

      assert Enum.map(body["cards"], & &1["function_id"]) == ["SampleApp.Formatter", @shout]
    end

    test "names every unknown module and function at once", %{session: session} do
      response =
        run(Tools.SetCards, %{
          session: session,
          cards: [
            %{key: "a", function_id: "SampleApp.Nope"},
            %{key: "b", function_id: "Nope.f/0"}
          ]
        })

      assert response.isError
      assert [%{"text" => text}] = response.content
      assert text =~ "unknown functions: Nope.f/0"
      assert text =~ "unknown functions or modules: SampleApp.Nope"
      assert text =~ "a function id ends in /arity"
    end

    test "no card hangs under a module card, and a module card hangs under none", %{
      session: session
    } do
      under_module =
        run(Tools.SetCards, %{
          session: session,
          cards: [
            %{key: "m", function_id: "SampleApp.Formatter"},
            %{key: "f", function_id: @shout, parent_key: "m"}
          ]
        })

      assert under_module.isError
      assert [%{"text" => text}] = under_module.content
      assert text =~ "SampleApp.Formatter is a module"

      module_under =
        run(Tools.SetCards, %{
          session: session,
          cards: [
            %{key: "f", function_id: @shout},
            %{key: "m", function_id: "SampleApp.Formatter", parent_key: "f"}
          ]
        })

      assert module_under.isError
      assert [%{"text" => text}] = module_under.content
      assert text =~ "SampleApp.Formatter is a module"
    end
  end

  describe "set_view" do
    test "a module card takes the views it offers", %{session: session} do
      run(Tools.OpenCard, %{session: session, function_id: "SampleApp.Formatter"})

      for view <- ~w(doc source diff) do
        body = json!(run(Tools.SetView, %{session: session, card_id: 1, view: view}))
        assert card(body, 1)["view"] == view
      end
    end

    test "a module card refuses a view it does not offer", %{session: session} do
      run(Tools.OpenCard, %{session: session, function_id: "SampleAppWeb.RequestId"})

      response = run(Tools.SetView, %{session: session, card_id: 1, view: "diff"})

      assert response.isError
      assert [%{"text" => "no diff for SampleAppWeb.RequestId"}] = response.content
    end

    test "a function card has no doc view", %{session: session} do
      run(Tools.OpenCard, %{session: session, function_id: @shout})

      response = run(Tools.SetView, %{session: session, card_id: 1, view: "doc"})

      assert response.isError
      assert [%{"text" => "no doc view for " <> @shout}] = response.content
    end
  end

  describe "comments on a module card" do
    test "are added and listed over MCP", %{session: session} do
      added =
        json!(
          run(Tools.AddComment, %{
            session: session,
            function_id: "SampleApp.Formatter",
            line: 2,
            body: "Say what the decorations are for."
          })
        )

      assert %{"function_id" => "SampleApp.Formatter", "status" => "anchored"} = added
      assert added["file"] == "lib/sample_app/formatter.ex"

      body =
        json!(run(Tools.ListComments, %{session: session, function_id: "SampleApp.Formatter"}))

      assert [%{"id" => id, "anchored_line" => 2}] = body["comments"]
      assert id == added["id"]
    end

    test "are refused on a line outside the moduledoc", %{session: session} do
      response =
        run(Tools.AddComment, %{
          session: session,
          function_id: "SampleApp.Formatter",
          line: 9,
          body: "Off the doc."
        })

      assert response.isError

      assert [%{"text" => "line 9 is outside SampleApp.Formatter (lines 2..2)"}] =
               response.content
    end

    test "are refused on the branch side of a module without moduledoc lines", %{
      session: session
    } do
      response =
        run(Tools.AddComment, %{
          session: session,
          function_id: "SampleApp.TallyTest",
          line: 1,
          body: "No doc."
        })

      assert response.isError
      assert [%{"text" => text}] = response.content
      assert text =~ "SampleApp.TallyTest has no moduledoc lines"
    end

    test "land on the base side of a removed moduledoc", %{session: session} do
      added =
        json!(
          run(Tools.AddComment, %{
            session: session,
            function_id: "SampleApp.Workers.Mailer",
            line: 1,
            side: "old",
            body: "Why drop it?"
          })
        )

      assert %{"side" => "old", "status" => "anchored", "snippet" => snippet} = added
      assert snippet == ~s(@moduledoc "An Oban worker.")
    end
  end

  describe "an id without an arity that names no module" do
    test "is answered with both forms by the comment tools", %{session: session} do
      response =
        run(Tools.AddComment, %{
          session: session,
          function_id: "SampleApp.Formatter.shout",
          line: 8,
          body: "Missing arity."
        })

      assert response.isError
      assert [%{"text" => text}] = response.content
      assert text =~ "unknown function or module: SampleApp.Formatter.shout"
      assert text =~ "a function id ends in /arity"
    end
  end

  describe "function-only tools" do
    test "answer a module name with an error saying it is a module" do
      for tool <- [Tools.GetFunction, Tools.GetCallers, Tools.GetCallees] do
        response = run(tool, %{id: "SampleApp.Formatter"})

        assert response.isError
        assert [%{"text" => text}] = response.content
        assert text =~ "SampleApp.Formatter is a module"
        assert text =~ "get_module"
      end
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

        %{"name" => "SampleAppWeb.RequestId"} = module ->
          Map.put(module, "change", "added")

        %{"name" => "SampleAppWeb.Endpoint"} = module ->
          Map.merge(module, %{
            "doc" => %{"text" => nil, "hidden" => true},
            "source" => "  @moduledoc false"
          })

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

    path =
      Path.join(
        System.tmp_dir!(),
        "grasp-module-tools-#{System.unique_integer([:positive])}.json"
      )

    File.write!(path, Jason.encode!(%{document | "modules" => modules}))
    on_exit(fn -> File.rm(path) end)
    path
  end
end
