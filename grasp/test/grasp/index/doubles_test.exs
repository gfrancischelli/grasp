defmodule Grasp.Index.DoublesTest do
  use ExUnit.Case, async: true

  alias Grasp.Index.{Builder, Doubles, Extract, Join, Resolve}
  alias Grasp.TracedDoubles

  describe "declarations/1" do
    test "reads each defmock, local under import Mox or on Mox, through the file's aliases" do
      helper = ~S"""
      alias SampleApp.Geo
      import Mox

      Mox.defmock(SampleApp.GeoMock, for: Geo.Lookup)
      defmock(SampleApp.ClockMock, for: SampleApp.Clock, skip_optional_callbacks: true)
      ExUnit.start()
      """

      assert Doubles.declarations([helper]) == %{
               "SampleApp.GeoMock" => "SampleApp.Geo.Lookup",
               "SampleApp.ClockMock" => "SampleApp.Clock"
             }
    end

    test "reads aliases written with as: and in braces, and runs nothing" do
      support = ~S"""
      defmodule SampleApp.Mocks do
        alias SampleApp.{Geo, Clock}
        alias SampleApp.Mailer, as: Post

        Mox.defmock(SampleApp.MailerMock, for: Post)
        Mox.defmock(Geo.Mock, for: Clock)
        Mox.defmock(@computed, for: Clock)
        Mox.defmock(SampleApp.ListMock, for: [Clock, Post])
        Mox.defmock(SampleApp.BracketMock, [for: Post])
        raise "never evaluated"
      end
      """

      assert Doubles.declarations([support, "defmodule Broken do"]) == %{
               "SampleApp.MailerMock" => "SampleApp.Mailer",
               "SampleApp.Geo.Mock" => "SampleApp.Clock",
               "SampleApp.BracketMock" => "SampleApp.Mailer"
             }
    end
  end

  describe "declarations_in/3" do
    @tag :tmp_dir
    test "reads each test path's test_helper.exs and the traced files, only parsing them",
         %{tmp_dir: root} do
      File.mkdir_p!(Path.join(root, "test/support"))
      File.mkdir_p!(Path.join(root, "integration"))

      File.write!(Path.join(root, "test/test_helper.exs"), ~S"""
      Mox.defmock(SampleApp.GeoMock, for: SampleApp.Geo)
      ExUnit.start()
      """)

      File.write!(Path.join(root, "test/support/mocks.ex"), ~S"""
      defmodule SampleApp.Mocks do
        import Mox
        alias SampleApp.Clock
        defmock(SampleApp.ClockMock, for: Clock)
        raise "never evaluated"
      end
      """)

      assert Doubles.declarations_in(
               root,
               ["test", "integration", Path.join(root, "missing")],
               ["test/support/mocks.ex", "test/support/gone.ex"]
             ) == %{
               "SampleApp.GeoMock" => "SampleApp.Geo",
               "SampleApp.ClockMock" => "SampleApp.Clock"
             }
    end

    @tag :tmp_dir
    test "finds a test path's helper written as an absolute path", %{tmp_dir: root} do
      File.mkdir_p!(Path.join(root, "test"))

      File.write!(
        Path.join(root, "test/test_helper.exs"),
        "Mox.defmock(SampleApp.GeoMock, for: SampleApp.Geo)\n"
      )

      assert Doubles.declarations_in(root, [Path.join(root, "test")], []) == %{
               "SampleApp.GeoMock" => "SampleApp.Geo"
             }
    end
  end

  describe "resolve/4" do
    @declarations %{
      "SampleApp.GeoMock" => "SampleApp.Geo",
      "SampleApp.ClockMock" => "SampleApp.Clock"
    }
    @modules [
      %{"name" => "SampleApp.Geo.Ip", "behaviours" => ["SampleApp.Geo"]},
      %{"name" => "SampleApp.Geo.Static", "behaviours" => ["GenServer", "SampleApp.Geo"]},
      %{"name" => "SampleApp.Greeter", "behaviours" => []}
    ]

    test "reaches the function of every implementation, at the fn's arity or at every one" do
      functions =
        Join.join(
          [
            definition("SampleApp.Geo.Ip", :lookup, [1]),
            definition("SampleApp.Geo.Static", :lookup, [1, 2]),
            definition("SampleApp.Greeter", :lookup, [1])
          ],
          []
        )

      [test] =
        [
          test_definition([
            site("SampleApp.GeoMock", :lookup, 1, {5, 5}),
            site("SampleApp.GeoMock", :lookup, nil, {6, 5})
          ])
        ]
        |> Join.join([])
        |> Doubles.resolve(@declarations, @modules, functions)

      double = %{mock: "SampleApp.GeoMock", behaviour: "SampleApp.Geo"}

      first =
        Map.put(double, :implementations, ["SampleApp.Geo.Ip", "SampleApp.Geo.Static"])

      assert test.calls == [
               %{
                 target: "SampleApp.Geo.Ip.lookup/1",
                 kind: :double,
                 range: range({5, 5}),
                 double: first
               },
               %{
                 target: "SampleApp.Geo.Ip.lookup/1",
                 kind: :double,
                 range: range({6, 5}),
                 double: first
               }
             ]

      assert test.hidden_calls == [
               %{target: "SampleApp.Geo.Static.lookup/1", kind: :double, line: 5, double: double},
               %{target: "SampleApp.Geo.Static.lookup/1", kind: :double, line: 6, double: double},
               %{target: "SampleApp.Geo.Static.lookup/2", kind: :double, line: 6, double: double}
             ]
    end

    test "a site reads as its double: the traced Mox call on its range gives way" do
      joined = TracedDoubles.joined_test()
      assert [%{calls: [%{target: "Mox.expect/3", range: %{start: {6, 5}}}]}] = joined

      [test] =
        Doubles.resolve(
          joined,
          TracedDoubles.declarations(),
          TracedDoubles.modules(),
          TracedDoubles.implementations()
        )

      refute Enum.any?(test.calls, &String.starts_with?(&1.target, "Mox."))

      assert [
               %{
                 target: "SampleApp.Geo.Ip.lookup/1",
                 kind: :double,
                 range: %{start: {6, 5}},
                 double: %{implementations: ["SampleApp.Geo.Ip", "SampleApp.Geo.Static"]}
               }
             ] = test.calls

      assert [%{target: "SampleApp.Geo.Static.lookup/1", kind: :double, line: 6}] =
               test.hidden_calls

      json = Builder.function_json(test)

      assert [%{"double" => %{"implementations" => [_, _]}} = call] = json["calls"]
      assert Resolve.call_record(call) == hd(test.calls)

      assert [
               %{
                 "target" => "SampleApp.Geo.Static.lookup/1",
                 "kind" => "double",
                 "line" => 6,
                 "double" => %{"mock" => "SampleApp.GeoMock", "behaviour" => "SampleApp.Geo"}
               }
             ] = json["hidden_calls"]
    end

    test "keeps the traced Mox call of a site that reaches nothing" do
      [test] =
        Doubles.resolve(
          TracedDoubles.joined_test(),
          TracedDoubles.declarations(),
          TracedDoubles.modules(),
          []
        )

      assert [%{target: "Mox.expect/3", range: %{start: {6, 5}}}] = test.calls
      assert test.hidden_calls == []
    end

    test "draws nothing for an undeclared mock, an unimplemented behaviour or an unheld arity" do
      functions = Join.join([definition("SampleApp.Geo.Ip", :lookup, [1])], [])

      [test] =
        [
          test_definition([
            site("SampleApp.UndeclaredMock", :lookup, 1, {5, 5}),
            site("SampleApp.ClockMock", :now, 0, {6, 5}),
            site("SampleApp.GeoMock", :lookup, 3, {7, 5})
          ])
        ]
        |> Join.join([])
        |> Doubles.resolve(@declarations, @modules, functions)

      assert test.calls == []
    end

    test "a capture reaches the arity it writes and no other" do
      source = ~S"""
      defmodule SampleApp.GeoTest do
        use ExUnit.Case
        import Mox

        test "looks up" do
          stub(SampleApp.GeoMock, :lookup, &SampleApp.Geo.Static.lookup/1)
        end
      end
      """

      {:ok, %{definitions: definitions}} = Extract.extract(source, "test/geo_test.exs")
      functions = Join.join([definition("SampleApp.Geo.Static", :lookup, [1, 2])], [])

      [test] =
        definitions
        |> Join.join([])
        |> Doubles.resolve(@declarations, @modules, functions)

      assert [%{target: "SampleApp.Geo.Static.lookup/1", kind: :double}] = test.calls
    end

    test "leaves a record with no double sites as it is" do
      [greet] = Join.join([definition("SampleApp.Greeter", :greet, [1])], [])
      assert Doubles.resolve([greet], @declarations, @modules, [greet]) == [greet]
    end

    test "a double call survives the document and an incremental refresh, even on a worker" do
      functions = Join.join([definition("SampleApp.Geo.Ip", :new, [1])], [])

      [test] =
        [test_definition([site("SampleApp.GeoMock", :new, 1, {5, 5})])]
        |> Join.join([])
        |> Doubles.resolve(@declarations, @modules, functions)

      json = Builder.function_json(test)

      assert [
               %{
                 "target" => "SampleApp.Geo.Ip.new/1",
                 "kind" => "double",
                 "double" => %{"mock" => "SampleApp.GeoMock", "behaviour" => "SampleApp.Geo"}
               } = call
             ] = json["calls"]

      worker = %{
        "kind" => "oban_worker",
        "label" => "SampleApp.Geo.Ip",
        "target" => "SampleApp.Geo.Ip.perform/1",
        "meta" => %{}
      }

      assert Resolve.refresh(json, [worker])["calls"] == [call]
      assert Resolve.call_record(call) == hd(test.calls)
    end
  end

  defp site(mock, function, arity, start),
    do: %{mock: mock, function: function, arity: arity, range: range(start)}

  defp range({line, column}), do: %{start: {line, column}, end: {line, column + 6}}

  defp definition(module, name, arities) do
    %{
      module: module,
      name: name,
      arity: List.last(arities),
      arities: arities,
      kind: :def,
      file: "lib/sample_app/geo.ex",
      start_line: 1,
      end_line: 3,
      source: "",
      call_sites: [],
      route_sites: [],
      double_sites: [],
      head_positions: [],
      head_ranges: []
    }
  end

  defp test_definition(double_sites) do
    %{
      definition("SampleApp.GeoTest", :"test looks up", [1])
      | kind: :test,
        file: "test/sample_app/geo_test.exs",
        double_sites: double_sites
    }
    |> Map.put(:test, %{describe: nil, name: "looks up", tags: []})
  end
end
