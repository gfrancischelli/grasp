defmodule Grasp.TracedDoubles do
  @moduledoc """
  A test writing a Mox expectation, and the two implementations of the behaviour its mock
  doubles, built the way `mix grasp.index` builds them: extracted from source, joined with
  the trace's event for the imported `Mox.expect/3` on the expectation's range, resolved by
  `Grasp.Index.Doubles` and written by `Grasp.Index.Builder.function_json/1`.

  The expectation sits on line 6 of the test file, at column 5.
  """

  alias Grasp.Index.{Builder, Doubles, Extract, Join}

  @test_source ~S"""
  defmodule SampleApp.GeoTest do
    use ExUnit.Case
    import Mox

    test "looks up an address" do
      expect(SampleApp.GeoMock, :lookup, fn _ip -> :ok end)
    end
  end
  """

  @implementations_source ~S"""
  defmodule SampleApp.Geo.Ip do
    @behaviour SampleApp.Geo
    def lookup(ip), do: ip
  end

  defmodule SampleApp.Geo.Static do
    @behaviour SampleApp.Geo
    def lookup(_ip), do: :static
  end
  """

  @doc "The test's id."
  @spec test_id() :: String.t()
  def test_id, do: ~s|SampleApp.GeoTest."test looks up an address"/1|

  @doc "The mock declarations the build reads, the mock mapped to the behaviour it doubles."
  @spec declarations() :: Doubles.declarations()
  def declarations, do: %{"SampleApp.GeoMock" => "SampleApp.Geo"}

  @doc "The modules, in the document's JSON shape, both implementing `SampleApp.Geo`."
  @spec modules() :: [map()]
  def modules do
    for name <- ["SampleApp.Geo.Ip", "SampleApp.Geo.Static"],
        do: %{
          "name" => name,
          "file" => "lib/sample_app/geo.ex",
          "line" => 1,
          "behaviours" => ["SampleApp.Geo"]
        }
  end

  @doc "The test's record as the join writes it, before its doubles are resolved."
  @spec joined_test() :: [Join.function_record()]
  def joined_test do
    {:ok, %{definitions: definitions}} = Extract.extract(@test_source, "test/geo_test.exs")

    event = %{
      file: "test/geo_test.exs",
      module: SampleApp.GeoTest,
      function: {:"test looks up an address", 1},
      line: 6,
      column: 5,
      target: {Mox, :expect, 3},
      kind: :imported
    }

    Join.join(definitions, [event])
  end

  @doc "The implementations' records as the join writes them."
  @spec implementations() :: [Join.function_record()]
  def implementations do
    {:ok, %{definitions: definitions}} =
      Extract.extract(@implementations_source, "lib/sample_app/geo.ex")

    Join.join(definitions, [])
  end

  @doc "The test's record and the implementations', in the JSON shape the document holds."
  @spec records_json() :: [map()]
  def records_json do
    implementations = implementations()

    joined_test()
    |> Doubles.resolve(declarations(), modules(), implementations)
    |> Enum.concat(implementations)
    |> Enum.map(&Builder.function_json/1)
  end
end
