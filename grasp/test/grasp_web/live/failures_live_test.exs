defmodule GraspWeb.FailuresLiveTest do
  # The results document lives in :persistent_term and is the whole viewer's, so these tests
  # share it and run alone.
  use GraspWeb.ConnCase, async: false

  alias Grasp.{IndexStore, ResultsStore, Session, TestResults}

  @init ~s|SampleApp.TallyTest."test init keeps the start count"/1|
  @init_with "SampleApp.TallyTest.init_with/1"
  @counter_init "SampleApp.Counter.init/1"
  @greet "SampleApp.Greeter.greet/2"

  @own %{
    "module" => "SampleApp.TallyTest",
    "function" => "test init keeps the start count",
    "arity" => 1,
    "file" => "test/sample_app/tally_test.exs",
    "line" => 18
  }
  @runner %{
    "module" => "ExUnit.Runner",
    "function" => "exec_test",
    "arity" => 1,
    "file" => "lib/ex_unit/runner.ex",
    "line" => 512
  }
  @dependency %{
    "module" => "GenServer",
    "function" => "call",
    "arity" => 3,
    "file" => "lib/gen_server.ex",
    "line" => 1142
  }
  @helper %{
    "module" => "SampleApp.TallyTest",
    "function" => "init_with",
    "arity" => 1,
    "file" => "test/sample_app/tally_test.exs",
    "line" => 21
  }
  @deepest %{
    "module" => "SampleApp.Counter",
    "function" => "init",
    "arity" => 1,
    "file" => "lib/sample_app/counter.ex",
    "line" => 8
  }

  setup %{conn: conn} do
    results = ResultsStore.path()

    on_exit(fn ->
      File.rm(results)
      :ok = ResultsStore.reload()
    end)

    name = "t-#{System.unique_integer([:positive])}"
    {:ok, view, _html} = live(conn, "/s/#{name}")
    %{view: view, name: name, results: results}
  end

  describe "the failure panel" do
    test "sits under the line the test's own frame names, its values escaped", %{
      view: view,
      name: name,
      results: results
    } do
      record_failure(results, [
        error([@deepest, @dependency, @helper, @own, @runner],
          message: "<b>Assertion</b> with == failed & more",
          left: ~s|{:ok, "<script>alert(1)</script>"}|,
          right: "{:ok, 7}"
        )
      ])

      Session.open_root(name, @init)

      assert has_element?(view, "#card-1 .line[data-line='18'] + .failure[data-line='18']")
      assert has_element?(view, "#card-1 .failure__message", "<b>Assertion</b> with == failed")
      assert has_element?(view, "#card-1 .failure__expr", "assert init_with(7) == {:ok, 7}")
      assert has_element?(view, "#card-1 .failure__value[data-side='left'] pre", "<script>")
      assert has_element?(view, "#card-1 .failure__value[data-side='right'] pre", "{:ok, 7}")

      html = render(view)
      refute html =~ "<b>Assertion</b>"
      refute html =~ "<script>alert(1)</script>"
      assert html =~ "&lt;b&gt;Assertion&lt;/b&gt;"

      assert has_element?(
               view,
               "#card-1 .failure__frame[data-indexed='false']",
               "GenServer.call/3"
             )

      assert has_element?(
               view,
               "#card-1 .failure__frame[data-indexed='false']",
               "outside the index"
             )

      assert has_element?(view, "#card-1 .failure__frame[data-own='true']", "tally_test.exs:18")
      assert has_element?(view, "#card-1 .card__header #open-failure-1", "open failure")
    end

    test "sits under the test's first line when no frame is the test's own", %{
      view: view,
      name: name,
      results: results
    } do
      record_failure(results, [error([@deepest, @runner], message: "boom")])
      Session.open_root(name, @init)

      assert has_element?(view, "#card-1 .line[data-line='17'] + .failure", "boom")
    end

    test "is drawn for each error, and never stored as a comment", %{
      view: view,
      name: name,
      results: results
    } do
      record_failure(results, [
        error([@own], message: "first"),
        error([@own], message: "second")
      ])

      Session.open_root(name, @init)

      assert has_element?(view, "#card-1 .failure", "first")
      assert has_element?(view, "#card-1 .failure", "second")
      refute has_element?(view, "#card-1 .thread")
      assert Grasp.Comments.list(session: name, include_resolved: true) == []
    end

    test "goes, with open failure, when the result is stale", %{
      view: view,
      name: name,
      results: results
    } do
      record_failure(results, [error([@own], message: "boom")], source_hash: "0")
      Session.open_root(name, @init)

      assert has_element?(view, "#card-1 .badge--result[data-result='stale']")
      refute has_element?(view, "#card-1 .failure")
      refute has_element?(view, "#open-failure-1")
    end
  end

  describe "open failure" do
    test "opens the indexed frames as a chain of callees, deepest focused", %{
      view: view,
      name: name,
      results: results
    } do
      record_failure(results, [
        error([@deepest, @dependency, @helper, @own, @runner], message: "boom"),
        error([greet_frame()], message: "the second error opens nothing")
      ])

      Session.open_root(name, @init)
      view |> element("#open-failure-1") |> render_click()

      forest = Session.get(name)
      helper = Grasp.Session.Forest.find(forest, @init_with)
      deepest = Grasp.Session.Forest.find(forest, @counter_init)

      assert map_size(forest.cards) == 3
      assert Grasp.Session.Forest.find(forest, @greet) == nil
      assert forest.focus == deepest

      assert Enum.map(forest.edges, &{&1.from, &1.to, &1.target}) == [
               {1, helper, @init_with},
               {helper, deepest, @counter_init}
             ]

      assert Grasp.Session.Forest.card(forest, helper).highlight == %{"lines" => [21, 21]}
      assert Grasp.Session.Forest.card(forest, deepest).highlight == %{"lines" => [8, 8]}

      assert has_element?(view, "#card-#{helper} .line[data-line='21'][data-highlight='true']")
      assert has_element?(view, "#card-#{deepest} .line[data-line='8'][data-highlight='true']")
      assert has_element?(view, "#card-#{deepest}[data-focused='true']")
    end

    test "reuses a card already on the canvas and unfolds it", %{
      view: view,
      name: name,
      results: results
    } do
      record_failure(results, [error([@deepest, @helper, @own], message: "boom")])

      Session.open_root(name, @init)
      Session.open_root(name, @init_with)
      Session.toggle_collapse(name, 2)
      view |> element("#open-failure-1") |> render_click()

      forest = Session.get(name)
      assert map_size(forest.cards) == 3
      assert Grasp.Session.Forest.find(forest, @init_with) == 2
      refute Grasp.Session.Forest.card(forest, 2).collapsed
      assert forest.focus == Grasp.Session.Forest.find(forest, @counter_init)
    end

    test "a step its caller does not call says it passes outside the index", %{
      view: view,
      name: name,
      results: results
    } do
      record_failure(results, [error([greet_frame(), @dependency, @own], message: "boom")])

      Session.open_root(name, @init)

      assert has_element?(
               view,
               "#card-1 .failure__frame[data-step='true']",
               "reached through code outside the index"
             )

      view |> element("#open-failure-1") |> render_click()

      forest = Session.get(name)
      greet = Grasp.Session.Forest.find(forest, @greet)
      assert Enum.map(forest.edges, &{&1.from, &1.to, &1.target}) == [{1, greet, @greet}]
      assert forest.focus == greet
    end

    test "a failure with no indexed frame above the test's opens nothing", %{
      view: view,
      name: name,
      results: results
    } do
      record_failure(results, [error([@dependency, @own, @runner], message: "boom")])

      Session.open_root(name, @init)
      before = Session.get(name)
      view |> element("#open-failure-1") |> render_click()

      assert Session.get(name) == before
    end
  end

  defp record_failure(results, errors, opts \\ []) do
    document =
      TestResults.merge(
        nil,
        %{@init => %{"status" => "failed", "time" => 10, "errors" => errors}},
        %{run_id: "r1", finished_at: "2026-09-28T12:00:00Z", index: IndexStore.get()}
      )

    document =
      case Keyword.fetch(opts, :source_hash) do
        {:ok, hash} -> put_in(document, ["tests", @init, "source_hash"], hash)
        :error -> document
      end

    :ok = TestResults.write(document, results)
    :ok = ResultsStore.reload()
  end

  defp error(stacktrace, opts) do
    %{
      "kind" => "error",
      "message" => Keyword.fetch!(opts, :message),
      "expr" => "assert init_with(7) == {:ok, 7}",
      "stacktrace" => stacktrace
    }
    |> put_present("left", opts[:left])
    |> put_present("right", opts[:right])
  end

  defp put_present(map, _key, nil), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)

  defp greet_frame do
    %{
      "module" => "SampleApp.Greeter",
      "function" => "greet",
      "arity" => 2,
      "file" => "lib/sample_app/greeter.ex",
      "line" => 7
    }
  end
end
