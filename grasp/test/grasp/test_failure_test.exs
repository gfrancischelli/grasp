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

  test "a repeated function's step keeps the deepest frame's line", %{
    index: index,
    record: record
  } do
    recursive =
      error([
        frame("SampleApp.TallyTest", "init_with", 1, 4),
        frame("GenServer", "call", 3, 1142),
        frame("SampleApp.TallyTest", "init_with", 1, 6),
        own(18)
      ])

    assert [%{id: "SampleApp.TallyTest.init_with/1", line: 4}] =
             TestFailure.chain(index, record, recursive)

    onwards =
      error([
        frame("SampleApp.Counter", "init", 1, 8),
        frame("SampleApp.TallyTest", "init_with", 1, 21),
        frame("SampleApp.TallyTest", "init_with", 1, 30),
        own(18)
      ])

    assert [%{line: 21}, %{id: "SampleApp.Counter.init/1", line: 8}] =
             TestFailure.chain(index, record, onwards)

    aliased =
      error([
        frame("SampleApp.Greeter", "greet", 2, 7),
        frame("SampleApp.Greeter", "greet", 1, 6),
        own(18)
      ])

    assert [%{id: "SampleApp.Greeter.greet/2", line: 7}] =
             TestFailure.chain(index, record, aliased)
  end

  test "a closure, comprehension or inlined frame is its enclosing function's", %{
    index: index,
    record: record
  } do
    for generated <- ["-init_with/1-fun-0-", "-init_with/1-lc$^0/1-0-", "-init_with/1-inlined-0-"] do
      error =
        error([
          frame("SampleApp.TallyTest", generated, 2, 22),
          frame("GenServer", "call", 3, 1142),
          frame("SampleApp.TallyTest", "init_with", 1, 21),
          own(18)
        ])

      assert [
               %{
                 label: "SampleApp.TallyTest.init_with/1",
                 id: "SampleApp.TallyTest.init_with/1",
                 closure?: true
               }
               | _
             ] =
               TestFailure.trace(index, record, error)

      assert TestFailure.chain(index, record, error) == [
               %{
                 id: "SampleApp.TallyTest.init_with/1",
                 via: "SampleApp.TallyTest.init_with/1",
                 line: 22
               }
             ]
    end
  end

  test "a closure in the test body is the test's own frame, a slash in its name included", %{
    index: index
  } do
    reply = ~s|SampleApp.TallyTest."test handle_call/3 replies with the next number"/1|
    {:ok, record} = Index.fetch_function(index, reply)

    closure =
      frame(
        "SampleApp.TallyTest",
        "-test handle_call/3 replies with the next number/1-fun-0-",
        1,
        13
      )

    error = error([frame("SampleApp.Counter", "handle_call", 3, 11), closure])

    assert TestFailure.line(record, error) == 13

    assert [%{own?: false}, %{own?: true, closure?: true}] =
             TestFailure.trace(index, record, error)

    assert [%{id: "SampleApp.Counter.handle_call/3", line: 11}] =
             TestFailure.chain(index, record, error)
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
