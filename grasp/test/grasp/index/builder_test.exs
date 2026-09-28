defmodule Grasp.Index.BuilderTest do
  use ExUnit.Case, async: false

  @moduletag :integration

  @fixture Path.expand("../../fixtures/sample_app", __DIR__)
  @grasp_build "_build/grasp"
  @next_number ~S(SampleApp.TallyTest."test handle_call/3 replies with the next number"/1)
  @untouched [
    "_build/dev/lib/sample_app/ebin/Elixir.SampleApp.Greeter.beam",
    "_build/dev/lib/sample_app/.mix/compile.elixir"
  ]

  setup_all do
    out = Path.join(System.tmp_dir!(), "grasp-sample-#{System.unique_integer([:positive])}.json")
    env = [{"MIX_ENV", "dev"}]

    unless Enum.all?(locked_deps(), &File.dir?(Path.join([@fixture, "deps", &1]))) do
      {fetched, status} =
        System.cmd("mix", ["deps.get"], cd: @fixture, env: env, stderr_to_stdout: true)

      assert status == 0, fetched
    end

    # The project's own build has to be there for the task to seed from it, and its beams
    # are what the run must leave alone.
    {compiled, status} =
      System.cmd("mix", ["compile"], cd: @fixture, env: env, stderr_to_stdout: true)

    assert status == 0, compiled
    File.rm_rf!(Path.join(@fixture, @grasp_build))
    untouched = Map.new(@untouched, &{&1, stat(&1)})

    {output, status} =
      System.cmd("mix", ["grasp.index", "--out", out],
        cd: @fixture,
        env: env,
        stderr_to_stdout: true
      )

    assert status == 0, output
    {:ok, index} = Grasp.Index.load(out)
    %{index: index, output: output, untouched: untouched}
  end

  test "compiles in a build directory of its own, seeded from the project's",
       %{output: output, untouched: untouched} do
    assert output =~ "Grasp: seeding #{@grasp_build} from _build/dev"

    assert File.regular?(
             Path.join([
               @fixture,
               @grasp_build,
               "lib/sample_app/ebin/Elixir.SampleApp.Greeter.beam"
             ])
           )

    assert Map.new(@untouched, &{&1, stat(&1)}) == untouched
  end

  test "reports what it wrote", %{output: output} do
    assert output =~
             ~r/Grasp index written to .*grasp-sample-\d+\.json \(\d+ functions, \d+ calls, \d+ hidden, 4 tests\)/
  end

  describe "the project's tests" do
    test "are records of their own kind, carrying ExUnit's names", %{index: index} do
      {:ok, test} = Grasp.Index.fetch_function(index, @next_number)

      assert test["kind"] == "test"
      assert test["file"] == "test/sample_app/tally_test.exs"
      assert test["arity"] == 1

      assert test["test"] == %{
               "describe" => "handle_call/3",
               "name" => "replies with the next number",
               "tags" => ["tally"]
             }

      assert %{"kind" => "remote"} = call(test, "SampleApp.Counter.handle_call/3")

      assert @next_number in Grasp.Index.callers(index, "SampleApp.Counter.handle_call/3")
    end

    test "keep their setups, helpers and the support files' functions", %{index: index} do
      {:ok, setup} = Grasp.Index.fetch_function(index, "SampleApp.TallyTest.__ex_unit_setup_0/1")
      assert setup["kind"] == "setup"
      refute Map.has_key?(setup, "test")

      {:ok, helper} = Grasp.Index.fetch_function(index, "SampleApp.TallyTest.init_with/1")
      assert helper["kind"] == "defp"
      assert call(helper, "SampleApp.Counter.init/1")

      {:ok, conn_for} = Grasp.Index.fetch_function(index, "SampleApp.SampleCase.conn_for/1")
      assert conn_for["file"] == "test/support/sample_case.ex"
      assert call(conn_for, "Phoenix.ConnTest.build_conn/0")

      {:ok, case_setup} =
        Grasp.Index.fetch_function(index, "SampleApp.SampleCase.__ex_unit_setup_0/1")

      assert call(case_setup, "SampleApp.SampleCase.conn_for/1")

      {:ok, request} =
        Grasp.Index.fetch_function(
          index,
          ~S(SampleAppWeb.RoutesTest."test a plain path reaches the controller"/1)
        )

      assert call(request, "Phoenix.ConnTest.get/2")
    end

    test "never read the test helper", %{index: index} do
      refute Enum.any?(Grasp.Index.modules(index), &(&1["file"] == "test/test_helper.exs"))
    end

    test "are named in the project block", %{index: index} do
      assert index.project["test_paths"] == ["test"]
    end

    test "are traced in a build directory of their own" do
      assert File.dir?(Path.join([@fixture, "_build/grasp_test/lib/sample_app/ebin"]))
    end

    test "are left out with --no-tests" do
      {output, index} = index!(["--no-tests"])

      refute output =~ "tracing tests"
      refute output =~ "tests)"
      refute Map.has_key?(index.project, "test_paths")

      refute Enum.any?(index.functions, fn {_id, record} ->
               record["kind"] in ["test", "setup"]
             end)

      assert {:ok, _greet} = Grasp.Index.fetch_function(index, "SampleApp.Greeter.greet/2")
    end

    test "that do not compile are reported and leave the application's records" do
      broken = Path.join(@fixture, "test/sample_app/broken_test.exs")

      File.write!(
        broken,
        "defmodule SampleApp.BrokenTest do\n  use ExUnit.Case\n  test \"x\", do: nope()\nend\n"
      )

      try do
        {output, index} = index!([])

        assert output =~ "grasp: tests not indexed:"
        assert output =~ "test/sample_app/broken_test.exs"
        refute Map.has_key?(index.project, "test_paths")
        refute Enum.any?(index.functions, fn {_id, record} -> record["kind"] == "test" end)
        assert {:ok, _greet} = Grasp.Index.fetch_function(index, "SampleApp.Greeter.greet/2")
      after
        File.rm!(broken)
      end
    end
  end

  test "records project metadata", %{index: index} do
    assert index.project["app"] == "sample_app"
    assert index.project["elixirc_paths"] == ["lib"]
    assert index.project["root"] == @fixture
    assert is_binary(index.generated_at)
    assert index.git["base_ref"] == nil
    assert index.git["base_sha"] == nil
  end

  test "indexes definitions with spans, sources and default arities", %{index: index} do
    {:ok, greet} = Grasp.Index.fetch_function(index, "SampleApp.Greeter.greet/2")

    assert greet["arities"] == [1, 2]
    assert greet["kind"] == "def"
    assert greet["file"] == "lib/sample_app/greeter.ex"
    assert greet["span"] == %{"start_line" => 6, "end_line" => 11}
    assert String.starts_with?(greet["source"], "  @doc \"Greets someone")
    assert greet["change"] == "unchanged"
    assert greet["removed"] == false
  end

  test "a decorated function spans from its doc", %{index: index} do
    {:ok, trail} = Grasp.Index.fetch_function(index, "SampleApp.Audited.leave_trail/1")

    assert trail["span"] == %{"start_line" => 5, "end_line" => 8}
    assert String.starts_with?(trail["source"], "  @doc")
    assert call(trail, "SampleApp.Greeter.greet/1")
  end

  test "resolves aliased, imported, local, captured and nested calls with ranges", %{index: index} do
    {:ok, greet} = Grasp.Index.fetch_function(index, "SampleApp.Greeter.greet/2")

    assert %{"kind" => "remote", "range" => %{"start" => [9, 12], "end" => [9, 26]}} =
             call(greet, "SampleApp.Formatter.wrap/1")

    assert %{"kind" => "imported", "range" => %{"start" => [10, 19], "end" => [10, 24]}} =
             call(greet, "SampleApp.Formatter.shout/1")

    {:ok, greet_all} = Grasp.Index.fetch_function(index, "SampleApp.Greeter.greet_all/1")
    assert %{"kind" => "remote"} = call(greet_all, "Enum.map/2")

    assert %{"kind" => "local", "range" => %{"start" => [15, 46], "end" => [15, 51]}} =
             call(greet_all, "SampleApp.Greeter.greet/1")

    assert Grasp.Index.callers(index, "SampleApp.Greeter.greet/2") == [
             "SampleApp.Audited.leave_trail/1",
             "SampleApp.Greeter.Nested.hello/0",
             "SampleApp.Greeter.greet_all/1",
             "SampleApp.Workers.Mailer.perform/1",
             "SampleAppWeb.GreetController.create/2",
             "SampleAppWeb.GreetController.show/2",
             "SampleAppWeb.GreetHTML.show/1",
             "SampleAppWeb.GreetingComponent.render/1",
             "SampleAppWeb.HelloLive.render/1"
           ]
  end

  test "a context call written inside a ~H interpolation is a call of its own", %{index: index} do
    {:ok, render} = Grasp.Index.fetch_function(index, "SampleAppWeb.HelloLive.render/1")

    assert %{"kind" => "remote", "range" => %{"start" => [12, 9], "end" => [12, 32]}} =
             call(render, "SampleApp.Greeter.greet/1")

    assert render["hidden_calls"] == []

    assert "SampleApp.Greeter.greet/2" in Grasp.Index.callees(
             index,
             "SampleAppWeb.HelloLive.render/1"
           )

    {:ok, component} =
      Grasp.Index.fetch_function(index, "SampleAppWeb.GreetingComponent.render/1")

    assert %{"kind" => "remote", "range" => %{"start" => [9, 12], "end" => [9, 35]}} =
             call(component, "SampleApp.Greeter.greet/1")

    assert component["hidden_calls"] == []
  end

  test "indexes an embedded template as a record of its own", %{index: index} do
    {:ok, show} = Grasp.Index.fetch_function(index, "SampleAppWeb.GreetHTML.show/1")
    file = Path.join(@fixture, "lib/sample_app_web/greet_html/show.html.heex")

    assert show["kind"] == "template"
    assert show["file"] == "lib/sample_app_web/greet_html/show.html.heex"
    assert show["span"] == %{"start_line" => 1, "end_line" => 9}
    assert show["source"] == File.read!(file)

    assert %{"range" => %{"start" => [1, 2], "end" => [1, 8]}} =
             call(show, "SampleAppWeb.GreetHTML.badge/1")

    assert %{"range" => %{"start" => [2, 2], "end" => [2, 39]}} =
             call(show, "SampleAppWeb.GreetingComponent.render/1")

    assert hidden(show, "SampleApp.Greeter.greet/1") == nil
  end

  test "a template's interpolations and expression tags are calls the reader can click",
       %{index: index} do
    {:ok, show} = Grasp.Index.fetch_function(index, "SampleAppWeb.GreetHTML.show/1")

    assert %{"kind" => "remote", "range" => %{"start" => [4, 5], "end" => [4, 28]}} =
             call(show, "SampleApp.Greeter.greet/1")

    greets =
      show["calls"]
      |> Enum.filter(&(&1["target"] == "SampleApp.Greeter.greet/1"))
      |> Enum.map(&{&1["kind"], &1["range"]})

    # The expression tag on line 5 carries a column the compiler reports; the attribute and
    # body interpolations on line 6 carry none and are placed in document order.
    assert greets == [
             {"remote", %{"start" => [4, 5], "end" => [4, 28]}},
             {"remote", %{"start" => [5, 8], "end" => [5, 21]}},
             {"remote", %{"start" => [6, 16], "end" => [6, 29]}},
             {"remote", %{"start" => [6, 39], "end" => [6, 52]}}
           ]

    assert hidden(show, "SampleApp.Greeter.greet/1") == nil
  end

  test "a route written in a template is a call on the action the router maps it to",
       %{index: index} do
    {:ok, show} = Grasp.Index.fetch_function(index, "SampleAppWeb.GreetHTML.show/1")

    assert %{
             "kind" => "route",
             "range" => %{"start" => [3, 9], "end" => [3, 21]},
             "route" => %{"verb" => "GET", "path" => "/greet/:name"}
           } = call(show, "SampleAppWeb.GreetController.show/2")

    assert %{
             "kind" => "route",
             "range" => %{"start" => [8, 17], "end" => [8, 29]},
             "route" => %{"verb" => "POST", "path" => "/greet"}
           } = call(show, "SampleAppWeb.GreetController.create/2")

    assert %{
             "kind" => "route",
             "range" => %{"start" => [9, 17], "end" => [9, 29]},
             "route" => %{"verb" => "GET", "path" => "/hello"}
           } = call(show, "SampleAppWeb.HelloLive.mount/3")

    {:ok, again} = Grasp.Index.fetch_function(index, "SampleAppWeb.GreetController.again/2")

    assert %{
             "kind" => "route",
             "route" => %{"verb" => "GET", "path" => "/greet/:name"}
           } = call(again, "SampleAppWeb.GreetController.show/2")

    assert %{"kind" => "imported"} = call(again, "Phoenix.Controller.redirect/2")

    callers = Grasp.Index.callers(index, "SampleAppWeb.GreetController.show/2")

    assert "SampleAppWeb.GreetHTML.show/1" in callers
    assert "SampleAppWeb.GreetController.again/2" in callers

    assert "SampleAppWeb.GreetHTML.show/1" in Grasp.Index.callers(
             index,
             "SampleAppWeb.HelloLive.mount/3"
           )
  end

  test "enqueueing a job is a call on the worker that performs it", %{index: index} do
    {:ok, mail} = Grasp.Index.fetch_function(index, "SampleAppWeb.GreetController.mail/2")

    assert %{
             "kind" => "enqueue",
             "range" => %{"start" => [19, 12], "end" => [19, 40]},
             "job" => %{"worker" => "SampleApp.Workers.Mailer", "queue" => "mail"}
           } = call(mail, "SampleApp.Workers.Mailer.perform/1")

    assert call(mail, "SampleApp.Workers.Mailer.new/1") == nil

    assert "SampleAppWeb.GreetController.mail/2" in Grasp.Index.callers(
             index,
             "SampleApp.Workers.Mailer.perform/1"
           )
  end

  test "the document keeps the inputs its edges are resolved from", %{index: index} do
    {:ok, show} = Grasp.Index.fetch_function(index, "SampleAppWeb.GreetHTML.show/1")

    assert %{
             "verb" => "GET",
             "path" => ["greet", "bob"],
             "range" => %{"start" => [3, 9], "end" => [3, 21]}
           } in show["route_sites"]

    {:ok, mail} = Grasp.Index.fetch_function(index, "SampleAppWeb.GreetController.mail/2")

    assert %{"via" => %{"target" => "SampleApp.Workers.Mailer.new/1", "kind" => "remote"}} =
             call(mail, "SampleApp.Workers.Mailer.perform/1")

    {:ok, greet} = Grasp.Index.fetch_function(index, "SampleApp.Greeter.greet/2")
    assert greet["route_sites"] == []
  end

  test "reaches the template a controller renders and the component a template calls",
       %{index: index} do
    {:ok, controller} = Grasp.Index.fetch_function(index, "SampleAppWeb.GreetController.show/2")

    assert %{"kind" => "template", "range" => %{"start" => [8, 5], "end" => [8, 11]}} =
             call(controller, "SampleAppWeb.GreetHTML.show/1")

    {:ok, live} = Grasp.Index.fetch_function(index, "SampleAppWeb.HelloLive.render/1")

    assert %{"kind" => "remote", "range" => %{"start" => [13, 6], "end" => [13, 43]}} =
             call(live, "SampleAppWeb.GreetingComponent.render/1")

    assert Grasp.Index.callers(index, "SampleAppWeb.GreetingComponent.render/1") == [
             "SampleAppWeb.GreetHTML.show/1",
             "SampleAppWeb.HelloLive.render/1"
           ]
  end

  test "lists modules including nested ones", %{index: index} do
    names = index |> Grasp.Index.modules() |> Enum.map(& &1["name"])

    assert "SampleApp.Greeter" in names
    assert "SampleApp.Greeter.Nested" in names
    assert "SampleApp.Formatter" in names
  end

  test "records entry points", %{index: index} do
    entries = Grasp.Index.entry_points(index)
    by_kind = Enum.group_by(entries, & &1["kind"])

    assert %{
             "label" => "GET /greet/:name",
             "target" => "SampleAppWeb.GreetController.show/2",
             "meta" => %{
               "verb" => "GET",
               "path" => "/greet/:name",
               "router" => "SampleAppWeb.Router"
             }
           } = find(entries, "SampleAppWeb.GreetController.show/2")

    assert labelled(entries, "POST /greet")["target"] == "SampleAppWeb.GreetController.create/2"
    assert labelled(entries, "GET /again")["target"] == "SampleAppWeb.GreetController.again/2"

    assert %{
             "kind" => "route",
             "target" => "SampleAppWeb.GreetController.create/2",
             "meta" => %{"path" => "/api/echo", "router" => "SampleAppWeb.ApiRouter"}
           } = labelled(entries, "POST /api/echo")

    refute Enum.any?(entries, &(&1["meta"]["path"] == "/echo"))

    assert %{
             "kind" => "live_route",
             "label" => "GET /hello",
             "target" => "SampleAppWeb.HelloLive.mount/3"
           } =
             Enum.find(entries, &(&1["kind"] == "live_route"))

    assert %{"meta" => %{"queue" => "mail", "max_attempts" => 5}} =
             find(entries, "SampleApp.Workers.Mailer.perform/1")

    live_targets = by_kind["live_view"] |> Enum.map(& &1["target"]) |> Enum.sort()

    assert live_targets == [
             "SampleAppWeb.HelloLive.handle_event/3",
             "SampleAppWeb.HelloLive.mount/3",
             "SampleAppWeb.HelloLive.render/1"
           ]

    component_targets = by_kind["live_component"] |> Enum.map(& &1["target"]) |> Enum.sort()

    assert component_targets == [
             "SampleAppWeb.GreetingComponent.handle_event/3",
             "SampleAppWeb.GreetingComponent.render/1"
           ]

    refute Enum.any?(
             by_kind["live_view"],
             &String.starts_with?(&1["target"], "SampleAppWeb.GreetingComponent.")
           )

    genserver_targets = by_kind["genserver"] |> Enum.map(& &1["target"]) |> Enum.sort()
    assert genserver_targets == ["SampleApp.Counter.handle_call/3", "SampleApp.Counter.init/1"]

    assert [%{"target" => "SampleApp.Supervisor.init/1"}] = by_kind["supervisor"]
    assert [%{"target" => "SampleApp.Application.start/2"}] = by_kind["application"]
    assert [%{"target" => "SampleAppWeb.RequestId.call/2"}] = by_kind["plug"]

    refute Enum.any?(
             entries,
             &String.starts_with?(&1["target"], "SampleAppWeb.GreetController.call/")
           )

    refute Enum.any?(entries, &String.starts_with?(&1["target"], "SampleAppWeb.Endpoint."))
    assert entries == Enum.sort_by(entries, &{kind_rank(&1["kind"]), &1["label"], &1["target"]})
  end

  test "records module behaviours", %{index: index} do
    mods = Map.new(Grasp.Index.modules(index), &{&1["name"], &1["behaviours"]})

    assert "Phoenix.LiveComponent" in mods["SampleAppWeb.GreetingComponent"]
    assert "Oban.Worker" in mods["SampleApp.Workers.Mailer"]
    assert "GenServer" in mods["SampleApp.Counter"]
    assert mods["SampleApp.Formatter"] == []
  end

  # The fixture keeps its dependencies between runs, so they are fetched only when the lock
  # names one the deps directory does not hold — which is also what a dependency added to
  # Grasp looks like from here.
  defp locked_deps do
    @fixture
    |> Path.join("mix.lock")
    |> File.read!()
    |> then(&Regex.scan(~r/^\s+"([^"]+)":/m, &1, capture: :all_but_first))
    |> List.flatten()
  end

  defp index!(args) do
    out = Path.join(System.tmp_dir!(), "grasp-sample-#{System.unique_integer([:positive])}.json")

    {output, status} =
      System.cmd("mix", ["grasp.index", "--out", out | args],
        cd: @fixture,
        env: [{"MIX_ENV", "dev"}],
        stderr_to_stdout: true
      )

    assert status == 0, output
    {:ok, index} = Grasp.Index.load(out)
    File.rm!(out)
    {output, index}
  end

  # Size as well as mtime: a rebuild inside the same second would leave the mtime alone.
  defp stat(relative) do
    %File.Stat{size: size, mtime: mtime} =
      File.stat!(Path.join(@fixture, relative), time: :posix)

    {size, mtime}
  end

  defp call(record, target), do: Enum.find(record["calls"], &(&1["target"] == target))

  defp hidden(record, target),
    do: Enum.find(record["hidden_calls"], &(&1["target"] == target))

  defp find(entries, target), do: Enum.find(entries, &(&1["target"] == target))

  defp labelled(entries, label), do: Enum.find(entries, &(&1["label"] == label))

  defp kind_rank(kind) do
    Enum.find_index(
      ~w(route live_route oban_worker live_view live_component genserver supervisor application plug),
      &(&1 == kind)
    )
  end
end
