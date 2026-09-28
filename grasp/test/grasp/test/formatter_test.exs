defmodule Grasp.Test.FormatterTest do
  use ExUnit.Case, async: true

  alias Grasp.Test.Formatter

  @moduletag :tmp_dir

  defp run(tmp_dir, tests) do
    run_file = Path.join(tmp_dir, "run/run.bin")
    {:ok, formatter} = Formatter.start_link(run_file: run_file, seed: 0)

    for test <- tests, do: GenServer.cast(formatter, {:test_finished, test})
    GenServer.cast(formatter, {:suite_finished, %{run: 1, async: 0, load: nil}})
    GenServer.stop(formatter)

    run_file |> File.read!() |> :erlang.binary_to_term()
  end

  defp test_named(name, state, time \\ 10),
    do: %ExUnit.Test{module: Acme.TallyTest, name: name, state: state, time: time}

  test "records each test's status by its id, and when the suite finished", %{tmp_dir: tmp_dir} do
    run =
      run(tmp_dir, [
        test_named(:"test counts up", nil, 1234),
        test_named(:"test is skipped", {:skipped, "pending"}),
        test_named(:"test is excluded", {:excluded, "due to integration filter"}),
        test_named(:"test is invalid", {:invalid, %ExUnit.TestModule{name: Acme.TallyTest}})
      ])

    assert {:ok, _finished_at, 0} = DateTime.from_iso8601(run.finished_at)

    assert run.tests == %{
             ~s(Acme.TallyTest."test counts up"/1) => %{
               "status" => "passed",
               "time" => 1234,
               "errors" => []
             },
             ~s(Acme.TallyTest."test is skipped"/1) => %{
               "status" => "skipped",
               "time" => 10,
               "errors" => []
             },
             ~s(Acme.TallyTest."test is excluded"/1) => %{
               "status" => "excluded",
               "time" => 10,
               "errors" => []
             },
             ~s(Acme.TallyTest."test is invalid"/1) => %{
               "status" => "invalid",
               "time" => 10,
               "errors" => []
             }
           }
  end

  test "an assertion keeps its expression and both sides as ExUnit prints them",
       %{tmp_dir: tmp_dir} do
    compared = %ExUnit.AssertionError{
      message: "Assertion with == failed",
      expr: quote(do: assert(count(7) == {:ok, 8})),
      left: {:ok, 7},
      right: {:ok, 8}
    }

    matched = %ExUnit.AssertionError{
      message: "match (=) failed",
      expr: quote(do: assert({:reply, 42, _} = next(41))),
      left: quote(do: {:reply, 42, _}),
      right: {:reply, 43, 43},
      context: {:match, []}
    }

    received = %ExUnit.AssertionError{
      message: "Assertion failed, no matching message after 100ms",
      expr: quote(do: assert_receive(:done)),
      left: :done,
      context: {:mailbox, [], []}
    }

    stacktrace = [
      {Acme.TallyTest, :"test compares", 1,
       [file: ~c"#{File.cwd!()}/test/acme/tally_test.exs", line: 12]}
    ]

    run =
      run(tmp_dir, [
        test_named(:"test compares", {:failed, [{:error, compared, stacktrace}]}),
        test_named(:"test matches", {:failed, [{:error, matched, []}]}),
        test_named(:"test receives", {:failed, [{:error, received, []}]})
      ])

    assert run.tests[~s(Acme.TallyTest."test compares"/1)] == %{
             "status" => "failed",
             "time" => 10,
             "errors" => [
               %{
                 "kind" => "error",
                 "message" => "Assertion with == failed",
                 "expr" => "assert count(7) == {:ok, 8}",
                 "left" => "{:ok, 7}",
                 "right" => "{:ok, 8}",
                 "stacktrace" => [
                   %{
                     "module" => "Acme.TallyTest",
                     "function" => "test compares",
                     "arity" => 1,
                     "file" => "test/acme/tally_test.exs",
                     "line" => 12
                   }
                 ]
               }
             ]
           }

    assert [%{"left" => "{:reply, 42, _}", "right" => "{:reply, 43, 43}"}] =
             run.tests[~s(Acme.TallyTest."test matches"/1)]["errors"]

    assert [%{"expr" => "assert_receive :done", "left" => ":done"} = error] =
             run.tests[~s(Acme.TallyTest."test receives"/1)]["errors"]

    refute Map.has_key?(error, "right")
  end

  test "a raised error, a throw and an exit keep their kind and message, and each module frame",
       %{tmp_dir: tmp_dir} do
    stacktrace = [
      {Acme.Tally, :next, [1, 2], [file: ~c"lib/acme/tally.ex", line: 3]},
      {:lists, :map, 2, [file: ~c"lists.erl", line: 1559]},
      {fn -> :ok end, 0, [file: ~c"lib/acme/tally.ex", line: 9]}
    ]

    run =
      run(tmp_dir, [
        test_named(
          :"test raises",
          {:failed, [{:error, %RuntimeError{message: "boom"}, stacktrace}]}
        ),
        test_named(:"test throws", {:failed, [{:throw, {:halt, 1}, []}]}),
        test_named(:"test exits", {:failed, [{:exit, :timeout, []}, {:error, :badarg, []}]})
      ])

    assert run.tests[~s(Acme.TallyTest."test raises"/1)]["errors"] == [
             %{
               "kind" => "error",
               "message" => "boom",
               "stacktrace" => [
                 %{
                   "module" => "Acme.Tally",
                   "function" => "next",
                   "arity" => 2,
                   "file" => "lib/acme/tally.ex",
                   "line" => 3
                 },
                 %{
                   "module" => ":lists",
                   "function" => "map",
                   "arity" => 2,
                   "file" => "lists.erl",
                   "line" => 1559
                 }
               ]
             }
           ]

    assert [%{"kind" => "throw", "message" => "{:halt, 1}", "stacktrace" => []}] =
             run.tests[~s(Acme.TallyTest."test throws"/1)]["errors"]

    assert [
             %{"kind" => "exit", "message" => ":timeout"},
             %{"kind" => "error", "message" => ":badarg"}
           ] = run.tests[~s(Acme.TallyTest."test exits"/1)]["errors"]
  end

  test "the run file comes from the application environment when ExUnit names none",
       %{tmp_dir: tmp_dir} do
    run_file = Path.join(tmp_dir, "from-env.bin")
    previous = Application.fetch_env(:grasp, Formatter)
    Application.put_env(:grasp, Formatter, run_file: run_file)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:grasp, Formatter, value)
        :error -> Application.delete_env(:grasp, Formatter)
      end
    end)

    {:ok, formatter} = Formatter.start_link(seed: 0)
    GenServer.cast(formatter, {:suite_finished, %{run: 1, async: 0, load: nil}})
    GenServer.stop(formatter)

    assert %{tests: tests} = run_file |> File.read!() |> :erlang.binary_to_term()
    assert tests == %{}
  end
end
