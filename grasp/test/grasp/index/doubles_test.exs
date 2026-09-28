defmodule Grasp.Index.DoublesTest do
  use ExUnit.Case, async: true

  alias Grasp.Index.{Builder, Doubles, Join, Resolve}

  describe "declarations/1" do
    test "reads each defmock, local under import Mox or on Mox, through the file's aliases" do
      helper = ~S"""
      alias SampleApp.Geo
      import Mox

      Mox.defmock(GeolocationMock, for: Geo.Lookup)
      defmock(SampleApp.ClockMock, for: SampleApp.Clock, skip_optional_callbacks: true)
      ExUnit.start()
      """

      assert Doubles.declarations([helper]) == %{
               "GeolocationMock" => "SampleApp.Geo.Lookup",
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
        Mox.defmock(ListMock, for: [Clock, Post])
        raise "never evaluated"
      end
      """

      assert Doubles.declarations([support, "defmodule Broken do"]) == %{
               "SampleApp.MailerMock" => "SampleApp.Mailer",
               "SampleApp.Geo.Mock" => "SampleApp.Clock"
             }
    end
  end

  describe "resolve/4" do
    @declarations %{
      "GeolocationMock" => "SampleApp.Geo",
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
            site("GeolocationMock", :lookup, 1, {5, 5}),
            site("GeolocationMock", :lookup, nil, {6, 5})
          ])
        ]
        |> Join.join([])
        |> Doubles.resolve(@declarations, @modules, functions)

      double = %{mock: "GeolocationMock", behaviour: "SampleApp.Geo"}

      assert test.calls == [
               %{
                 target: "SampleApp.Geo.Ip.lookup/1",
                 kind: :double,
                 range: range({5, 5}),
                 double: double
               },
               %{
                 target: "SampleApp.Geo.Static.lookup/1",
                 kind: :double,
                 range: range({5, 5}),
                 double: double
               },
               %{
                 target: "SampleApp.Geo.Ip.lookup/1",
                 kind: :double,
                 range: range({6, 5}),
                 double: double
               },
               %{
                 target: "SampleApp.Geo.Static.lookup/1",
                 kind: :double,
                 range: range({6, 5}),
                 double: double
               },
               %{
                 target: "SampleApp.Geo.Static.lookup/2",
                 kind: :double,
                 range: range({6, 5}),
                 double: double
               }
             ]
    end

    test "draws nothing for an undeclared mock, an unimplemented behaviour or an unheld arity" do
      functions = Join.join([definition("SampleApp.Geo.Ip", :lookup, [1])], [])

      [test] =
        [
          test_definition([
            site("UndeclaredMock", :lookup, 1, {5, 5}),
            site("SampleApp.ClockMock", :now, 0, {6, 5}),
            site("GeolocationMock", :lookup, 3, {7, 5})
          ])
        ]
        |> Join.join([])
        |> Doubles.resolve(@declarations, @modules, functions)

      assert test.calls == []
    end

    test "leaves a record with no double sites as it is" do
      [greet] = Join.join([definition("SampleApp.Greeter", :greet, [1])], [])
      assert Doubles.resolve([greet], @declarations, @modules, [greet]) == [greet]
    end

    test "a double call survives the document and an incremental refresh, even on a worker" do
      functions = Join.join([definition("SampleApp.Geo.Ip", :new, [1])], [])

      [test] =
        [test_definition([site("GeolocationMock", :new, 1, {5, 5})])]
        |> Join.join([])
        |> Doubles.resolve(@declarations, @modules, functions)

      json = Builder.function_json(test)

      assert [
               %{
                 "target" => "SampleApp.Geo.Ip.new/1",
                 "kind" => "double",
                 "double" => %{"mock" => "GeolocationMock", "behaviour" => "SampleApp.Geo"}
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
