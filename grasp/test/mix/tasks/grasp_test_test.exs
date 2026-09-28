defmodule Mix.Tasks.Grasp.TestTest do
  # The task sends its report through `Mix.shell()`, which is global.
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  @moduletag :tmp_dir

  @counts ~s(Acme.TallyTest."test counts up"/1)
  @keeps ~s(Acme.TallyTest."test keeps the count"/1)
  @greets ~s(Acme.GreeterTest."test greets"/1)
  @removed ~s(Acme.GreeterTest."test waves"/1)

  setup %{tmp_dir: tmp_dir} do
    index = Path.join(tmp_dir, "index.json")
    File.write!(index, Jason.encode!(%{"version" => 1, "functions" => records()}))
    %{index: index, out: Path.join(tmp_dir, "results/results.json")}
  end

  defp records do
    [
      test_record(@counts, "test/acme/tally_test.exs", 4, "modified"),
      test_record(@keeps, "test/acme/tally_test.exs", 9, "unchanged"),
      test_record(@greets, "test/acme/greeter_test.exs", 3, "added"),
      test_record(@removed, "test/acme/greeter_test.exs", 8, "removed")
      |> Map.put("removed", true),
      %{
        "id" => "Acme.Tally.next/1",
        "module" => "Acme.Tally",
        "name" => "next",
        "arity" => 1,
        "kind" => "def",
        "file" => "lib/acme/tally.ex",
        "span" => %{"start_line" => 2, "end_line" => 4},
        "source" => "def next(count), do: count + 1",
        "change" => "modified"
      }
    ]
  end

  defp test_record(id, file, line, change) do
    [module, name] = Regex.run(~r/^(.*)\."(.*)"\/1$/, id, capture: :all_but_first)

    %{
      "id" => id,
      "module" => module,
      "name" => name,
      "arity" => 1,
      "kind" => "test",
      "file" => file,
      "span" => %{"start_line" => line, "end_line" => line + 2},
      "source" => "test #{inspect(name)} do\n  assert true\nend",
      "change" => change
    }
  end

  # Stands in for `System.cmd/3`: it reports how it is started, writes `tests` to the run
  # file the task names, as the formatter would, and answers `status`.
  defp fake_runner(tests, status) do
    parent = self()

    fn command, args, opts ->
      send(parent, {:ran, command, args, opts})
      ["run", "--no-start", _script, _ebin, run_file, "--" | _files] = args

      if tests != nil do
        File.write!(
          run_file,
          :erlang.term_to_binary(%{finished_at: "2026-09-28T12:00:00Z", tests: tests})
        )
      end

      {"", status}
    end
  end

  defp run_task(args, runner), do: capture_io(fn -> Mix.Tasks.Grasp.Test.run(args, runner) end)

  test "runs the named tests by file and line in the test environment and records them",
       %{index: index, out: out} do
    tests = %{
      @counts => %{"status" => "passed", "time" => 3, "errors" => []},
      @keeps => %{"status" => "excluded", "time" => 0, "errors" => []}
    }

    output =
      run_task(
        ["--index", index, "--out", out, @greets, @counts, @counts],
        fake_runner(tests, 0)
      )

    assert_received {:ran, "mix", args, opts}

    assert [
             "run",
             "--no-start",
             script,
             ebin,
             run_file,
             "--",
             "test/acme/greeter_test.exs:3",
             "test/acme/tally_test.exs:4"
           ] = args

    assert script == Application.app_dir(:grasp, "priv/test_run.exs")
    assert File.regular?(script)
    assert File.regular?(Path.join(ebin, "Elixir.Grasp.Test.Formatter.beam"))
    assert Path.dirname(run_file) == Path.dirname(out)
    refute File.exists?(run_file)

    assert opts[:cd] == File.cwd!()
    assert opts[:env] == [{"MIX_ENV", "test"}]
    assert %IO.Stream{} = opts[:into]

    assert output =~ "Grasp test results written to #{out} (1 passed, 1 excluded)"

    {:ok, results} = Grasp.TestResults.decode(File.read!(out))
    {:ok, loaded} = Grasp.Index.load(index)
    {:ok, counts} = Grasp.Index.fetch_function(loaded, @counts)

    assert {:fresh, %{"status" => "passed", "time" => 3, "finished_at" => "2026-09-28T12:00:00Z"}} =
             Grasp.TestResults.for_test(results, counts)
  end

  test "an id the index holds no test for aborts the task, listing every such id",
       %{index: index, out: out} do
    assert_raise Mix.Error,
                 ~s(grasp.test: the index holds no test for "Acme.Nope.\\"test x\\"/1", ) <>
                   ~s("Acme.Tally.next/1", ) <> inspect(@removed),
                 fn ->
                   Mix.Tasks.Grasp.Test.run(
                     ["--index", index, "--out", out, @counts, ~s(Acme.Nope."test x"/1)] ++
                       ["Acme.Tally.next/1", @removed],
                     fake_runner(%{}, 0)
                   )
                 end

    refute_received {:ran, _command, _args, _opts}
  end

  test "--changed runs the added and modified tests", %{index: index, out: out} do
    run_task(["--index", index, "--out", out, "--changed"], fake_runner(%{}, 0))

    assert_received {:ran, "mix", args, _opts}

    assert Enum.drop_while(args, &(&1 != "--")) ==
             ["--", "test/acme/greeter_test.exs:3", "test/acme/tally_test.exs:4"]
  end

  test "--changed with no added or modified test runs nothing", %{tmp_dir: tmp_dir, out: out} do
    index = Path.join(tmp_dir, "unchanged.json")

    File.write!(
      index,
      Jason.encode!(%{
        "version" => 1,
        "functions" => [test_record(@keeps, "test/acme/tally_test.exs", 9, "unchanged")]
      })
    )

    output = run_task(["--index", index, "--out", out, "--changed"], fake_runner(%{}, 0))

    assert output =~ "grasp: no added or modified tests to run"
    refute_received {:ran, _command, _args, _opts}
    refute File.exists?(out)
  end

  test "--all names no file, and a failing suite's status is the task's",
       %{index: index, out: out} do
    tests = %{@counts => %{"status" => "failed", "time" => 3, "errors" => []}}

    capture_io(fn ->
      assert catch_exit(
               Mix.Tasks.Grasp.Test.run(
                 ["--index", index, "--out", out, "--all"],
                 fake_runner(tests, 2)
               )
             ) == {:shutdown, 2}
    end)

    assert_received {:ran, "mix", args, _opts}
    assert List.last(args) == "--"

    assert {:ok, %{"tests" => %{@counts => %{"status" => "failed"}}}} =
             Grasp.TestResults.read(out)
  end

  test "a run that records nothing exits with its status and leaves the document untouched",
       %{index: index, out: out} do
    File.mkdir_p!(Path.dirname(out))
    File.write!(out, Grasp.TestResults.encode(Grasp.TestResults.new()))
    before = File.read!(out)

    output =
      capture_io(:stderr, fn ->
        capture_io(fn ->
          assert catch_exit(
                   Mix.Tasks.Grasp.Test.run(
                     ["--index", index, "--out", out, "--all"],
                     fake_runner(nil, 1)
                   )
                 ) == {:shutdown, 1}
        end)
      end)

    assert output =~ "the test run exited with status 1 and recorded no results"
    assert File.read!(out) == before
  end

  test "naming no test, or more than one selection, is refused", %{index: index, out: out} do
    for args <- [[], ["--all", "--changed"], [@counts, "--all"]] do
      assert_raise Mix.Error, ~r/name the tests to run, or pass one of --changed and --all/, fn ->
        Mix.Tasks.Grasp.Test.run(["--index", index, "--out", out | args], fake_runner(%{}, 0))
      end
    end
  end

  test "an index that cannot be read aborts before the suite runs", %{tmp_dir: tmp_dir} do
    assert_raise Mix.Error, ~r/cannot read the index at .*missing.json/, fn ->
      Mix.Tasks.Grasp.Test.run(
        ["--index", Path.join(tmp_dir, "missing.json"), "--all"],
        fake_runner(%{}, 0)
      )
    end

    refute_received {:ran, _command, _args, _opts}
  end
end
