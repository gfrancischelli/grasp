defmodule Grasp.TestFailureTest do
  use ExUnit.Case, async: true

  alias Grasp.{Index, TestFailure}

  @init ~s|SampleApp.TallyTest."test init keeps the start count"/1|

  setup do
    {:ok, index} = Index.load("test/fixtures/index.json")
    {:ok, record} = Index.fetch_function(index, @init)
    %{index: index, record: record}
  end

  test "the line is the own frame's within the test, its first line otherwise", %{
    record: record
  } do
    assert TestFailure.line(record, error([own(18)])) == 18
    assert TestFailure.line(record, error([frame("SampleApp.Counter", "init", 1, 8)])) == 17
    assert TestFailure.line(record, error([own(99)])) == 17
    assert TestFailure.line(record, %{"stacktrace" => "nonsense"}) == 17
  end

  test "the chain runs from the test outwards, deepest last, through indexed frames only", %{
    index: index,
    record: record
  } do
    error =
      error([
        frame("SampleApp.Counter", "init", 1, 8),
        frame("GenServer", "call", 3, 1142),
        frame("SampleApp.TallyTest", "init_with", 1, 21),
        frame("SampleApp.TallyTest", "init_with", 1, 21),
        own(18),
        frame("SampleApp.Greeter", "greet", 2, 7)
      ])

    assert TestFailure.chain(index, record, error) == [
             %{
               id: "SampleApp.TallyTest.init_with/1",
               via: "SampleApp.TallyTest.init_with/1",
               line: 21
             },
             %{id: "SampleApp.Counter.init/1", via: "SampleApp.Counter.init/1", line: 8}
           ]

    trace = TestFailure.trace(index, record, error)
    assert Enum.map(trace, &(&1.id != nil)) == [true, false, true, true, true, true]
    assert Enum.map(trace, & &1.step?) == [true, false, false, true, false, false]
    assert Enum.map(trace, & &1.own?) == [false, false, false, false, true, false]
    assert Enum.at(trace, 0).skipped?
  end

  test "a frame its caller does not call is still a step, with no call target", %{
    index: index,
    record: record
  } do
    error = error([frame("SampleApp.Greeter", "greet", 2, 7), own(18)])

    assert TestFailure.chain(index, record, error) == [
             %{id: "SampleApp.Greeter.greet/2", via: nil, line: 7}
           ]
  end

  test "a malformed frame names nothing and creates no atom", %{index: index, record: record} do
    name = "never_an_atom_#{System.unique_integer([:positive])}"

    error =
      error([
        %{"module" => "SampleApp.Counter", "function" => name, "arity" => 1},
        %{"module" => %{}, "function" => nil, "arity" => "one"},
        own(18)
      ])

    assert TestFailure.chain(index, record, error) == []

    assert [%{id: nil}, %{id: nil, label: "%{}.nil"}, %{own?: true}] =
             TestFailure.trace(index, record, error)

    assert_raise ArgumentError, fn -> String.to_existing_atom(name) end
  end

  defp error(frames), do: %{"kind" => "error", "message" => "boom", "stacktrace" => frames}

  defp own(line), do: frame("SampleApp.TallyTest", "test init keeps the start count", 1, line)

  defp frame(module, function, arity, line),
    do: %{
      "module" => module,
      "function" => function,
      "arity" => arity,
      "file" => "f.ex",
      "line" => line
    }
end
