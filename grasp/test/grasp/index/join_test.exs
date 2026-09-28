defmodule Grasp.Index.JoinTest do
  use ExUnit.Case, async: false

  alias Grasp.Index.{Builder, Extract, Join}
  alias Grasp.TestSupport.Compile

  @source ~S"""
  defmodule Grasp.JoinTest.Sample do
    alias Enum, as: E
    import String, only: [upcase: 1]

    def run(list, extra \\ nil) do
      E.map(list, &helper/1)
      upcase("a")
      helper(extra)
    end

    defp helper(x), do: x
  end
  """

  setup do
    events = Compile.trace(@source, "lib/sample.ex")
    {:ok, %{definitions: defs}} = Extract.extract(@source, "lib/sample.ex")
    %{events: events, defs: defs}
  end

  test "function_id/3 formats Elixir and Erlang modules", _ do
    assert Join.function_id(Grasp.JoinTest.Sample, :run, 2) == "Grasp.JoinTest.Sample.run/2"
    assert Join.function_id(:erlang, :max, 2) == ":erlang.max/2"
    assert Join.function_id("Grasp.JoinTest.Sample", :run, 2) == "Grasp.JoinTest.Sample.run/2"
  end

  test "function_id/3 quotes a name only where a remote call would", _ do
    assert Join.function_id("SampleAppWeb.GreetControllerTest", :"test greet/2 says hello", 1) ==
             ~S|SampleAppWeb.GreetControllerTest."test greet/2 says hello"/1|

    assert Join.function_id(SampleApp.Greeter, :greet, 2) == "SampleApp.Greeter.greet/2"
    assert Join.function_id(SampleApp.Greeter, :valid?, 1) == "SampleApp.Greeter.valid?/1"
    assert Join.function_id(Kernel, :+, 2) == "Kernel.+/2"

    assert Join.function_id(SampleApp.Greeter, :__ex_unit_setup_0, 1) ==
             "SampleApp.Greeter.__ex_unit_setup_0/1"
  end

  test "function_id/3 quotes a name given as text the same way, creating no atom", _ do
    unseen = "test acme #{System.unique_integer([:positive])} says \"hi\""
    assert_raise ArgumentError, fn -> String.to_existing_atom(unseen) end

    assert Join.function_id("SampleApp.GreeterTest", unseen, 1) ==
             "SampleApp.GreeterTest.#{inspect(unseen)}/1"

    assert_raise ArgumentError, fn -> String.to_existing_atom(unseen) end

    control = "test acme #{System.unique_integer([:positive])} \\0 \0 end"

    assert Join.function_id("SampleApp.GreeterTest", control, 1) ==
             Join.function_id("SampleApp.GreeterTest", String.to_atom(control), 1)

    bare = "acme_unseen_#{System.unique_integer([:positive])}?"
    assert Join.function_id("SampleApp.Greeter", bare, 1) == "SampleApp.Greeter.#{bare}/1"
    assert_raise ArgumentError, fn -> String.to_existing_atom(bare) end

    for name <- [:"test greet/2 says hello", :greet, :valid?, :+, :.., :"test \"quoted\""] do
      assert Join.function_id("SampleApp.Greeter", Atom.to_string(name), 1) ==
               Join.function_id("SampleApp.Greeter", name, 1)
    end
  end

  test "pairs the calls in a test's and a setup's body with the tracer's events", _ do
    source = ~S"""
    defmodule Grasp.JoinTest.GreeterTest do
      use ExUnit.Case, register: false

      setup do
        {:ok, name: String.upcase("ada")}
      end

      describe "greet/2" do
        @tag :slow
        test "says hello", %{name: name} do
          assert String.length(name) == 3
        end
      end
    end
    """

    events = Compile.trace(source, "test/greeter_test.exs")
    {:ok, %{definitions: defs}} = Extract.extract(source, "test/greeter_test.exs")
    records = Join.join(defs, events)

    test_record = record(records, "Grasp.JoinTest.GreeterTest", :"test greet/2 says hello")
    assert test_record.id == ~S|Grasp.JoinTest.GreeterTest."test greet/2 says hello"/1|
    assert test_record.kind == :test
    assert test_record.test == %{describe: "greet/2", name: "says hello", tags: ["slow"]}

    assert %{kind: :remote, range: %{start: {11, 14}, end: {11, 27}}} =
             call(test_record, "String.length/1")

    setup = record(records, "Grasp.JoinTest.GreeterTest", :__ex_unit_setup_0)
    assert setup.id == "Grasp.JoinTest.GreeterTest.__ex_unit_setup_0/1"
    assert setup.test == nil
    assert %{kind: :remote, range: %{start: {5, 17}}} = call(setup, "String.upcase/1")

    assert Builder.function_json(test_record)["test"] ==
             %{"describe" => "greet/2", "name" => "says hello", "tags" => ["slow"]}

    refute Map.has_key?(Builder.function_json(setup), "test")
  end

  test "pairs events with call sites into ranged calls", %{events: events, defs: defs} do
    [run] = Join.join(defs, events) |> Enum.filter(&(&1.name == :run))

    assert run.id == "Grasp.JoinTest.Sample.run/2"
    assert run.arities == [1, 2]
    assert run.span == %{start_line: 5, end_line: 9}

    assert %{kind: :remote, range: %{start: {6, 5}, end: {6, 10}}} = call(run, "Enum.map/2")

    assert %{kind: :local, range: %{start: {6, 18}, end: {6, 24}}} =
             call(run, "Grasp.JoinTest.Sample.helper/1")

    assert %{kind: :imported, range: %{start: {7, 5}, end: {7, 11}}} =
             call(run, "String.upcase/1")

    assert run.hidden_calls == []
  end

  test "drops Kernel calls, def-registration events and column-less calls into dependencies",
       %{defs: defs} do
    events = [
      event(:run, 2, 6, 7, {Kernel, :if, 2}, :imported_macro),
      event(:run, 2, 6, nil, {:erlang, :orelse, 2}, :remote),
      event(:run, 2, 5, 7, {Module, :compile_definition_attributes, 6}, :remote)
    ]

    [run] = Join.join(defs, events) |> Enum.filter(&(&1.name == :run))
    assert run.calls == []
    assert run.hidden_calls == []
  end

  test "keeps a column-less call to an indexed definition as a hidden call", %{defs: defs} do
    events = [event(:run, 2, 7, nil, {Grasp.JoinTest.Sample, :helper, 1}, :remote)]

    [run] = Join.join(defs, events) |> Enum.filter(&(&1.name == :run))

    assert run.calls == []

    assert run.hidden_calls == [
             %{target: "Grasp.JoinTest.Sample.helper/1", kind: :remote, line: 7}
           ]
  end

  @named_range %{start: {6, 26}, end: {6, 31}}

  test "places a column-less event on the site that wrote the same call", %{defs: defs} do
    defs = with_site(defs, :run, named_site("Greeter"))
    events = [event(:run, 2, 6, nil, {SampleApp.Greeter, :greet, 1}, :remote)]

    [run] = defs |> Join.join(events) |> Enum.filter(&(&1.name == :run))

    assert run.calls == [
             %{target: "SampleApp.Greeter.greet/1", kind: :remote, range: @named_range}
           ]

    assert run.hidden_calls == []
  end

  test "reads the written module as a suffix of the module the compiler resolved",
       %{defs: defs} do
    defs = with_site(defs, :run, named_site("Greeter"))
    events = [event(:run, 2, 6, nil, {Other.Greeter, :greet, 1}, :remote)]

    [run] = defs |> Join.join(events) |> Enum.filter(&(&1.name == :run))

    assert [%{target: "Other.Greeter.greet/1", range: @named_range}] = run.calls
  end

  test "leaves a column-less event whose module is not the written one", %{defs: defs} do
    defs = with_site(defs, :run, named_site("Greeter"))
    events = [event(:run, 2, 6, nil, {Greeting, :greet, 1}, :remote)]

    [run] = defs |> Join.join(events) |> Enum.filter(&(&1.name == :run))

    assert run.calls == []
    assert run.hidden_calls == []
  end

  test "places a column-less event on a site written without a module", %{defs: defs} do
    defs = with_site(defs, :run, named_site(nil))
    events = [event(:run, 2, 6, nil, {SampleApp.Greeter, :greet, 1}, :remote)]

    [run] = defs |> Join.join(events) |> Enum.filter(&(&1.name == :run))

    assert [%{target: "SampleApp.Greeter.greet/1", range: @named_range}] = run.calls
  end

  test "hands two events on one line to two sites in document order", %{defs: defs} do
    second = %{named_site("Greeter") | column: 40, range: %{start: {6, 40}, end: {6, 45}}}
    defs = defs |> with_site(:run, named_site("Greeter")) |> with_site(:run, second)

    event = event(:run, 2, 6, nil, {SampleApp.Greeter, :greet, 1}, :remote)

    [run] = defs |> Join.join([event, event]) |> Enum.filter(&(&1.name == :run))

    assert Enum.map(run.calls, & &1.range) == [@named_range, second.range]
  end

  test "leaves a site a column-bearing event lands on out of the named placement",
       %{defs: defs} do
    events = [
      event(:run, 2, 6, 18, {Grasp.JoinTest.Sample, :helper, 1}, :local),
      event(:run, 2, 6, nil, {Grasp.JoinTest.Sample, :helper, 1}, :remote)
    ]

    [run] = defs |> Join.join(events) |> Enum.filter(&(&1.name == :run))

    assert run.calls == [
             %{
               target: "Grasp.JoinTest.Sample.helper/1",
               kind: :local,
               range: %{start: {6, 18}, end: {6, 24}}
             }
           ]

    assert run.hidden_calls == [
             %{target: "Grasp.JoinTest.Sample.helper/1", kind: :remote, line: 6}
           ]
  end

  test "never places a column-less event on a site with no callee", %{defs: defs} do
    defs = with_site(defs, :run, %{named_site("Greeter") | callee: nil})
    events = [event(:run, 2, 6, nil, {SampleApp.Greeter, :greet, 1}, :remote)]

    [run] = defs |> Join.join(events) |> Enum.filter(&(&1.name == :run))

    assert run.calls == []
    assert run.hidden_calls == []
  end

  test "drops a column-less call whose line is outside the definition span", %{defs: defs} do
    events = [event(:run, 2, 99, nil, {Grasp.JoinTest.Sample, :helper, 1}, :remote)]

    [run] = Join.join(defs, events) |> Enum.filter(&(&1.name == :run))

    assert run.calls == []
    assert run.hidden_calls == []
  end

  test "drops a column-less call whose target the index does not hold", %{defs: defs} do
    events = [event(:run, 2, 6, nil, {Phoenix.LiveView.Engine, :fetch_assign!, 2}, :remote)]

    [run] = Join.join(defs, events) |> Enum.filter(&(&1.name == :run))

    assert run.calls == []
    assert run.hidden_calls == []
  end

  test "drops a reflection target reported at a real call site", %{defs: defs} do
    events = [event(:run, 2, 6, 5, {Phoenix.VerifiedRoutes, :__encode_segment__, 1}, :remote)]

    [run] = Join.join(defs, events) |> Enum.filter(&(&1.name == :run))

    assert run.calls == []
    assert run.hidden_calls == []
  end

  test "drops a sigil target reported at a position no site holds", %{defs: defs} do
    events = [event(:run, 2, 6, 5, {Phoenix.VerifiedRoutes, :sigil_p, 2}, :imported_macro)]

    [run] = Join.join(defs, events) |> Enum.filter(&(&1.name == :run))

    assert run.calls == []
    assert run.hidden_calls == []
  end

  @piped ~S'''
  defmodule Grasp.JoinTest.Piped do
    def render(assigns) do
      ~H"""
      <p>{@amount |> Fmt.money()}</p>
      """
    end
  end
  '''

  test "places a column-less event on the site a piped call wrote" do
    {:ok, %{definitions: defs}} = Extract.extract(@piped, "lib/piped.ex")

    events = [
      %{
        file: "lib/piped.ex",
        module: Grasp.JoinTest.Piped,
        function: {:render, 1},
        line: 4,
        column: nil,
        target: {App.Fmt, :money, 1},
        kind: :remote
      }
    ]

    render = defs |> Join.join(events) |> record("Grasp.JoinTest.Piped", :render)

    assert render.calls == [
             %{
               target: "App.Fmt.money/1",
               kind: :remote,
               range: %{start: {4, 20}, end: {4, 29}}
             }
           ]

    assert render.hidden_calls == []
  end

  @reflection ~S"""
  defmodule Grasp.JoinTest.Schema do
    def __schema__(_kind), do: []
    def run, do: :ok
  end
  """

  test "drops a column-less reflection call even when the index holds it" do
    {:ok, %{definitions: defs}} = Extract.extract(@reflection, "lib/schema.ex")

    events = [
      %{
        file: "lib/schema.ex",
        module: Grasp.JoinTest.Schema,
        function: {:run, 0},
        line: 3,
        column: nil,
        target: {Grasp.JoinTest.Schema, :__schema__, 1},
        kind: :remote
      }
    ]

    run = defs |> Join.join(events) |> record("Grasp.JoinTest.Schema", :run)

    assert run.calls == []
    assert run.hidden_calls == []
  end

  test "keeps events with no matching node as hidden calls", %{defs: defs} do
    events = [event(:run, 2, 6, 99, {MyAppWeb.CoreComponents, :button, 1}, :remote)]

    [run] = Join.join(defs, events) |> Enum.filter(&(&1.name == :run))

    assert run.hidden_calls == [
             %{target: "MyAppWeb.CoreComponents.button/1", kind: :remote, line: 6}
           ]
  end

  test "attributes events made through a default-argument arity to the definition", %{defs: defs} do
    events = [event(:run, 1, 6, 7, {Enum, :map, 2}, :remote)]

    [run] = Join.join(defs, events) |> Enum.filter(&(&1.name == :run))
    assert [%{target: "Enum.map/2"}] = run.calls
  end

  test "drops events whose caller has no definition", %{defs: defs} do
    events = [event(:generated, 0, 6, 7, {Enum, :map, 2}, :remote)]
    assert Enum.all?(Join.join(defs, events), &(&1.calls == [] and &1.hidden_calls == []))
  end

  @hooked ~S"""
  defmodule Grasp.JoinTest.Hooks do
    def hook(_env, _kind, _name, _args, _guards, _body), do: :ok
  end

  defmodule Grasp.JoinTest.Hooked do
    @on_definition {Grasp.JoinTest.Hooks, :hook}

    def greet(name) do
      String.upcase(name)
    end
  end
  """

  test "drops the @on_definition hook reported at the def head and keeps the real call" do
    records = join_source(@hooked, "lib/hooked.ex")
    greet = record(records, "Grasp.JoinTest.Hooked", :greet)

    assert greet.calls == [
             %{target: "String.upcase/1", kind: :remote, range: %{start: {9, 5}, end: {9, 18}}}
           ]

    assert greet.hidden_calls == []
    assert record(records, "Grasp.JoinTest.Hooks", :hook).calls == []
  end

  @macros ~S"""
  defmodule Grasp.JoinTest.Macros do
    defmacro twice(x), do: quote(do: unquote(x) * 2)
  end
  """

  test "drops compiler internals reported inside a macro body" do
    twice = @macros |> join_source("lib/macros.ex") |> record("Grasp.JoinTest.Macros", :twice)
    targets = Enum.map(twice.calls ++ twice.hidden_calls, & &1.target)

    refute Enum.any?(targets, &String.starts_with?(&1, ":elixir_"))
    refute Enum.any?(targets, &String.contains?(&1, "unquote"))
  end

  @delegate ~S"""
  defmodule Grasp.JoinTest.Delegates do
    defdelegate size(x), to: Enum, as: :count
  end
  """

  test "recovers the delegated call of a defdelegate, ranged over the delegate name" do
    size =
      @delegate |> join_source("lib/delegates.ex") |> record("Grasp.JoinTest.Delegates", :size)

    assert size.calls == [
             %{target: "Enum.count/1", kind: :remote, range: %{start: {2, 15}, end: {2, 19}}}
           ]

    assert size.hidden_calls == []
  end

  test "drops a column-less reflection event reported on a defdelegate" do
    {:ok, %{definitions: defs}} = Extract.extract(@delegate, "lib/delegates.ex")

    events = [
      %{
        file: "lib/delegates.ex",
        module: Grasp.JoinTest.Delegates,
        function: {:size, 1},
        line: 2,
        column: nil,
        target: {Phoenix.Component.Declarative, :__on_definition__, 6},
        kind: :remote
      }
    ]

    size = defs |> Join.join(events) |> record("Grasp.JoinTest.Delegates", :size)

    assert size.calls == []
    assert size.hidden_calls == []
  end

  @defaults ~S"""
  defmodule Grasp.JoinTest.Defaults do
    def greet(name, prefix \\ String.trim(" p ")) do
      prefix <> name
    end
  end
  """

  test "resolves a call inside a default argument to its expression, not a hidden call" do
    greet =
      @defaults |> join_source("lib/defaults.ex") |> record("Grasp.JoinTest.Defaults", :greet)

    assert greet.calls == [
             %{target: "String.trim/1", kind: :remote, range: %{start: {2, 29}, end: {2, 40}}}
           ]

    assert greet.hidden_calls == []
  end

  @controller ~S"""
  defmodule Grasp.JoinTest.GreetController do
    def show(conn, name) do
      render(conn, :show, name: name)
    end
  end
  """

  @html ~S"""
  defmodule Grasp.JoinTest.GreetHTML do
    def show(assigns), do: assigns
  end
  """

  test "retargets a controller's render at the template the HTML module holds" do
    {:ok, %{definitions: controller}} = Extract.extract(@controller, "lib/greet_controller.ex")
    {:ok, %{definitions: html}} = Extract.extract(@html, "lib/greet_html.ex")

    events = [render_event()]

    show =
      (controller ++ html)
      |> Join.join(events)
      |> record("Grasp.JoinTest.GreetController", :show)

    assert show.calls == [
             %{
               target: "Grasp.JoinTest.GreetHTML.show/1",
               kind: :template,
               range: %{start: {3, 5}, end: {3, 11}}
             }
           ]
  end

  test "retargets a render at a template whose name only a quoted id can spell" do
    source = String.replace(@controller, "render(conn, :show,", ~S|render(conn, "my-page.html",|)
    {:ok, %{definitions: controller}} = Extract.extract(source, "lib/greet_controller.ex")
    {:ok, %{definitions: [show_html]}} = Extract.extract(@html, "lib/greet_html.ex")
    page = %{show_html | name: :"my-page", kind: :template}

    show =
      (controller ++ [page])
      |> Join.join([render_event()])
      |> record("Grasp.JoinTest.GreetController", :show)

    assert show.calls == [
             %{
               target: ~S|Grasp.JoinTest.GreetHTML."my-page"/1|,
               kind: :template,
               range: %{start: {3, 5}, end: {3, 11}}
             }
           ]
  end

  test "leaves a render whose template the index does not hold as the call the compiler made" do
    {:ok, %{definitions: controller}} = Extract.extract(@controller, "lib/greet_controller.ex")

    show =
      controller
      |> Join.join([render_event()])
      |> record("Grasp.JoinTest.GreetController", :show)

    assert show.calls == [
             %{
               target: "Phoenix.Controller.render/3",
               kind: :imported,
               range: %{start: {3, 5}, end: {3, 11}}
             }
           ]
  end

  @pdf_controller ~S"""
  defmodule Grasp.JoinTest.PdfController do
    def show(conn, name) do
      MyApp.PDF.render(conn, :show, name: name)
    end
  end
  """

  @pdf_html ~S"""
  defmodule Grasp.JoinTest.PdfHTML do
    def show(assigns), do: assigns
  end
  """

  test "leaves a render made through another module alone, template or not" do
    {:ok, %{definitions: controller}} = Extract.extract(@pdf_controller, "lib/pdf_controller.ex")
    {:ok, %{definitions: html}} = Extract.extract(@pdf_html, "lib/pdf_html.ex")

    event = %{
      file: "lib/pdf_controller.ex",
      module: Grasp.JoinTest.PdfController,
      function: {:show, 2},
      line: 3,
      column: 15,
      target: {MyApp.PDF, :render, 3},
      kind: :remote
    }

    show =
      (controller ++ html)
      |> Join.join([event])
      |> record("Grasp.JoinTest.PdfController", :show)

    assert show.calls == [
             %{
               target: "MyApp.PDF.render/3",
               kind: :remote,
               range: %{start: {3, 5}, end: {3, 21}}
             }
           ]
  end

  @routed ~S'''
  defmodule Grasp.JoinTest.Routed do
    def render(assigns) do
      ~H"""
      <a href="/greet/bob">again</a>
      """
    end
  end
  '''

  test "copies the route sites of a definition onto its record, untouched" do
    {:ok, %{definitions: definitions}} = Extract.extract(@routed, "lib/routed.ex")

    assert Join.join(definitions, [])
           |> record("Grasp.JoinTest.Routed", :render)
           |> Map.fetch!(:route_sites) == [
             %{verb: "GET", path: ["greet", "bob"], range: %{start: {4, 13}, end: {4, 25}}}
           ]
  end

  defp named_site(module) do
    %{
      line: 6,
      column: 26,
      range: @named_range,
      template: nil,
      callee: %{module: module, name: :greet, arity: 1}
    }
  end

  defp with_site(definitions, name, site) do
    Enum.map(definitions, fn
      %{name: ^name} = definition ->
        %{definition | call_sites: definition.call_sites ++ [site]}

      definition ->
        definition
    end)
  end

  defp render_event do
    %{
      file: "lib/greet_controller.ex",
      module: Grasp.JoinTest.GreetController,
      function: {:show, 2},
      line: 3,
      column: 5,
      target: {Phoenix.Controller, :render, 3},
      kind: :imported
    }
  end

  defp join_source(source, file) do
    events = Compile.trace(source, file)
    {:ok, %{definitions: defs}} = Extract.extract(source, file)
    Join.join(defs, events)
  end

  defp record(records, module, name),
    do: Enum.find(records, &(&1.module == module and &1.name == name))

  defp call(record, target), do: Enum.find(record.calls, &(&1.target == target))

  defp event(name, arity, line, column, target, kind) do
    %{
      file: "lib/sample.ex",
      module: Grasp.JoinTest.Sample,
      function: {name, arity},
      line: line,
      column: column,
      target: target,
      kind: kind
    }
  end
end
